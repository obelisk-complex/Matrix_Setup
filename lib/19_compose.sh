#!/usr/bin/env bash
# Matrix Stack Setup - Compose File Assembly
# Merges compose fragments into a final podman-compose.yml.
# shellcheck disable=SC2034
set -euo pipefail

# Defaults — overridden by detect_compose_command() in 02_detect.sh
: "${COMPOSE_CMD:=podman compose}"
: "${COMPOSE_NETWORKING:=dns}" # "pod" or "dns"
VOLUME_LABEL=""  # ":Z" for SELinux

compose_assemble() {
    log_step "Assembling compose file"

    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local compose_file="$install_dir/podman-compose.yml"
    local templates_dir="${SCRIPT_DIR}/templates/compose"

    # SELinux volume labels
    if [[ "${SELINUX_MODE:-absent}" == "enforcing" || "${SELINUX_MODE:-absent}" == "permissive" ]]; then
        VOLUME_LABEL=":Z"
    fi

    # Start with base (networks + volumes)
    local fragments=("$templates_dir/base.yml")

    # PostgreSQL (if containerized)
    if [[ "${PG_USE_CONTAINER:-true}" == "true" ]]; then
        fragments+=("$templates_dir/postgres.yml")
    fi

    # Homeserver
    local hs_type="${CONFIG[homeserver.type]:-synapse}"
    fragments+=("$templates_dir/${hs_type}.yml")

    # Caddy (unless external proxy handles it)
    if [[ "${CONFIG[proxy.external]:-false}" != "true" ]]; then
        fragments+=("$templates_dir/caddy.yml")
    fi

    # Web client
    if [[ -n "${CONFIG[webclient.type]:-}" && "${CONFIG[webclient.type]}" != "none" ]]; then
        fragments+=("$templates_dir/webclient.yml")
    fi

    # Admin UI
    if [[ "${CONFIG[admin_ui.enabled]:-false}" == "true" && "$hs_type" == "synapse" ]]; then
        fragments+=("$templates_dir/admin.yml")
    fi

    # Monitoring
    if [[ "${CONFIG[monitoring.enabled]:-false}" == "true" ]]; then
        fragments+=("$templates_dir/monitoring.yml")
    fi

    # Build template variables for fragment rendering
    declare -A compose_vars=()
    _compose_build_vars compose_vars

    # Render and merge fragments
    local merged=""
    for fragment in "${fragments[@]}"; do
        if [[ ! -f "$fragment" ]]; then
            log_warn "Compose fragment not found: $fragment"
            continue
        fi

        local rendered
        rendered=$(_compose_render_fragment "$fragment" compose_vars)
        merged+=$'\n'"$rendered"
    done

    # Add bridge compose fragments
    if [[ "${#BRIDGES_ENABLED[@]:-0}" -gt 0 ]]; then
        for bridge_name in "${BRIDGES_ENABLED[@]}"; do
            local plugin="${SCRIPT_DIR}/bridges/${bridge_name}.sh"
            if [[ -f "$plugin" ]]; then
                # shellcheck source=/dev/null
                source "$plugin"
                if declare -f bridge_compose_fragment &>/dev/null; then
                    local bridge_fragment
                    bridge_fragment=$(bridge_compose_fragment)
                    # Inject under services: key
                    merged+=$'\n'"$bridge_fragment"
                fi
            fi
        done
    fi

    echo "$merged" > "$compose_file"
    rollback_snapshot "compose" "FILE_CREATED" "$compose_file"

    # Validate compose file
    log_substep "Validating compose file..."
    if $COMPOSE_CMD -f "$compose_file" config --quiet 2>/dev/null; then
        log_substep "Compose file valid"
    else
        log_warn "Compose file validation returned warnings (may still work)"
    fi

    log_success "Compose file assembled: $compose_file"
}

_compose_build_vars() {
    local -n _vars="$1"
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local domain="${CONFIG[domain.name]}"

    _vars[INSTALL_DIR]="$install_dir"
    _vars[DOMAIN]="$domain"
    _vars[VOLUME_LABEL]="$VOLUME_LABEL"

    # Images
    _vars[SYNAPSE_IMAGE]="$SYNAPSE_IMAGE"
    _vars[DENDRITE_IMAGE]="$DENDRITE_IMAGE"
    _vars[POSTGRES_IMAGE]="$POSTGRES_IMAGE"
    _vars[CADDY_IMAGE]="$CADDY_IMAGE"
    _vars[COTURN_IMAGE]="$COTURN_IMAGE"
    _vars[SYNAPSE_ADMIN_IMAGE]="$SYNAPSE_ADMIN_IMAGE"
    _vars[PROMETHEUS_IMAGE]="$PROMETHEUS_IMAGE"
    _vars[GRAFANA_IMAGE]="$GRAFANA_IMAGE"

    # Ports
    _vars[PORT_HTTP]="$PORT_HTTP"
    _vars[PORT_HTTPS]="$PORT_HTTPS"
    _vars[FEDERATION_PORT]="$PORT_FEDERATION"
    _vars[STUN_PORT]="$PORT_STUN"

    # Feature flags
    _vars[FEDERATION]="${CONFIG[federation.enabled]:-true}"
    _vars[HAS_APPSERVICES]="${CONFIG[bridges.has_appservices]:-false}"

    # DNS challenge
    if [[ -n "${CONFIG[dns.cloudflare_api_token]:-}" ]]; then
        _vars[DNS_CHALLENGE]="true"
        _vars[CF_API_TOKEN]="${CONFIG[dns.cloudflare_api_token]}"
    else
        _vars[DNS_CHALLENGE]="false"
    fi

    # TLS for coturn
    _vars[TLS]="${CONFIG[coturn.tls]:-false}"

    # Web client
    if [[ -n "${CONFIG[webclient.type]:-}" && "${CONFIG[webclient.type]}" != "none" ]]; then
        _vars[WEBCLIENT_IMAGE]="${CONFIG[webclient.image]:-$ELEMENT_IMAGE}"
        local wc_type="${CONFIG[webclient.type]}"
        case "$wc_type" in
            element|schildichat) _vars[WEBCLIENT_CONFIG_FILE]="element-config.json" ;;
            cinny)               _vars[WEBCLIENT_CONFIG_FILE]="cinny-config.json" ;;
        esac
    fi

    # Grafana
    _vars[GRAFANA_SUBDOMAIN]="${CONFIG[monitoring.grafana_subdomain]:-grafana}"
}

_compose_render_fragment() {
    local input="$1"
    local -n _rvars="$2"
    local content
    content=$(<"$input")

    # Process conditional blocks
    local key
    for key in "${!_rvars[@]}"; do
        if [[ "${_rvars[$key]}" == "true" || "${_rvars[$key]}" == "1" ]]; then
            content=$(echo "$content" | sed "/{{#${key}}}/d; /{{\\/${key}}}/d")
        else
            content=$(echo "$content" | sed "/{{#${key}}}/,/{{\\/${key}}}/d")
        fi
    done

    # Variable substitution
    for key in "${!_rvars[@]}"; do
        local escaped_val
        escaped_val=$(printf '%s' "${_rvars[$key]}" | sed 's/[&/\]/\\&/g')
        content=$(echo "$content" | sed "s|{{${key}}}|${escaped_val}|g")
    done

    echo "$content"
}
