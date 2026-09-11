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

    # The example config nests these under [advanced], which the parser flattens
    # to `advanced.<key>`; every consumer reads the bare key.
    _config_alias_advanced

    # Apply defaults for any missing values
    _config_apply_defaults
}

# Copy the [advanced] table's non-namespaced settings onto the bare keys the
# rest of the codebase reads. A bare key written at the top level of the file
# wins, so an existing config that used that form keeps its meaning.
_config_alias_advanced() {
    local key
    for key in install_dir matrix_user; do
        if [[ -z "${CONFIG[$key]:-}" && -n "${CONFIG[advanced.$key]:-}" ]]; then
            CONFIG["$key"]="${CONFIG[advanced.$key]}"
        fi
    done
}

# Apply advanced.podman_compose_command over the detected tool. Must run after
# detect_compose_command, which would otherwise overwrite the operator's choice.
# Validation restricts the value to the documented set: COMPOSE_CMD is expanded
# unquoted at every call site.
config_apply_compose_command() {
    local requested="${CONFIG[advanced.podman_compose_command]:-auto}"
    [[ "$requested" != "auto" ]] || return 0

    local networking
    case "$requested" in
        "podman compose")
            podman compose version &>/dev/null || {
                log_warn "Config requests 'podman compose', which this podman does not provide; using ${COMPOSE_CMD:-none detected}"
                return 0
            }
            networking="dns"
            ;;
        podman-compose)
            check_command podman-compose || {
                log_warn "Config requests 'podman-compose', which is not installed; using ${COMPOSE_CMD:-none detected}"
                return 0
            }
            networking="pod"
            ;;
        docker-compose)
            check_command docker-compose || {
                log_warn "Config requests 'docker-compose', which is not installed; using ${COMPOSE_CMD:-none detected}"
                return 0
            }
            networking="dns"
            ;;
        *)
            log_warn "Ignoring unrecognised advanced.podman_compose_command '$requested'"
            return 0
            ;;
    esac

    COMPOSE_CMD="$requested"
    COMPOSE_NETWORKING="$networking"
    log_info "Compose tool set from config: $COMPOSE_CMD (networking: $COMPOSE_NETWORKING)"
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

    # --- Identifier / format validation ---
    # These values flow into shell, SQL, JSON and arithmetic sinks elsewhere in
    # the codebase. Strict validation here is the primary defence against
    # injection; consumers add defence-in-depth (getent/json.dumps/quoting).
    local key val

    # matrix_user: must be a valid Unix username (resolved via getent, used in
    # file ownership and paths).
    val="${CONFIG[matrix_user]:-}"
    if [[ -n "$val" && ! "$val" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        log_error "Config: matrix_user '$val' is not a valid Unix username (^[a-z_][a-z0-9_-]{0,31}\$)"
        errors=$((errors + 1))
    fi

    # install_dir: absolute path, no shell metacharacters, whitespace or traversal.
    val="${CONFIG[install_dir]:-}"
    if [[ -n "$val" ]]; then
        if [[ "$val" != /* ]]; then
            log_error "Config: install_dir must be an absolute path, got '$val'"
            errors=$((errors + 1))
        elif [[ "$val" == *..* || "$val" =~ [[:space:]\;\|\&\$\`\(\)\<\>\*\?\\\"\'] ]]; then
            log_error "Config: install_dir '$val' contains unsafe characters"
            errors=$((errors + 1))
        fi
    fi

    # podman_compose_command: COMPOSE_CMD is expanded unquoted at every call
    # site, so only the four documented values are accepted.
    val="${CONFIG[advanced.podman_compose_command]:-auto}"
    case "$val" in
        auto|"podman compose"|podman-compose|docker-compose) ;;
        *)
            log_error "Config: advanced.podman_compose_command must be one of auto, 'podman compose', podman-compose, docker-compose; got '$val'"
            errors=$((errors + 1))
            ;;
    esac

    # Ports: integer in 1-65535. Regex-check BEFORE any arithmetic so a value
    # like 'x[$(cmd)]' can never reach (( )) evaluation.
    for key in coturn.min_port coturn.max_port smtp.port; do
        val="${CONFIG[$key]:-}"
        [[ -z "$val" ]] && continue
        if [[ ! "$val" =~ ^[0-9]+$ ]]; then
            log_error "Config: $key must be a positive integer, got '$val'"
            errors=$((errors + 1))
        elif (( 10#$val < 1 || 10#$val > 65535 )); then
            log_error "Config: $key must be in range 1-65535, got '$val'"
            errors=$((errors + 1))
        fi
    done
    if [[ "${CONFIG[coturn.min_port]:-}" =~ ^[0-9]+$ && "${CONFIG[coturn.max_port]:-}" =~ ^[0-9]+$ ]] \
        && (( 10#${CONFIG[coturn.min_port]} >= 10#${CONFIG[coturn.max_port]} )); then
        log_error "Config: coturn.min_port must be less than coturn.max_port"
        errors=$((errors + 1))
    fi

    # database.user / database.name: SQL identifier-safe (prevents SQL injection
    # in psql role/database creation).
    for key in database.user database.name; do
        val="${CONFIG[$key]:-}"
        if [[ -n "$val" && ! "$val" =~ ^[a-zA-Z_][a-zA-Z0-9_]{0,62}$ ]]; then
            log_error "Config: $key '$val' must match ^[a-zA-Z_][a-zA-Z0-9_]{0,62}\$"
            errors=$((errors + 1))
        fi
    done

    # backup.retention_daily / backup.retention_weekly: reach an arithmetic
    # context in the root-run backup timer. Verified on bash 5.2.21: a bare
    # $(cmd) operand is a syntax error, but an array subscript - a[$(cmd)] -
    # does execute, so these are pinned to plain integers here.
    for key in backup.retention_daily backup.retention_weekly; do
        val="${CONFIG[$key]:-}"
        if [[ -n "$val" && ! "$val" =~ ^[0-9]+$ ]]; then
            log_error "Config: $key must be a non-negative integer, got '$val'"
            errors=$((errors + 1))
        fi
    done

    # media_retention.days: integer (prevents bash arithmetic command injection
    # in the generated cleanup script).
    val="${CONFIG[media_retention.days]:-}"
    if [[ -n "$val" && ! "$val" =~ ^[0-9]+$ ]]; then
        log_error "Config: media_retention.days must be a non-negative integer, got '$val'"
        errors=$((errors + 1))
    fi

    # admin.username: Matrix localpart rules (prevents JSON injection in the
    # registration request body).
    val="${CONFIG[admin.username]:-}"
    if [[ -n "$val" && ! "$val" =~ ^[a-z0-9._=/-]+$ ]]; then
        log_error "Config: admin.username '$val' contains characters invalid for a Matrix localpart (^[a-z0-9._=/-]+\$)"
        errors=$((errors + 1))
    fi

    # admin.password: reject known placeholder/default values so a copy-pasted
    # example config cannot ship a publicly-known admin password.
    case "${CONFIG[admin.password]:-}" in
        "") ;;
        changeme*|password|admin|administrator|12345678|matrix)
            log_error "Config: admin.password must not be a default/placeholder value"
            errors=$((errors + 1)) ;;
    esac

    # bridges.enabled: each entry must be a safe bridge name (prevents path
    # traversal / arbitrary 'source' in lib/16_bridges.sh).
    if [[ -n "${CONFIG[bridges.enabled]:-}" ]]; then
        local _b _bridges
        IFS=',' read -ra _bridges <<< "${CONFIG[bridges.enabled]}"
        for _b in "${_bridges[@]}"; do
            _b="${_b// /}"
            [[ -z "$_b" ]] && continue
            if [[ ! "$_b" =~ ^[a-z][a-z0-9_]*$ ]]; then
                log_error "Config: bridges.enabled contains invalid bridge name '$_b'"
                errors=$((errors + 1))
            fi
        done
    fi

    # monitoring.grafana_subdomain: a single DNS label (RFC 1035). It reaches
    # the compose and Caddyfile renderers raw and ends up in a hostname.
    val="${CONFIG[monitoring.grafana_subdomain]:-}"
    if [[ -n "$val" && ! "$val" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        log_error "Config: monitoring.grafana_subdomain '$val' is not a valid DNS label"
        errors=$((errors + 1))
    fi

    # hardening.*: each switch is consumed as `== "true"`, so any other spelling
    # ("yes", "1", "True") silently reads as "off" and quietly disables a
    # control the operator asked for. Reject it instead.
    for key in hardening.ssh hardening.firewall hardening.fail2ban \
               hardening.sysctl hardening.auto_updates \
               hardening.ssh_tcp_forwarding hardening.ipv6_privacy; do
        val="${CONFIG[$key]:-}"
        if [[ -n "$val" && "$val" != "true" && "$val" != "false" ]]; then
            log_error "Config: $key must be true or false, got '$val'"
            errors=$((errors + 1))
        fi
    done

    # hardening.conntrack_max: reaches a sysctl assignment. Upper bound is a
    # sanity check, not a kernel limit — a table this large is a typo, not a plan.
    val="${CONFIG[hardening.conntrack_max]:-}"
    if [[ -n "$val" ]]; then
        if [[ ! "$val" =~ ^[0-9]+$ ]]; then
            log_error "Config: hardening.conntrack_max must be a positive integer, got '$val'"
            errors=$((errors + 1))
        elif (( 10#$val < 1024 || 10#$val > 4194304 )); then
            log_error "Config: hardening.conntrack_max must be in range 1024-4194304, got '$val'"
            errors=$((errors + 1))
        fi
    fi

    # proxy.bind_address: the host side of the port the homeserver is published
    # on when an external proxy fronts the stack, and the backend address in
    # every generated snippet. A hostname is resolved by neither, and a value
    # carrying a colon or a space would shift the remaining fields of the port
    # mapping along, so only an IP literal is accepted.
    val="${CONFIG[proxy.bind_address]:-}"
    if [[ -n "$val" ]] && ! _validate_ip_literal "$val"; then
        log_error "Config: proxy.bind_address '$val' is not an IP address literal"
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
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for key in $(echo "${!CONFIG[@]}" | tr ' ' '\n' | sort); do
            # No credential-shaped value is persisted. The previous filter
            # matched `*.password` and `*.secret*` only, which let through every
            # `secrets.<name>_password`, every bridge token, the Cloudflare API
            # token and the reCAPTCHA private key. This file exists for re-run
            # detection: `upgrade_check` reads the version, the domain and the
            # homeserver type, and nothing reads a secret back out of it.
            case "$key" in
                secrets.*|*password*|*secret*|*token*|*key*) continue ;;
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
    : "${CONFIG[proxy.bind_address]:=$DEFAULT_PROXY_BIND_ADDRESS}"
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
    # These three default to what an install already does, so upgrading without
    # editing the config changes nothing: SSH forwarding stays as the operator's
    # own sshd_config has it, IPv6 privacy addresses stay off, and the conntrack
    # table size is left to the kernel.
    : "${CONFIG[hardening.ssh_tcp_forwarding]:=true}"
    : "${CONFIG[hardening.ipv6_privacy]:=false}"
    : "${CONFIG[hardening.conntrack_max]:=}"
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

# An IP address literal, v4 or v6. A form with an embedded IPv4 part
# (::ffff:127.0.0.1) is rejected rather than half-checked.
_validate_ip_literal() {
    local addr="$1"

    if [[ "$addr" == *:* ]]; then
        [[ "$addr" =~ ^[0-9A-Fa-f:]+$ && "$addr" != *::*::* ]]
        return
    fi

    local -a octets
    IFS='.' read -ra octets <<< "$addr"
    (( ${#octets[@]} == 4 )) || return 1
    local octet
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}
