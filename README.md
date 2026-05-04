# organise_media

A pair of Bash scripts that rename and sort video downloads into a clean `Movies` / `TV` library, with automatic title lookups via TVmaze and OMDb.

## Scripts

| Script | For | Output |
|---|---|---|
| `organise_media.sh` | Mac | `~/Temp/Movies` and `~/Temp/TV`, then rsync to Pi |
| `organise_media_pi.sh` | Raspberry Pi | `~/media/Movies` and `~/media/TV` |

## How it works

1. Scans `~/Downloads` for video files (mkv, mp4, avi, m4v, mov, wmv, mpg, mpeg)
2. Detects TV episodes by `SxxExx` pattern; everything else is treated as a movie
3. Strips quality tags, codec strings, release group suffixes, and site watermarks from filenames
4. Looks up the clean title against TVmaze (TV) or OMDb (movies) and presents matches to confirm
5. Renames and moves the file into the correct folder:
   - TV: `~/Temp/TV/<Show Name (Year)>/Season XX/<Show Name (Year)> SxxExx.ext`
   - Movies: `~/Temp/Movies/<Movie Title (Year)>.ext`
6. Saves confirmed titles to a local corrections database so repeat runs skip the API lookup
7. After processing, the Mac script rsyncs the sorted files to `pi:media/` and clears `~/Temp`

## Requirements

- `bash` (3.2+, macOS default is fine)
- `curl`
- `python3`
- OMDb API key for movie lookups — free at https://www.omdbapi.com/apikey.aspx
- SSH alias `pi` configured in `~/.ssh/config` (Mac script only)

## Setup

```bash
# Store your OMDb key permanently
echo 'OMDB_API_KEY=yourkey' >> ~/.config/organise_media/config

# Or export it in your shell profile
export OMDB_API_KEY=yourkey
```

## Usage

```
bash organise_media.sh [OPTIONS]
```

### Run options (combinable)

| Flag | Description |
|---|---|
| `--dry-run` | Preview what would happen without touching any files |
| `--copy` | Copy files instead of moving them |
| `--auto` | Accept the first API match without prompting |

### Utility commands (sole argument)

| Flag | Description |
|---|---|
| `--show-db` | Print the local title-corrections database |
| `--edit-db` | Open the corrections database in `$EDITOR` |
| `--cleanup` | Delete everything inside `~/Downloads` |
| `--show-media` | Show a summary of the media library (movie and TV episode counts) |

## Title corrections database

Confirmed titles are cached in `~/.config/organise_media/title_corrections.tsv`. The key is a normalised form of the title (lowercase, no apostrophes/hyphens) so that `bobs burgers` maps back to `Bob's Burgers (2011)` on every subsequent run without hitting the network.

Use `--show-db` to inspect it and `--edit-db` to fix any wrong entries.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `MEDIA` | `~/Temp` | Base output directory |
| `OMDB_API_KEY` | _(none)_ | OMDb API key for movie lookups |
| `EDITOR` | `nano` | Editor opened by `--edit-db` |
