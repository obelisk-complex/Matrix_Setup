#!/usr/bin/env bash
# Asserts that every function name passed to `run_phase` in setup.sh
# resolves to a function defined in setup.sh or lib/*.sh.
#
# This catches the "renamed function, forgot to update the call site"
# class of bug, where the call would otherwise fail at runtime under
# `set -e` (exit code 127) or, worse, succeed under `if !` and silently
# skip the phase.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SETUP="$PROJECT_DIR/setup.sh"

# Collect every defined function across setup.sh + lib/*.sh.
defined=$(
    grep -hE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)' \
        "$SETUP" "$PROJECT_DIR"/lib/*.sh \
        | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\).*/\1/' \
        | sort -u
)

# Collect every run_phase callee from setup.sh.
# Format we accept: run_phase "Phase name"   callee_fn
callees=$(
    grep -E '^[[:space:]]*run_phase[[:space:]]+"[^"]+"[[:space:]]+[A-Za-z_]' "$SETUP" \
        | sed -E 's/^[[:space:]]*run_phase[[:space:]]+"[^"]+"[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\1/'
)

n=0
fails=0
while IFS= read -r callee; do
    [[ -z "$callee" ]] && continue
    n=$((n + 1))
    if grep -qxF "$callee" <<< "$defined"; then
        printf 'ok %d - run_phase callee %s is defined\n' "$n" "$callee"
    else
        printf 'not ok %d - run_phase callee %s is NOT defined\n' "$n" "$callee"
        fails=$((fails + 1))
    fi
done <<< "$callees"

if [[ $n -eq 0 ]]; then
    printf 'not ok 1 - no run_phase callees discovered (regex drift?)\n'
    exit 1
fi

printf '# %d run_phase callees checked, %d unresolved\n' "$n" "$fails"
exit $(( fails == 0 ? 0 : 1 ))
