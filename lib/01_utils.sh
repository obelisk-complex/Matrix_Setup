#!/usr/bin/env bash
# Matrix Stack Setup - Utilities
# Logging, prompts, template rendering, error handling.
set -euo pipefail

# --- Globals set by setup.sh ---
QUIET="${QUIET:-false}"
HEADLESS="${HEADLESS:-false}"
TOTAL_STEPS="${TOTAL_STEPS:-0}"
CURRENT_STEP=0

# --- Logging ---

log_info() {
    printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"
}

log_warn() {
    printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

log_error() {
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
}

log_success() {
    printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        printf '%s[DEBUG]%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2
    fi
}

log_verbose() {
    if [[ "$QUIET" != "true" ]]; then
        printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"
    fi
}

log_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    printf '\n%s[%d/%d]%s %s%s%s\n' "$C_CYAN" "$CURRENT_STEP" "$TOTAL_STEPS" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"
}

log_substep() {
    printf '  %s->%s %s\n' "$C_DIM" "$C_RESET" "$*"
}

log_banner() {
    printf '\n%s%s' "$C_BOLD" "$C_CYAN"
    cat << 'BANNER'
  __  __       _        _        ____       _
 |  \/  | __ _| |_ _ __(_)_  __ / ___|  ___| |_ _   _ _ __
 | |\/| |/ _` | __| '__| \ \/ / \___ \ / _ \ __| | | | '_ \
 | |  | | (_| | |_| |  | |>  <   ___) |  __/ |_| |_| | |_) |
 |_|  |_|\__,_|\__|_|  |_/_/\_\ |____/ \___|\__|\__,_| .__/
                                                       |_|
BANNER
    printf '%s  v%s\n\n' "$C_RESET" "$MATRIX_SETUP_VERSION"
}

# --- Prompts ---

# Read a value from the user, with a default. Returns the value on stdout.
# Usage: value=$(prompt_value "Enter domain" "example.com")
prompt_value() {
    local question="$1"
    local default="${2:-}"
    local value

    if [[ "$HEADLESS" == "true" ]]; then
        echo "$default"
        return 0
    fi

    # The function is invoked via $(prompt_value ...) which captures stdout.
    # Send the prompt to stderr so the user actually sees it, and read with
    # -e for readline line-editing (so backspace/arrow keys behave instead
    # of being captured as raw escape sequences).
    if [[ -n "$default" ]]; then
        printf '%s [%s%s%s]: ' "$question" "$C_CYAN" "$default" "$C_RESET" >&2
    else
        printf '%s: ' "$question" >&2
    fi
    read -er value
    echo "${value:-$default}"
}

# Read a password (hidden input). Returns on stdout.
prompt_password() {
    local question="$1"
    local value

    if [[ "$HEADLESS" == "true" ]]; then
        echo ""
        return 0
    fi

    printf '%s: ' "$question" >&2
    read -rs value
    printf '\n' >&2
    echo "$value"
}

# Yes/no confirmation. Returns 0 for yes, 1 for no.
# Usage: confirm_prompt "Enable federation?" "y" && do_thing
confirm_prompt() {
    local question="$1"
    local default="${2:-y}" # y or n
    local answer

    if [[ "$HEADLESS" == "true" ]]; then
        [[ "$default" == "y" ]] && return 0 || return 1
    fi

    local hint
    if [[ "$default" == "y" ]]; then
        hint="Y/n"
    else
        hint="y/N"
    fi

    printf '%s [%s]: ' "$question" "$hint"
    read -r answer
    answer="${answer:-$default}"
    answer="${answer,,}" # lowercase

    [[ "$answer" == "y" || "$answer" == "yes" ]]
}

# Select from numbered options. Returns selected index (0-based) on stdout.
# Usage: idx=$(prompt_select "Choose homeserver" "Synapse (recommended)" "Dendrite")
prompt_select() {
    local question="$1"
    shift
    local options=("$@")
    local i choice

    if [[ "$HEADLESS" == "true" ]]; then
        echo "0"
        return 0
    fi

    printf '%s\n' "$question" >&2
    for i in "${!options[@]}"; do
        printf '  %s[%d]%s %s\n' "$C_CYAN" $((i + 1)) "$C_RESET" "${options[$i]}" >&2
    done
    printf 'Selection [1]: ' >&2
    read -er choice
    choice="${choice:-1}"

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
        echo $((choice - 1))
    else
        log_warn "Invalid selection, using default (1)"
        echo "0"
    fi
}

# Multi-select from options. Returns space-separated indices on stdout.
# Usage: selected=$(prompt_multiselect "Choose bridges" "Telegram" "Discord" "WhatsApp")
prompt_multiselect() {
    local question="$1"
    shift
    local options=("$@")
    local i input

    if [[ "$HEADLESS" == "true" ]]; then
        echo ""
        return 0
    fi

    printf '%s (comma-separated numbers, or empty for none)\n' "$question" >&2
    for i in "${!options[@]}"; do
        printf '  %s[%d]%s %s\n' "$C_CYAN" $((i + 1)) "$C_RESET" "${options[$i]}" >&2
    done
    printf 'Selection: ' >&2
    read -er input

    if [[ -z "$input" ]]; then
        echo ""
        return 0
    fi

    local result=()
    IFS=',' read -ra choices <<< "$input"
    for choice in "${choices[@]}"; do
        choice="${choice// /}" # trim whitespace
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            result+=($((choice - 1)))
        fi
    done
    echo "${result[*]}"
}

# --- File utilities ---

# Back up a file before modification
file_backup() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp "$file" "${file}.pre-matrix.$(date +%s)"
    fi
}

# --- Template rendering ---
# Replaces {{VAR}} with values from an associative array.
# Processes {{#FLAG}}...{{/FLAG}} conditional blocks.
# Usage: declare -A vars=([DOMAIN]="example.com" [FEDERATION]="true")
#        template_render "input.tpl" "output.conf" vars
template_render() {
    local input="$1"
    local output="$2"
    local -n _vars="$3"
    local content

    # Read with $(cat …), not the faster $(<"$input"): bash(1) calls them
    # equivalent under COMMAND SUBSTITUTION, but only for a file that opens. A
    # failed open on the redirection form exits the shell outright, even from a
    # call in a `||` list where set -e is otherwise suppressed, so every
    # caller's `|| { log_error …; return 1; }` was unreachable. A directory
    # opens and reads as empty, which rendered the template as nothing and
    # returned success, so -f has to be checked as well as -r.
    if [[ ! -f "$input" || ! -r "$input" ]]; then
        log_error "Template '$input': not a readable file"
        return 1
    fi
    content=$(cat -- "$input") || {
        log_error "Template '$input': failed to read"
        return 1
    }

    # Process conditional blocks. The keys come from the template, not from the
    # vars array: a key the caller never set is falsy, and its block has to go.
    # Looping over the array instead left such a block's markers in the output.
    local -a block_keys=()
    mapfile -t block_keys < <(grep -o '{{#[A-Za-z0-9_]\+}}' <<< "$content" \
        | sed 's/^{{#//; s/}}$//' | sort -u)

    local key script
    for key in "${block_keys[@]}"; do
        if [[ "${_vars[$key]:-}" == "true" || "${_vars[$key]:-}" == "1" ]]; then
            # Keep content between {{#KEY}} and {{/KEY}}, remove markers
            script="/{{#${key}}}/d; /{{\\/${key}}}/d"
        else
            # Remove everything between {{#KEY}} and {{/KEY}} inclusive
            script="/{{#${key}}}/,/{{\\/${key}}}/d"
        fi
        # A failed sed would leave $content empty; report it rather than
        # writing an empty file over the caller's output.
        content=$(echo "$content" | sed "$script") || {
            log_error "Template '$input': failed to process block {{#${key}}}"
            return 1
        }
    done

    # Substitute {{VAR}} placeholders
    for key in "${!_vars[@]}"; do
        local escaped_val
        escaped_val=$(printf '%s' "${_vars[$key]}" | sed 's/[&/\|]/\\&/g')
        content=$(echo "$content" | sed "s|{{${key}}}|${escaped_val}|g") || {
            log_error "Template '$input': failed to substitute {{${key}}} (value may contain a newline)"
            return 1
        }
    done

    echo "$content" > "$output"
}

# --- Retry with backoff ---
# Usage: retry_with_backoff 3 2 curl -sf http://localhost:8008/...
retry_with_backoff() {
    local max_attempts="$1"
    local base_delay="$2"
    shift 2
    local attempt=1

    while (( attempt <= max_attempts )); do
        if "$@"; then
            return 0
        fi
        if (( attempt == max_attempts )); then
            return 1
        fi
        local delay=$(( base_delay * attempt ))
        log_debug "Attempt $attempt failed, retrying in ${delay}s..."
        sleep "$delay"
        attempt=$((attempt + 1))
    done
    return 1
}

# --- Host address a port is published on, in the form both consumers accept ---
# The compose file writes it as the host side of a port mapping and the proxy
# snippets write it into a backend URL. podman-run(1) gives that mapping as
# [[ip:][hostPort]:]containerPort, so an IPv6 literal is bracketed to keep its
# own colons out of the field separators — the same form a URL needs (RFC 3986
# §3.2.2). UNVERIFIED: no podman was run here to parse the bracketed mapping;
# the podman 4.9.3 binary does carry the string "IPv6 addresses must be
# surrounded by square brackets".
proxy_bind_host() {
    local addr="${1:-$DEFAULT_PROXY_BIND_ADDRESS}"
    if [[ "$addr" == *:* ]]; then
        printf '[%s]' "$addr"
    else
        printf '%s' "$addr"
    fi
}

# --- Require root/sudo ---
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo."
        exit "$E_PREREQ"
    fi
}

# --- The compose command, split into argv ---
# COMPOSE_CMD is a string that is one word ("podman-compose", or the absolute
# path to the pinned virtualenv binary) or two ("podman compose", podman v5+).
# In command position the shell splits it for free; passed as an *argument* to
# run_as_user it has to be split explicitly. Quoting it whole would look for a
# binary literally named "podman compose"; leaving it bare works but makes the
# split invisible (SC2086), which is how it was reviewed as a bug twice.
# Usage: local -a compose=(); compose_argv compose
compose_argv() {
    local -n _compose_argv="$1"
    read -r -a _compose_argv <<< "$COMPOSE_CMD"
}

# --- Run command as matrix user ---
run_as_user() {
    local matrix_user="${CONFIG[matrix_user]:-$DEFAULT_MATRIX_USER}"
    sudo -u "$matrix_user" -- "$@"
}

# --- Enable a systemd *user* unit from the installer ---
# `systemctl --user enable` needs the target user's session bus, which `sudo -u`
# does not set up, so every call site used to swallow its failure and the units
# were never enabled. systemctl(1) defines enable as creating "a set of symlinks,
# as encoded in the [Install] sections", so the symlink is created directly.
# Quadlet units need none of this: their generator applies [Install] itself
# (podman-systemd.unit(5)).
systemd_user_enable_unit() {
    local unit_dir="$1" unit="$2" target="$3"
    local wants_dir="$unit_dir/${target}.wants"

    mkdir -p "$wants_dir"
    ln -sf "$unit_dir/$unit" "$wants_dir/$unit"
}

# --- Resolve a user's home directory (no eval) ---
# Uses getent so a username containing shell metacharacters can never be
# evaluated. Returns non-zero (and logs) if the user has no resolvable home.
get_user_home() {
    local user="$1"
    local home
    home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
    if [[ -z "$home" ]]; then
        log_error "Cannot resolve home directory for user '$user'"
        return 1
    fi
    printf '%s\n' "$home"
}

# --- Check command exists ---
check_command() {
    command -v "$1" &>/dev/null
}

# --- Create temp file/dir safely ---
make_temp_file() {
    mktemp "${TMPDIR:-/tmp}/matrix-setup.XXXXXXXXXX"
}

make_temp_dir() {
    mktemp -d "${TMPDIR:-/tmp}/matrix-setup.XXXXXXXXXX"
}

# --- Version comparison (returns 0 if $1 >= $2) ---
# NOTE: relies on GNU coreutils `sort -V` (present on all supported Linux
# distros; not available on BusyBox/macOS sort).
version_gte() {
    local v1="$1" v2="$2"
    [[ "$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -n1)" == "$v2" ]]
}
