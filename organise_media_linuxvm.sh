#!/usr/bin/env bash

# organise_media.sh
# Renames and sorts video files from ~/Downloads into $MEDIA/Movies and $MEDIA/TV
# TV lookups:    TVmaze API  (free, no key needed)
# Movie lookups: OMDb API    (free key required — get one at https://www.omdbapi.com/apikey.aspx)

# Set your OMDb key here or export OMDB_API_KEY=yourkey before running:
OMDB_API_KEY="${OMDB_API_KEY:-}"

set -euo pipefail

DOWNLOADS="$HOME/Downloads"
MEDIA="$HOME/media"
MOVIES="$HOME/media/Movies"
TV="$HOME/media/TV"

# ── Title corrections database ────────────────────────────────────────────────
# Stores confirmed API titles so apostrophes (and other corrections) are
# remembered across runs without re-querying the network.
# Format: one entry per line, tab-separated:  normalised_key <TAB> Confirmed Title (Year)
# "normalised_key" is the title lowercased with apostrophes/quotes stripped,
# so "bobs burgers" → "Bob's Burgers (2011)"
DB_DIR="$HOME/.config/organise_media"
DB_FILE="$DB_DIR/title_corrections.tsv"
CONFIG_FILE="$DB_DIR/config"
mkdir -p "$DB_DIR"
[[ -f "$DB_FILE" ]] || touch "$DB_FILE"

# Load OMDB_API_KEY from config file if not already exported into the environment
if [[ -z "${OMDB_API_KEY:-}" ]] && [[ -s "$CONFIG_FILE" ]]; then
    _v=$(awk -F'=' '/^OMDB_API_KEY[[:space:]]*=/{gsub(/^[[:space:]]+|[[:space:]]+$|[[:space:]]*#.*/, "", $2); print $2; exit}' "$CONFIG_FILE")
    [[ -n "$_v" ]] && OMDB_API_KEY="$_v"
    unset _v
fi

VIDEO_EXTENSIONS=("mkv" "mp4" "avi" "m4v" "mov" "wmv" "mpg" "mpeg")
PROCESSED_FILES=()  # display strings for end-of-run summary
SOURCE_PATHS=()     # original filepaths of successfully processed files

# ── Flag parsing ──────────────────────────────────────────────────────────────

# Handle standalone commands (these exit immediately and must be the sole arg)
case "${1:-}" in
    -h|--help|-\?)
        cat <<EOF

Usage: $(basename "$0") [OPTIONS]

Renames and files video downloads from \$DOWNLOADS into \$MEDIA/Movies and \$MEDIA/TV.
  DOWNLOADS = ${DOWNLOADS}
  MEDIA     = ${MEDIA}

Run options (combinable):
  --copy       Copy files instead of moving them
  --dry-run    Preview what would happen without touching any files
  --auto       Accept the first API match without prompting

Utility commands (sole argument):
  --cleanup    Delete everything inside \$DOWNLOADS
  --show-db    Print the local title-corrections database
  --edit-db    Open the corrections database in \$EDITOR
  --show-media Show a summary of ~/media/ (movies + TV episode counts)

API keys:
  TV shows  — TVmaze (free, no key needed)
  Movies    — OMDb   (free key: https://www.omdbapi.com/apikey.aspx)
              export OMDB_API_KEY=yourkey

Environment overrides:
  MEDIA          Base directory for sorted output  (default: ~/Temp)
  OMDB_API_KEY   OMDb API key for movie lookups
  EDITOR         Editor used by --edit-db          (default: nano)

EOF
        exit 0
        ;;
    --cleanup)
        echo ""
        echo "🧹  Clearing $DOWNLOADS ..."
        find "$DOWNLOADS/" -mindepth 1 -delete
        echo "✓   Done."
        exit 0
        ;;
    --show-db)
        echo ""
        echo "📖  Title corrections database ($DB_FILE):"
        echo ""
        if [[ ! -s "$DB_FILE" ]]; then
            echo "   (empty)"
        else
            column -t -s $'\t' "$DB_FILE" | sed 's/^/   /'
        fi
        echo ""
        exit 0
        ;;
    --edit-db)
        "${EDITOR:-nano}" "$DB_FILE"
        exit 0
        ;;
esac

COPY_MODE=false
DRY_RUN=false
AUTO_MODE=false
SHOW_MEDIA=false
CONFIRMED_TITLES=()

for arg in "$@"; do
    case "$arg" in
        --copy)       COPY_MODE=true ;;
        --dry-run)    DRY_RUN=true ;;
        --auto)       AUTO_MODE=true ;;
        --show-media) SHOW_MEDIA=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# ── Dependency check ──────────────────────────────────────────────────────────

for cmd in curl python3; do
    command -v "$cmd" &>/dev/null || { echo "Error: '$cmd' is required but not installed."; exit 1; }
done

# ── Helpers ───────────────────────────────────────────────────────────────────

is_video() {
    local ext="${1##*.}"; ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    for e in "${VIDEO_EXTENSIONS[@]}"; do [[ "$ext" == "$e" ]] && return 0; done
    return 1
}

pick_option() {
    local prompt="$1"; shift
    local options=("$@")
    echo "" >&2
    echo "  ❓ $prompt" >&2
    local i=1
    for opt in "${options[@]}"; do
        printf "     %d) %s\n" "$i" "$opt" >&2
        ((i++))
    done
    while true; do
        printf "  Choice [1-%d]: " "${#options[@]}" >&2
        read -r choice </dev/tty
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "${options[$((choice-1))]}"
            return
        fi
        echo "  Invalid choice, try again." >&2
    done
}

confirm() {
    # Default to yes if the user just presses Enter
    while true; do
        printf "  %s [Y/n]: " "$1" >&2
        read -r yn </dev/tty
        case "$(echo "$yn" | tr '[:upper:]' '[:lower:]')" in
            y|yes|"") return 0;;
            n|no)      return 1;;
        esac
    done
}

# confirm_move MEDIA_TYPE SRC CANDIDATES_NAMEREF EXT SE
# Shows the proposed move, prompts Y/n.  If declined, re-runs pick_option
# from the provided candidates and loops until the user confirms.
# Modifies the caller's `chosen`, `dest_name`, and `dest_dir` variables
# via bash dynamic scoping.
confirm_move() {
    local media_type="$1"   # "TV" or "Movie"
    local src="$2"
    local _cands_ref="$3"
    local ext="$4"
    local se="$5"           # season/episode tag, empty for movies
    # Bash 3.2-compatible indirect array expansion (macOS ships bash 3.2)
    eval "local _candidates=(\"\${${_cands_ref}[@]}\")"
    # `chosen`, `dest_name`, `dest_dir` are inherited from the caller's scope

    local action_label
    $COPY_MODE && action_label="Copy" || action_label="Move"

    while true; do
        echo "" >&2
        echo "  📋  Plan:" >&2
        echo "        Source : $(basename "$src")" >&2
        if [[ "$media_type" == "TV" ]]; then
            echo "        Dest   : $dest_dir/$dest_name" >&2
        else
            echo "        Dest   : $MOVIES/$dest_name" >&2
        fi

        local _skip=false
        for _ct in "${CONFIRMED_TITLES[@]:-}"; do
            [[ "$_ct" == "$chosen" ]] && _skip=true && break
        done
        if $AUTO_MODE || $_skip || confirm "$action_label this file?"; then
            CONFIRMED_TITLES+=("$chosen")
            return 0
        fi

        # User said no — offer alternatives
        echo "" >&2
        echo "  🔄  Choose a different name instead:" >&2
        chosen=$(pick_option "Pick an alternative (or enter a custom name):" "${_candidates[@]}")

        if [[ "$chosen" == "Enter a custom name" ]]; then
            if [[ "$media_type" == "TV" ]]; then
                printf "  Custom show name: " >&2
            else
                printf "  Custom name (without extension): " >&2
            fi
            read -r chosen </dev/tty
        fi

        db_save "$chosen"

        # Recompute dest paths with the new name
        if [[ "$media_type" == "TV" ]]; then
            dest_name="${chosen} ${se}.${ext}"
            local season_num
            season_num=$(echo "$se" | grep -oE '[0-9]+' | head -1)
            dest_dir="$TV/$chosen/$(printf 'Season %02d' "$((10#$season_num))")"
            mkdir -p "$dest_dir"
        else
            dest_name="${chosen}.${ext}"
        fi
    done
}

dots_to_spaces() {
    echo "$1" | sed -E 's/[._]+/ /g; s/  +/ /g; s/^ //; s/ $//'
}

title_case() {
    python3 -c "
import sys
MINOR = {'a','an','the','and','but','or','nor','for','so','yet','in','on','at','to','of','by','up'}
words = sys.stdin.read().strip().split()
result = []
for i, w in enumerate(words):
    result.append(w[0].upper() + w[1:] if (i == 0 or w.lower() not in MINOR) else w.lower())
print(' '.join(result))
" <<< "${1:-}"
}

strip_tags() {
    echo "$1" | sed -E \
        -e 's/\[EZTVx?\.to\]//gi' \
        -e 's/\[YTS\.[A-Za-z]{2,4}\]//gi' \
        -e 's/www\.[A-Za-z0-9]+\.[a-z]+ *[-–] *//gi' \
        -e 's/\[(2160p|1080p|720p|4K|WEBRip|WEB-DL|HDR|HEVC|BluRay)[^\]]*\].*//gi' \
        -e 's/\b(2160p|1080p|720p|480p|4K|UHD|HDR10?|SDR|HLG|IMAX)\b.*//gi' \
        -e 's/\b(BluRay|Blu-Ray|BDRip|WEBRip|WEB-DL|WEB|HDTV|AMZN|SCREENER|DVDRip|HDDVDRip|BRRip|REPACK|PROPER|EXTENDED|THEATRICAL|UNRATED)\b.*//gi' \
        -e 's/\b(x264|x265|H264|H265|H\.264|H\.265|HEVC|XviD|DivX|AVC)\b.*//gi' \
        -e 's/\b(DDP?5\.?1?|DTS[-.]?HD|DTS|AAC5?\.?1?|AC3|DDP|FLAC|MP3|TrueHD|Atmos)\b.*//gi' \
        -e 's/\b10[Bb]it\b.*//gi' \
        -e 's/-[A-Za-z0-9]+$//' \
        -e 's/\s*[\[\(][^\]\)]*[\]\)]\s*$//' \
        -e 's/[[:space:]]*[(\[]+[[:space:]]*$//' \
        -e 's/  +/ /g; s/^ //; s/ $//'
}

url_encode() {
    python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))" <<< "${1:-}"
}

# ── Title corrections database helpers ───────────────────────────────────────

# Normalise a title to a lookup key: lowercase, remove apostrophes/quotes/hyphens,
# collapse spaces, strip trailing year in parens.
normalise_key() {
    python3 -c "
import sys, re
t = sys.stdin.read().strip()
# Strip trailing (year)
t = re.sub(r'\s*\(\d{4}\)\s*$', '', t)
# Remove apostrophes, curly quotes, straight quotes, hyphens
t = re.sub(r\"['''\"\"-]\", '', t)
# Lowercase and collapse whitespace
t = re.sub(r'\s+', ' ', t.lower()).strip()
print(t)
" <<< "${1:-}"
}

# Look up a title in the local database. Prints the confirmed title if found,
# returns 1 if not found.
db_lookup() {
    local key
    key=$(normalise_key "$1")
    # TSV: key <TAB> confirmed title
    awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' "$DB_FILE"
}

# Save a confirmed title to the database (overwrites any existing entry for that key).
db_save() {
    local confirmed="$1"
    local key
    key=$(normalise_key "$confirmed")
    # Remove any existing entry for this key, then append
    local tmp
    tmp=$(mktemp)
    grep -v $'^('"$key"$'\t)' "$DB_FILE" > "$tmp" 2>/dev/null || true
    printf '%s\t%s\n' "$key" "$confirmed" >> "$tmp"
    mv "$tmp" "$DB_FILE"
    echo "  💾  Saved to corrections DB: \"$confirmed\"" >&2
}

# Given a list of candidates (one per line), prepend any DB hit to the front
# so it appears as the top (pre-confirmed) choice.
prepend_db_hit() {
    local guessed="$1"
    shift
    local candidates=("$@")

    local hit
    hit=$(db_lookup "$guessed") || true

    if [[ -n "$hit" ]]; then
        echo "  📖  Corrections DB match: \"$hit\"" >&2
        # Put DB hit first, then remaining candidates (deduped)
        local result=("$hit")
        for c in "${candidates[@]}"; do
            [[ "$c" == "$hit" ]] && continue
            result+=("$c")
        done
        printf '%s\n' "${result[@]}"
    else
        printf '%s\n' "${candidates[@]}"
    fi
}

# ── TVmaze lookup (TV shows — no key needed) ──────────────────────────────────

tvmaze_search() {
    local query="$1"
    local hint_year="${2:-}"
    local encoded
    encoded=$(url_encode "$query")
    local response
    response=$(curl -sf "https://api.tvmaze.com/search/shows?q=${encoded}" 2>/dev/null) || return 1

    python3 - "$response" "$hint_year" <<'PYEOF'
import sys, json
try:
    results = json.loads(sys.argv[1])
    hint_year = sys.argv[2] if len(sys.argv) > 2 else ""
    seen = set()
    labels = []
    for item in results[:5]:
        show = item.get("show", {})
        name = show.get("name", "").strip()
        premiered = show.get("premiered") or ""
        year = premiered[:4] if premiered else ""
        label = f"{name} ({year})" if year else name
        if label not in seen:
            labels.append((label, year))
            seen.add(label)
    # Sort: exact year match first, then original API order
    labels.sort(key=lambda x: (0 if hint_year and x[1] == hint_year else 1))
    for label, _ in labels:
        print(label)
except Exception:
    sys.exit(1)
PYEOF
}

# ── OMDb lookup (movies — free key required) ──────────────────────────────────

omdb_search() {
    local query="$1"
    local year="$2"
    local encoded
    encoded=$(url_encode "$query")

    local url="https://www.omdbapi.com/?apikey=${OMDB_API_KEY}&s=${encoded}&type=movie"
    [[ -n "$year" ]] && url+="&y=${year}"

    local response
    response=$(curl -sf "$url" 2>/dev/null) || return 1

    python3 - "$response" <<'EOF'
import sys, json
try:
    data = json.loads(sys.argv[1])
    if data.get("Response") != "True":
        sys.exit(1)
    seen = set()
    for item in data.get("Search", [])[:5]:
        title = item.get("Title", "").strip()
        year  = item.get("Year", "").strip().rstrip("–").rstrip("-")[:4]
        label = f"{title} ({year})" if year else title
        if label not in seen:
            print(label)
            seen.add(label)
except Exception:
    sys.exit(1)
EOF
}

# ── TV processing ─────────────────────────────────────────────────────────────

process_tv() {
    local filepath="$1"
    local filename ext stem se raw_title guessed_title show_year chosen dest_name dest_dir

    filename=$(basename "$filepath")
    ext="${filename##*.}"; ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    stem="${filename%.*}"

    # Capture multi-episode tags like S01E01E02 or S01E01-E02
    se=$(echo "$stem" | grep -ioE '[Ss][0-9]{1,2}[Ee][0-9]{1,2}(-?[Ee][0-9]{1,2})?' | head -1 | tr '[:lower:]' '[:upper:]')

    raw_title=$(echo "$stem" | sed -E 's/[. _]?[Ss][0-9]{1,2}[Ee][0-9]{1,2}(-?[Ee][0-9]{1,2})?.*//')
    raw_title=$(dots_to_spaces "$raw_title")
    raw_title=$(strip_tags "$raw_title")

    show_year=$(echo "$raw_title" | grep -oE '\(?(19|20)[0-9]{2}\)?$' | grep -oE '[0-9]{4}' || true)
    [[ -n "$show_year" ]] && raw_title=$(echo "$raw_title" | sed -E "s/ *\(?$show_year\)? *$//")

    guessed_title=$(title_case "$raw_title")

    local season_num
    season_num=$(echo "$se" | grep -oE '[0-9]+' | head -1)

    echo ""
    echo "  📺  $filename"

    # ── Build candidate list (always, so confirm_move can offer alternatives) ──
    local candidates=()
    local lookup_query="$guessed_title"

    # ── Check corrections DB first ────────────────────────────────────────────
    local db_hit
    db_hit=$(db_lookup "$guessed_title") || true
    if [[ -n "$db_hit" ]]; then
        echo "  📖  Corrections DB hit: \"$db_hit\" — skipping online lookup." >&2
        candidates+=("$db_hit")
        chosen="$db_hit"
    else
        # ── Online lookup ─────────────────────────────────────────────────────
        printf "      Looking up \"%s\" on TVmaze..." "$guessed_title" >&2
        local lookup_results
        if lookup_results=$(tvmaze_search "$lookup_query" "$show_year") && [[ -n "$lookup_results" ]]; then
            printf " found.\n" >&2
            while IFS= read -r line; do
                candidates+=("$line")
            done <<< "$lookup_results"
        else
            printf " no results.\n" >&2
        fi

        local local_guess="$guessed_title"
        [[ -n "$show_year" ]] && local_guess="$guessed_title ($show_year)"
        local found=false
        for c in "${candidates[@]:-}"; do [[ "$c" == "$local_guess" ]] && found=true && break; done
        $found || candidates+=("$local_guess")

        if $AUTO_MODE; then
            chosen="${candidates[0]}"
            echo "  🤖  Auto-selected: \"$chosen\"" >&2
        else
            candidates+=("Enter a custom name")
            chosen=$(pick_option "Choose the correct show name for this episode:" "${candidates[@]}")
            if [[ "$chosen" == "Enter a custom name" ]]; then
                printf "  Custom show name: " >&2
                read -r chosen </dev/tty
            fi
        fi

        db_save "$chosen"
    fi

    # Ensure the candidates list always ends with a custom-entry option
    # (so confirm_move can offer it if the user rejects the first choice)
    local has_custom=false
    for c in "${candidates[@]:-}"; do [[ "$c" == "Enter a custom name" ]] && has_custom=true && break; done
    $has_custom || candidates+=("Enter a custom name")

    dest_name="${chosen} ${se}.${ext}"
    dest_dir="$TV/$chosen/$(printf 'Season %02d' "$((10#$season_num))")"
    mkdir -p "$dest_dir"

    confirm_move "TV" "$filepath" candidates "$ext" "$se"

    if [[ -e "$dest_dir/$dest_name" ]]; then
        echo "  ⚠  Already exists, skipping: $dest_name  (source: $filename)"
        return
    fi

    if $DRY_RUN; then
        echo "  🔍  [dry-run] → $dest_dir/$dest_name"
        PROCESSED_FILES+=("TV  │ $dest_dir / $dest_name")
    elif $COPY_MODE; then
        cp "$filepath" "$dest_dir/$dest_name"
        PROCESSED_FILES+=("TV  │ $dest_dir / $dest_name")
        SOURCE_PATHS+=("$filepath")
        echo "  ✓  → $dest_dir/$dest_name"
    else
        mv "$filepath" "$dest_dir/$dest_name"
        PROCESSED_FILES+=("TV  │ $dest_dir / $dest_name")
        SOURCE_PATHS+=("$filepath")
        echo "  ✓  → $dest_dir/$dest_name"
    fi
}

# ── Movie processing ──────────────────────────────────────────────────────────

process_movie() {
    local filepath="$1"
    local filename ext stem raw year title candidates chosen dest_name

    filename=$(basename "$filepath")
    ext="${filename##*.}"; ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    stem="${filename%.*}"

    raw=$(dots_to_spaces "$stem")
    raw=$(echo "$raw" | sed -E 's/^www\.[^ ]+ +[-–] +//i')
    raw=$(strip_tags "$raw")

    year=$(echo "$raw" | grep -oE '(19|20)[0-9]{2}' | head -1 || true)
    if [[ -n "$year" ]]; then
        title=$(echo "$raw" | sed -E "s/ *[,]? *\(?[[:space:]]*$year\)?.*//")
    else
        title="$raw"
    fi
    title=$(echo "$title" | sed -E 's/ +$//; s/^ +//')
    title=$(title_case "$title")

    echo ""
    echo "  📽  $filename"

    # ── Build candidate list (always, so confirm_move can offer alternatives) ──
    candidates=()

    # ── Online lookup ─────────────────────────────────────────────────────────
    if [[ -n "$OMDB_API_KEY" ]]; then
        printf "      Looking up \"%s\" on OMDb..." "$title" >&2
        local lookup_results
        if lookup_results=$(omdb_search "$title" "$year") && [[ -n "$lookup_results" ]]; then
            printf " found.\n" >&2
            while IFS= read -r line; do
                candidates+=("$line")
            done <<< "$lookup_results"
        else
            printf " no results.\n" >&2
        fi
    else
        echo "      (OMDb key not set — skipping online lookup)" >&2
    fi

    local local_with_year local_without
    [[ -n "$year" ]] && local_with_year="$title ($year)" || local_with_year=""
    local_without="$title"

    for candidate in "$local_with_year" "$local_without"; do
        [[ -z "$candidate" ]] && continue
        local found=false
        for c in "${candidates[@]:-}"; do [[ "$c" == "$candidate" ]] && found=true && break; done
        $found || candidates+=("$candidate")
    done

    if $AUTO_MODE; then
        chosen="${candidates[0]}"
        echo "  🤖  Auto-selected: \"$chosen\"" >&2
    else
        candidates+=("Enter a custom name")
        chosen=$(pick_option "Choose the correct movie name:" "${candidates[@]}")
        if [[ "$chosen" == "Enter a custom name" ]]; then
            printf "  Custom name (without extension): " >&2
            read -r chosen </dev/tty
        fi
    fi

    # Ensure custom-entry option is always available for confirm_move
    local has_custom=false
    for c in "${candidates[@]:-}"; do [[ "$c" == "Enter a custom name" ]] && has_custom=true && break; done
    $has_custom || candidates+=("Enter a custom name")

    dest_name="${chosen}.${ext}"

    confirm_move "Movie" "$filepath" candidates "$ext" ""

    if [[ -e "$MOVIES/$dest_name" ]]; then
        echo "  ⚠  Already exists, skipping: $dest_name  (source: $filename)"
        return
    fi

    if $DRY_RUN; then
        echo "  🔍  [dry-run] → $MOVIES/$dest_name"
        PROCESSED_FILES+=("Movie │ $dest_name")
    elif $COPY_MODE; then
        cp "$filepath" "$MOVIES/$dest_name"
        PROCESSED_FILES+=("Movie │ $dest_name")
        SOURCE_PATHS+=("$filepath")
        echo "  ✓  → $MOVIES/$dest_name"
    else
        mv "$filepath" "$MOVIES/$dest_name"
        PROCESSED_FILES+=("Movie │ $dest_name")
        SOURCE_PATHS+=("$filepath")
        echo "  ✓  → $MOVIES/$dest_name"
    fi
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

process_file() {
    is_video "$1" || return 0
    local stem; stem=$(basename "${1%.*}")
    if echo "$stem" | grep -qiE '[Ss][0-9]{1,2}[Ee][0-9]{1,2}(-?[Ee][0-9]{1,2})?'; then
        process_tv "$1"
    else
        process_movie "$1"
    fi
}

# ── Source cleanup helper ─────────────────────────────────────────────────────
# Removes source files (copy mode only) and their containing subdirectories
# (anything that was inside ~/Downloads/<subfolder>). Never deletes $DOWNLOADS
# itself or standalone files' siblings that weren't processed.

cleanup_sources() {
    echo ""
    echo "🧹  Cleaning up sources..."

    local dirs_to_check=()

    for src in "${SOURCE_PATHS[@]}"; do
        local parent
        parent=$(dirname "$src")

        if [[ "$parent" == "$DOWNLOADS" ]]; then
            # Standalone file — in copy mode it still exists, remove it
            if $COPY_MODE && [[ -f "$src" ]]; then
                rm "$src"
                echo "  🗑  Removed: $(basename "$src")"
            fi
            # In move mode the file is already gone; nothing to do
        else
            # File was inside a subfolder — record the subfolder for bulk removal
            dirs_to_check+=("$parent")
        fi
    done

    # Remove each unique subfolder and all its remaining contents
    if [[ ${#dirs_to_check[@]} -gt 0 ]]; then
        local unique_dirs
        unique_dirs=$(printf '%s\n' "${dirs_to_check[@]}" | sort -u)
        while IFS= read -r dir; do
            [[ -z "$dir" ]] && continue
            if [[ -d "$dir" ]] && [[ "$dir" != "$DOWNLOADS" ]]; then
                find "$dir" -mindepth 1 -delete 2>/dev/null || true
                rmdir "$dir" 2>/dev/null && echo "  🗑  Removed dir: $(basename "$dir")" || true
            fi
        done <<< "$unique_dirs"
    fi

    echo "✓   Done."
}

# ── Media library summary ─────────────────────────────────────────────────────

media_summary() {
    local movies_dir="$HOME/media/Movies"
    local tv_dir="$HOME/media/TV"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📚  Media Library"
    echo ""

    local movies=()
    if [[ -d "$movies_dir" ]]; then
        while IFS= read -r -d '' f; do
            is_video "$f" || continue
            movies+=("$(basename "$f")")
        done < <(find "$movies_dir" -maxdepth 1 -type f -print0 | sort -z)
    fi

    if [[ ${#movies[@]} -eq 0 ]]; then
        echo "  🎬  Movies: (none)"
    else
        echo "  🎬  Movies (${#movies[@]}):"
        for m in "${movies[@]}"; do
            echo "       ${m%.*}"
        done
    fi

    echo ""

    local show_dirs=()
    if [[ -d "$tv_dir" ]]; then
        while IFS= read -r -d '' d; do
            show_dirs+=("$d")
        done < <(find "$tv_dir" -maxdepth 1 -mindepth 1 -type d -print0 | sort -z)
    fi

    if [[ ${#show_dirs[@]} -eq 0 ]]; then
        echo "  📺  TV Shows: (none)"
    else
        echo "  📺  TV Shows (${#show_dirs[@]}):"
        for show_dir in "${show_dirs[@]}"; do
            local season_count episode_count
            season_count=$(find "$show_dir" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
            episode_count=$(find "$show_dir" -type f | wc -l | tr -d ' ')
            printf "       %-50s  %s season(s), %s ep(s)\n" \
                "$(basename "$show_dir")" "$season_count" "$episode_count"
        done
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── Warn if OMDb key is missing ───────────────────────────────────────────────

if [[ -z "$OMDB_API_KEY" ]]; then
    echo ""
    echo "  ⚠  OMDB_API_KEY is not set. Movie lookups will be skipped."
    echo "     Get a free key at: https://www.omdbapi.com/apikey.aspx"
    echo "     To store it permanently:"
    echo "       echo 'OMDB_API_KEY=yourkey' >> $CONFIG_FILE"
    echo ""
fi

mkdir -p "$MOVIES" "$TV"

if $SHOW_MEDIA; then
    media_summary
    exit 0
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎬  organise_media.sh"
$DRY_RUN  && echo "    [dry-run mode — no files will be moved]" || true
$COPY_MODE && echo "    [copy mode]" || true
$AUTO_MODE && echo "    [auto mode — accepting first match]" || true
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Top-level files
while IFS= read -r -d '' f; do
    process_file "$f"
done < <(find "$DOWNLOADS/" -maxdepth 1 -type f -print0)

# Subdirectories (multi-file packs)
while IFS= read -r -d '' d; do
    echo ""
    echo "  📁 Folder: $(basename "$d")"
    while IFS= read -r -d '' f; do
        process_file "$f"
    done < <(find "$d/" -type f -print0)
done < <(find "$DOWNLOADS/" -maxdepth 1 -mindepth 1 -type d -print0)

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if $DRY_RUN; then
    echo "🔍  [dry-run] Would process ${#PROCESSED_FILES[@]} file(s):"
elif $COPY_MODE; then
    echo "✅  Copied ${#PROCESSED_FILES[@]} file(s):"
else
    echo "✅  Moved ${#PROCESSED_FILES[@]} file(s):"
fi
echo ""
for f in "${PROCESSED_FILES[@]}"; do echo "   $f"; done
echo ""

if ! $DRY_RUN && (( ${#SOURCE_PATHS[@]} > 0 )); then
    cleanup_sources
    echo ""
fi

if ! $DRY_RUN; then
    media_summary
fi

echo "  Other commands:"
echo "  bash organise_media.sh --show-db    # view corrections database"
echo "  bash organise_media.sh --edit-db    # edit corrections database"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
