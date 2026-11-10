#!/bin/sh
# Run from any directory. No network, installation, or publishing.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$ROOT/scripts/check_site.py" "${1:-$ROOT/site}"
