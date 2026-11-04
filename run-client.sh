#!/usr/bin/env bash
# Old entry point, kept so existing notes and habits still work. It only calls
# ./tunnel.sh start client --foreground (see "Coming from the old scripts" in the README) and can go
# in a later release.
echo "run-client.sh is now: ./tunnel.sh start client --foreground" >&2
exec "$(dirname "$0")/tunnel.sh" start client --foreground "$@"
