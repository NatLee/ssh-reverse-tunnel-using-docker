#!/usr/bin/env bash
# Old entry point, kept so existing notes and habits still work. It only calls
# ./tunnel.sh keygen client (see "Coming from the old scripts" in the README) and can go
# in a later release.
echo "keygen.sh is now: ./tunnel.sh keygen client" >&2
exec "$(dirname "$0")/tunnel.sh" keygen client "$@"
