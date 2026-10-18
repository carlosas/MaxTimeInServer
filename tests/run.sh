#!/usr/bin/env bash
# Runs every tests/test_*.lua with a Lua 5.1-compatible interpreter.
set -u
cd "$(dirname "$0")/.."

LUA=""
for candidate in luajit lua5.1 lua; do
    if command -v "$candidate" >/dev/null 2>&1; then LUA="$candidate"; break; fi
done
if [ -z "$LUA" ]; then
    echo "No Lua interpreter found. Install one, e.g. 'brew install luajit'." >&2
    exit 127
fi

status=0
for test_file in tests/test_*.lua; do
    "$LUA" "$test_file" || status=1
done
exit "$status"
