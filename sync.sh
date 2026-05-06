#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# sync.sh
# Default mode: exports maraoke_production from remote dokku -> imports to
#   local maraoke_development, then downloads missing files from MEDIA_BASE_URL.
#
# JSON mode (--json <file>): skips the DB steps entirely and uses a manifest
#   JSON file (from /admin/sync_manifest) to determine which files to fetch.
#   Usage: ./sync.sh --json sync_manifest.json
# ---------------------------------------------------------------------------

JSON_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Load .env from same directory as this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
else
  echo "ERROR: .env file not found at $ENV_FILE" >&2
  exit 1
fi

MEDIA_BASE_URL="${MEDIA_BASE_URL:-https://media.maraoke.com/uploads}"
LOCAL_UPLOADS="$SCRIPT_DIR/public/uploads"

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------
download_list() {
  local list="$1" verbose="$2"
  local fail_count=0

  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    local dest="$LOCAL_UPLOADS/$rel"
    mkdir -p "$(dirname "$dest")"
    if [[ "$verbose" == "true" ]]; then
      curl --fail --location --retry 3 --retry-delay 5 \
        -o "$dest" "$MEDIA_BASE_URL/$rel" 2>&1 | tee -a "$SCRIPT_DIR/ftp_sync.log" || { (( fail_count++ )) || true; }
    else
      if ! curl --fail --silent --location --retry 3 --retry-delay 5 \
          -o "$dest" "$MEDIA_BASE_URL/$rel" 2>>"$SCRIPT_DIR/ftp_sync.log"; then
        (( fail_count++ )) || true
      fi
    fi
  done < "$list"

  echo "$fail_count"
}

run_downloads() {
  local core_list="$1" other_list="$2"
  local other_fail_count=0

  if [[ ! -s "$core_list" && ! -s "$other_list" ]]; then
    echo "    All files already present locally — nothing to download."
  else
    if [[ -s "$core_list" ]]; then
      local core_count
      core_count=$(wc -l < "$core_list" | tr -d ' ')
      echo "    $core_count missing file(s) for All-tagged songs. Downloading..."
      download_list "$core_list" "true" > /dev/null
    fi

    if [[ -s "$other_list" ]]; then
      local other_count
      other_count=$(wc -l < "$other_list" | tr -d ' ')
      echo "    $other_count missing file(s) for non-All songs. Downloading silently..."
      other_fail_count=$(download_list "$other_list" "false")
    fi
  fi

  rm -f "$core_list" "$other_list"

  echo ""
  echo "✓ File sync done. See ftp_sync.log for details."
  if [[ "$other_fail_count" -gt 0 ]]; then
    echo "  Note: $other_fail_count file(s) failed for non-All songs (see log)."
  fi
}

mkdir -p "$LOCAL_UPLOADS"

# ---------------------------------------------------------------------------
# JSON mode: skip DB, read file lists from manifest
# ---------------------------------------------------------------------------
if [[ -n "$JSON_FILE" ]]; then
  if [[ ! -f "$JSON_FILE" ]]; then
    echo "ERROR: JSON file not found: $JSON_FILE" >&2
    exit 1
  fi
  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required for --json mode. Install it with: brew install jq" >&2
    exit 1
  fi

  echo "==> Using manifest: $JSON_FILE (skipping DB sync)"

  CORE_LIST=$(mktemp)
  OTHER_LIST=$(mktemp)

  jq -r '.core[]'  "$JSON_FILE" | while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    [[ ! -f "$LOCAL_UPLOADS/$rel" ]] && echo "$rel"
  done > "$CORE_LIST"

  jq -r '.other[]' "$JSON_FILE" | while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    [[ ! -f "$LOCAL_UPLOADS/$rel" ]] && echo "$rel"
  done > "$OTHER_LIST"

  run_downloads "$CORE_LIST" "$OTHER_LIST"
  exit 0
fi

# ---------------------------------------------------------------------------
# Default mode: DB sync + file download
# ---------------------------------------------------------------------------

PROD_DB="maraoke_production"
DEV_DB="maraoke_development"
DUMP_FILE="/tmp/maraoke_$(date +%Y%m%d_%H%M%S).dump"
TODAY_SUFFIX=$(date +%Y%m%d)
ARCHIVE_DB="${DEV_DB}_${TODAY_SUFFIX}"

ACTIVE_CONNECTIONS=$(psql -qAt -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '$DEV_DB' AND pid <> pg_backend_pid();" postgres 2>/dev/null || echo 0)

if [[ "$ACTIVE_CONNECTIONS" -gt 0 ]]; then
  echo ""
  echo "ERROR: $DEV_DB has $ACTIVE_CONNECTIONS active connection(s)." >&2
  echo "       Close all connections (Rails server, psql, etc.) and try again." >&2
  echo ""
  psql -c "SELECT pid, application_name, client_addr, state FROM pg_stat_activity WHERE datname = '$DEV_DB' AND pid <> pg_backend_pid();" postgres 2>/dev/null || true
  echo ""
  exit 1
fi

echo "==> Exporting $PROD_DB from remote dokku..."
dokku postgres:export "$PROD_DB" > "$DUMP_FILE"
echo "    Dump saved to $DUMP_FILE"

db_exists() { psql -lqt | cut -d\| -f1 | grep -qw "$1"; }

if db_exists "$DEV_DB"; then
  if db_exists "$ARCHIVE_DB"; then
    echo "==> Archive $ARCHIVE_DB already exists — dropping $DEV_DB without archiving..."
    dropdb "$DEV_DB"
  else
    echo "==> Archiving local $DEV_DB -> $ARCHIVE_DB..."
    createdb -T "$DEV_DB" "$ARCHIVE_DB"
    dropdb "$DEV_DB"
  fi
else
  echo "==> Local $DEV_DB not found, skipping archive step."
fi

echo "==> Creating fresh local $DEV_DB..."
createdb "$DEV_DB"

echo "==> Importing dump into local $DEV_DB..."
pg_restore --no-owner --no-privileges -d "$DEV_DB" "$DUMP_FILE" 2>/dev/null \
  || psql --quiet "$DEV_DB" < "$DUMP_FILE"

echo "==> Cleaning up dump file..."
rm -f "$DUMP_FILE"

echo ""
echo "✓ DB done — local $DEV_DB is now a fresh copy of remote $PROD_DB."

echo ""
echo "==> Checking database for missing files..."

ALL_TAG_ID=1
CORE_LIST=$(mktemp)
OTHER_LIST=$(mktemp)

build_list() {
  local out="$1" tag_filter="$2"
  psql -qAt "$DEV_DB" -c "
    SELECT 'song/cdg_file/' || audiofile
      FROM songs WHERE audiofile IS NOT NULL AND audiofile != '' AND $tag_filter
    UNION
    SELECT 'song/cdg_file/' || cdg_file
      FROM songs WHERE cdg_file IS NOT NULL AND cdg_file != '' AND $tag_filter
    UNION
    SELECT 'song/cdg_file/' || vocalfile
      FROM songs WHERE vocalfile IS NOT NULL AND vocalfile != '' AND $tag_filter
    UNION
    SELECT 'song/cdg_file/' || secondinstrumentalfile
      FROM songs WHERE secondinstrumentalfile IS NOT NULL AND secondinstrumentalfile != '' AND $tag_filter
    UNION
    SELECT 'song/background_video/' || id || '/' || background_video
      FROM songs WHERE background_video IS NOT NULL AND background_video != '' AND $tag_filter
    UNION
    SELECT 'song/images/' || song_id || '/' || image
      FROM images WHERE image IS NOT NULL AND image != ''
        AND song_id IN (SELECT id FROM songs WHERE $tag_filter)
  " | while IFS= read -r rel; do
    if [[ -z "$rel" ]]; then continue; fi
    if [[ ! -f "$LOCAL_UPLOADS/$rel" ]]; then echo "$rel"; fi
  done >> "$out"
}

build_list "$CORE_LIST"  "id IN     (SELECT song_id FROM songs_tags WHERE tag_id = $ALL_TAG_ID)"
build_list "$OTHER_LIST" "id NOT IN (SELECT song_id FROM songs_tags WHERE tag_id = $ALL_TAG_ID)"

run_downloads "$CORE_LIST" "$OTHER_LIST"
