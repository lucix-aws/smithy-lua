#!/bin/bash
# Build script: compiles all .tl files to .lua in-place
# Usage: ./build.sh [--check]
#
# The .tl source files live alongside .lua files. When a .tl file exists,
# it is the source of truth and its compiled .lua output replaces the old .lua.
# Files that only have .lua (no .tl equivalent) are left untouched.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/runtime"
TL="${TL:-tl}"

# Verify tl is available
if ! command -v "$TL" &>/dev/null; then
    # Try common locations
    if [ -x "$HOME/.luarocks/bin/tl" ]; then
        TL="$HOME/.luarocks/bin/tl"
    else
        echo "Error: tl compiler not found. Install with: luarocks install tl" >&2
        exit 1
    fi
fi

cd "$RUNTIME_DIR"

CHECK_ONLY=false
if [ "$1" = "--check" ]; then
    CHECK_ONLY=true
fi

ERRORS=0
COUNT=0

# Find all .tl files
while IFS= read -r -d '' tl_file; do
    COUNT=$((COUNT + 1))
    lua_file="${tl_file%.tl}.lua"

    if [ "$CHECK_ONLY" = true ]; then
        if ! "$TL" check -I types -I smithy "$tl_file" 2>&1 | grep -q "0 errors"; then
            echo "FAIL: $tl_file"
            "$TL" check -I types -I smithy "$tl_file" 2>&1 | grep -E "error"
            ERRORS=$((ERRORS + 1))
        fi
    else
        if ! "$TL" gen -I types -I smithy --gen-target=5.1 --gen-compat=off "$tl_file" -o "$lua_file" 2>&1; then
            echo "FAIL: $tl_file"
            ERRORS=$((ERRORS + 1))
        fi
    fi
done < <(find smithy -name "*.tl" -print0)

if [ "$CHECK_ONLY" = true ]; then
    echo "Checked $COUNT .tl files, $ERRORS errors"
else
    echo "Compiled $COUNT .tl files to .lua, $ERRORS errors"
fi

[ $ERRORS -eq 0 ]
