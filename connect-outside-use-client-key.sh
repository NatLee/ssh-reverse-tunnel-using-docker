#!/usr/bin/env bash
# Old entry point, kept so existing notes and habits still work. It only calls
# ./tunnel.sh connect-outside (see "Coming from the old scripts" in the README) and can go
# in a later release.
echo "connect-outside-use-client-key.sh is now: ./tunnel.sh connect-outside" >&2
exec "$(dirname "$0")/tunnel.sh" connect-outside "$@"
