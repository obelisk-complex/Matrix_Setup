#!/usr/bin/env bash
# Matrix Stack Setup - Configuration Management
# Loads config from TOML (headless) or wizard, validates, persists state.
set -euo pipefail

# Global config associative array
declare -gA CONFIG=()

# --- Public API ---

# Load config from TOML file or set wizard mode
config_load() {
    local config_file="${1:-}"

    if [[ -n "$config_file" && -f "$config_file" ]]; then
        toml_parse_file "$config_file"
        # Copy TOML values into CONFIG
        local key
        for key in "${!TOML_VALUES[@]}"; do
            CONFIG["$key"]="${TOML_VALUES[$key]}"
        done
        log_info "Loaded configuration from: $config_file"
    fi

    # Apply defaults for any missing values
    _config_apply_defaults
}

# Validate the config. Returns 0 if valid, 1 with errors on stderr.
config_validate() {
    local errors=0

    # Domain is required
    if [[ -z "${CONFIG[domain.name]:-}" ]]; then
        log_error "Config: domain.name is required"
        errors=$((errors + 1))
    fi

    # In headless mode, domain must be confirmed
    if [[ "$HEADLESS" == "true" && "${CONFIG[domain.confirmed]:-false}" != "true" ]]; then
        log_error "Config: domain.confirmed must be true in headless mode"
        errors=$((errors + 1))
    fi

    # Validate domain format (RFC 1035)
    if [[ -n "${CONFIG[domain.name]:-}" ]]; then
        if ! _validate_domain "${CONFIG[domain.name]}"; then
            log_error "Config: domain.name '${CONFIG[domain.name]}' is not a valid domain"
            errors=$((errors + 1))
        fi
    fi

    # Homeserver type
    local hs="${CONFIG[homeserver.type]:-synapse}"
    if [[ "$hs" != "synapse" && "$hs" != "dendrite" ]]; then
        log_error "Config: homeserver.type must be 'synapse' or 'dendrite', got '$hs'"
        errors=$((errors + 1))
    fi

    # Dendrite + bridges = error
    if [[ "$hs" == "dendrite" && -n "${CONFIG[bridges.enabled]:-}" ]]; then
        log_error "Config: bridges are not supported with Dendrite"
        errors=$((errors + 1))
    fi

    # Dendrite + admin UI = error
    if [[ "$hs" == "dendrite" && "${CONFIG[admin_ui.enabled]:-false}" == "true" ]]; then
        log_error "Config: Synapse Admin UI is not available with Dendrite"
        errors=$((errors + 1))
    fi

    # Registration policy validation
    local reg="${CONFIG[registration.policy]:-invite-only}"
    case "$reg" in
        closed|invite-only) ;;
        open-email)
            if [[ "${CONFIG[smtp.enabled]:-false}" != "true" ]]; then
                log_error "Config: registration.policy 'open-email' requires smtp.enabled = true"
                errors=$((errors + 1))
            fi ;;
        open-captcha)
            if [[ -z "${CONFIG[registration.recaptcha_public_key]:-}" || \
                  -z "${CONFIG[registration.recaptcha_private_key]:-}" ]]; then
                log_error "Config: registration.policy 'open-captcha' requires recaptcha keys"
                errors=$((errors + 1))
            fi ;;
        *)
            log_error "Config: invalid registration.policy '$reg'"
            errors=$((errors + 1)) ;;
    esac

    # Admin account
    if [[ "$HEADLESS" == "true" ]]; then
        if [[ -z "${CONFIG[admin.username]:-}" ]]; then
            log_error "Config: admin.username is required"
            errors=$((errors + 1))
        fi
        if [[ -z "${CONFIG[admin.password]:-}" ]]; then
            log_error "Config: admin.password is required"
            errors=$((errors + 1))
        elif [[ ${#CONFIG[admin.password]} -lt 8 ]]; then
            log_error "Config: admin.password must be at least 8 characters"
            errors=$((errors + 1))
        fi
    fi

    # Backup encryption requires key
    if [[ "${CONFIG[backup.encryption]:-none}" != "none" && \
          -z "${CONFIG[backup.encryption_key]:-}" ]]; then
        log_error "Config: backup.encryption requires backup.encryption_key"
        errors=$((errors + 1))
    fi

    # Backup upload requires target
    if [[ "${CONFIG[backup.upload]:-none}" != "none" && \
          -z "${CONFIG[backup.upload_target]:-}" ]]; then
        log_error "Config: backup.upload requires backup.upload_target"
        errors=$((errors + 1))
    fi

    (( errors == 0 ))
}

# Get a config value
config_get() {
    echo "${CONFIG[$1]:-}"
}

# Set a config value
config_set() {
    CONFIG["$1"]="$2"
}

# Generate example TOML config
config_generate_example() {
    cat "${SCRIPT_DIR}/config/matrix-setup.example.toml"
}

# Save current config as state file for re-run detection
config_save_state() {
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local state_file="$install_dir/$MATRIX_SETUP_STATE_FILE"

    mkdir -p "$install_dir"
    {
        echo "# Matrix Setup State - do not edit"
        echo "version=$MATRIX_SETUP_VERSION"
        echo "timestamp=$(date -Iseconds)"
        for key in $(echo "${!CONFIG[@]}" | tr ' ' '\n' | sort); do
            # Don't persist passwords/secrets in state
            case "$key" in
                *.password|*.secret*) continue ;;
            esac
            echo "${key}=${CONFIG[$key]}"
        done
    } > "$state_file"
    chmod 600 "$state_file"
}

# --- Internal ---

_config_apply_defaults() {
    : "${CONFIG[homeserver.type]:=synapse}"
    : "${CONFIG[federation.enabled]:=true}"
    : "${CONFIG[registration.policy]:=invite-only}"
    : "${CONFIG[admin.username]:=admin}"
    : "${CONFIG[database.mode]:=auto}"
    : "${CONFIG[webclient.type]:=element}"
    : "${CONFIG[webclient.subdomain]:=chat}"
    : "${CONFIG[coturn.enabled]:=true}"
    : "${CONFIG[coturn.min_port]:=$PORT_COTURN_MIN}"
    : "${CONFIG[coturn.max_port]:=$PORT_COTURN_MAX}"
    : "${CONFIG[smtp.enabled]:=false}"
    : "${CONFIG[smtp.port]:=587}"
    : "${CONFIG[bridges.enabled]:=}"
    : "${CONFIG[admin_ui.enabled]:=true}"
    : "${CONFIG[admin_ui.subdomain]:=admin}"
    : "${CONFIG[monitoring.enabled]:=false}"
    : "${CONFIG[monitoring.grafana_subdomain]:=grafana}"
    : "${CONFIG[backup.retention_daily]:=$DEFAULT_BACKUP_DAILY}"
    : "${CONFIG[backup.retention_weekly]:=$DEFAULT_BACKUP_WEEKLY}"
    : "${CONFIG[backup.encryption]:=none}"
    : "${CONFIG[backup.upload]:=none}"
    : "${CONFIG[hardening.ssh]:=true}"
    : "${CONFIG[hardening.firewall]:=true}"
    : "${CONFIG[hardening.fail2ban]:=true}"
    : "${CONFIG[hardening.sysctl]:=true}"
    : "${CONFIG[hardening.auto_updates]:=true}"
    : "${CONFIG[secrets.mode]:=env}"
    : "${CONFIG[install_dir]:=$DEFAULT_INSTALL_DIR}"
    : "${CONFIG[matrix_user]:=$DEFAULT_MATRIX_USER}"
    : "${CONFIG[advanced.podman_compose_command]:=auto}"
}

_validate_domain() {
    local domain="$1"
    # RFC 1035: labels are alphanumeric + hyphens, separated by dots
    # Must not start/end with hyphen, 1-63 chars per label, 1-253 total
    [[ ${#domain} -le 253 ]] || return 1
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]] || return 1
    # Must have at least one dot (not just a hostname)
    [[ "$domain" == *.* ]] || return 1
    return 0
}
