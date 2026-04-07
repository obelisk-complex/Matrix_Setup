#!/usr/bin/env bash
# Matrix Stack Setup - TOML Parser
# Parses TOML config files into a Bash associative array.
# Tries Python 3.11+ tomllib first, falls back to pure-Bash subset parser.
set -euo pipefail

# Global associative array for parsed values
declare -gA TOML_VALUES=()

# --- Public API ---

# Parse a TOML file. Populates TOML_VALUES with dotted keys.
# Usage: toml_parse_file "/path/to/config.toml"
toml_parse_file() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        log_error "TOML file not found: $file"
        return 1
    fi

    TOML_VALUES=()

    # Try Python 3.11+ tomllib first (fast, correct)
    if _toml_parse_python "$file" 2>/dev/null; then
        log_debug "TOML parsed via Python tomllib"
        return 0
    fi

    # Fallback to pure-Bash parser
    log_debug "Python tomllib unavailable, using Bash TOML parser"
    _toml_parse_bash "$file"
}

# Get a value by dotted key. Returns empty string if not found.
toml_get() {
    local key="$1"
    echo "${TOML_VALUES[$key]:-}"
}

# Check if a key exists.
toml_has() {
    local key="$1"
    [[ -v "TOML_VALUES[$key]" ]]
}

# Get array values. Returns newline-separated items.
toml_get_array() {
    local key="$1"
    local val="${TOML_VALUES[$key]:-}"
    if [[ -z "$val" ]]; then
        return 0
    fi
    # Arrays are stored as comma-separated values
    echo "$val" | tr ',' '\n'
}

# --- Python backend ---

_toml_parse_python() {
    local file="$1"
    local py_script
    py_script=$(cat << 'PYTHON'
import sys, tomllib, json

def flatten(d, prefix=""):
    items = {}
    for k, v in d.items():
        key = f"{prefix}.{k}" if prefix else k
        if isinstance(v, dict):
            items.update(flatten(v, key))
        elif isinstance(v, list):
            items[key] = ",".join(str(i) for i in v)
        elif isinstance(v, bool):
            items[key] = "true" if v else "false"
        else:
            items[key] = str(v)
    return items

with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)

for k, v in flatten(data).items():
    # Output as KEY=VALUE, one per line
    print(f"{k}={v}")
PYTHON
    )

    local output
    output=$(python3 -c "$py_script" "$file")
    local line key val
    while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"
        TOML_VALUES["$key"]="$val"
    done <<< "$output"
}

# --- Pure-Bash parser (subset: strings, ints, bools, arrays, tables) ---

# Strip trailing comment only if the '#' is outside quotes.
_toml_strip_comment() {
    local line="$1"
    local in_dquote=false in_squote=false i char result=""

    for (( i=0; i<${#line}; i++ )); do
        char="${line:$i:1}"
        if [[ "$char" == '"' && "$in_squote" == false ]]; then
            in_dquote=$( [[ "$in_dquote" == true ]] && echo false || echo true )
        elif [[ "$char" == "'" && "$in_dquote" == false ]]; then
            in_squote=$( [[ "$in_squote" == true ]] && echo false || echo true )
        elif [[ "$char" == '#' && "$in_dquote" == false && "$in_squote" == false ]]; then
            break
        fi
        result+="$char"
    done

    # Trim trailing whitespace
    result="${result%"${result##*[![:space:]]}"}"
    echo "$result"
}

_toml_parse_bash() {
    local file="$1"
    local current_table=""
    local line_num=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))

        # Trim leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Strip comments only outside quoted strings
        line=$(_toml_strip_comment "$line")

        # Skip empty lines
        [[ -z "$line" ]] && continue

        # Table header: [section] or [section.subsection]
        if [[ "$line" =~ ^\[([a-zA-Z0-9._-]+)\]$ ]]; then
            current_table="${BASH_REMATCH[1]}"
            continue
        fi

        # Key = Value
        if [[ "$line" =~ ^([a-zA-Z0-9_-]+)[[:space:]]*=[[:space:]]*(.*) ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            # Build full dotted key
            local full_key
            if [[ -n "$current_table" ]]; then
                full_key="${current_table}.${key}"
            else
                full_key="$key"
            fi

            # Parse value
            value=$(_toml_parse_value "$value")
            TOML_VALUES["$full_key"]="$value"
            continue
        fi

        log_debug "TOML parser: skipping unrecognized line $line_num: $line"
    done < "$file"
}

_toml_parse_value() {
    local raw="$1"

    # Trim whitespace
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"

    # Quoted string (double quotes)
    if [[ "$raw" =~ ^\"(.*)\"$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi

    # Quoted string (single quotes)
    if [[ "$raw" =~ ^\'(.*)\'$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi

    # Boolean
    if [[ "$raw" == "true" || "$raw" == "false" ]]; then
        echo "$raw"
        return
    fi

    # Integer
    if [[ "$raw" =~ ^-?[0-9]+$ ]]; then
        echo "$raw"
        return
    fi

    # Array: ["val1", "val2", ...]
    if [[ "$raw" =~ ^\[.*\]$ ]]; then
        # Remove brackets
        local inner="${raw:1:${#raw}-2}"
        # Parse comma-separated items, strip quotes and whitespace
        local result=""
        IFS=',' read -ra items <<< "$inner"
        for item in "${items[@]}"; do
            item=$(echo "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            # Strip quotes
            item="${item#\"}"
            item="${item%\"}"
            item="${item#\'}"
            item="${item%\'}"
            if [[ -n "$result" ]]; then
                result="${result},${item}"
            else
                result="$item"
            fi
        done
        echo "$result"
        return
    fi

    # Bare string (fallback)
    echo "$raw"
}
