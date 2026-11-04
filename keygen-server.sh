#!/usr/bin/env bash
# Old entry point, kept so existing notes and habits still work. It only calls
# ./tunnel.sh keygen server (see "Coming from the old scripts" in the README) and can go
# in a later release.
echo "keygen-server.sh is now: ./tunnel.sh keygen server" >&2
exec "$(dirname "$0")/tunnel.sh" keygen server "$@"
