#!/usr/bin/env bash
# Rebuild a small Tinderbox smoke document via AppleScript.
#
# Creates a NEW Tinderbox document. Never addresses "front document".
# Refuses Desktop / playground paths and the golden corpus filename.
# Not used by CI. Requires Tinderbox 11 on macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_OUT="$ROOT/fixtures/mini-tinderbox/Grok-Bot-Feature-Corpus.seeded.tbx"
DEST="${1:-$DEFAULT_OUT}"
SCRIPT="$ROOT/scripts/seed-tinderbox-corpus.applescript"

die() {
  echo "seed-tinderbox-corpus: $*" >&2
  exit 1
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  die "macOS + Tinderbox 11 only"
fi

if [[ ! -f "$SCRIPT" ]]; then
  die "missing $SCRIPT"
fi

DEST="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$DEST")"
GOLDEN="$ROOT/fixtures/mini-tinderbox/Grok-Bot-Feature-Corpus.tbx"

case "$DEST" in
  */Desktop|*/Desktop/*)
    die "refusing Desktop paths (do not retarget playground docs)"
    ;;
esac
case "$DEST" in
  *grokbot-tinderboris*)
    die "refusing playground tree"
    ;;
esac
case "$DEST" in
  "$ROOT"/*) ;;
  *) die "destination must be inside the repository ($ROOT)" ;;
esac
if [[ "$DEST" == "$GOLDEN" ]]; then
  die "refusing to overwrite the golden corpus; pass a new filename"
fi
case "$DEST" in
  *.tbx) ;;
  *) die "destination must end in .tbx" ;;
esac

mkdir -p "$(dirname "$DEST")"

echo "seed-tinderbox-corpus: creating a new document at $DEST" >&2
osascript "$SCRIPT" "$DEST"
echo "seed-tinderbox-corpus: saved $DEST" >&2
echo "Text links, aliases, and HTML bold/italic still need a manual Tinderbox UI pass." >&2
