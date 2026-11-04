#!/usr/bin/env bash
# Old entry point, kept so existing notes and habits still work. It only calls
# ./tunnel.sh start server --foreground (see "Coming from the old scripts" in the README) and can go
# in a later release.
echo "run-server.sh is now: ./tunnel.sh start server --foreground" >&2
exec "$(dirname "$0")/tunnel.sh" start server --foreground "$@"
