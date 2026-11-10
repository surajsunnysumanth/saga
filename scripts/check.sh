#!/bin/bash
# CI gate for macOS with Swift 6, Git and Python 3. No user archive required.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_repository.py
python3 -m unittest discover -s scripts/tests -v
swift build -c release
swift test
