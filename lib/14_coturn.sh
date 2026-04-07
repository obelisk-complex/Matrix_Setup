#!/usr/bin/env bash
# Matrix Stack Setup - Coturn TURN/STUN Server
# Hardened config with CVE-2026-27624 mitigations.
# Runs rootful with host networking for reliable UDP media relay.
# shellcheck disable=SC2034,SC2154
set -euo pipefail

coturn_setup() {
    log_step "Configuring Coturn TURN/STUN server"

    if [[ "${CONFIG[coturn.enabled]:-true}" != "true" ]]; then
        log_substep "Coturn disabled, skipping"
        return 0
    fi

    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local config_dir="$install_dir/config"

    mkdir -p "$config_dir"

    CONFIG[coturn.image]="$COTURN_IMAGE"

    local domain="${CONFIG[domain.name]}"
    local min_port="${CONFIG[coturn.min_port]:-$PORT_COTURN_MIN}"
    local max_port="${CONFIG[coturn.max_port]:-$PORT_COTURN_MAX}"

    declare -A turn_vars=(
        [DOMAIN]="$domain"
        [TURN_SECRET]="${CONFIG[secrets.coturn_secret]:-}"
        [MIN_PORT]="$min_port"
        [MAX_PORT]="$max_port"
        [STUN_PORT]="$PORT_STUN"
        [STUN_TLS_PORT]="$PORT_STUN_TLS"
    )

    # IPv6 support
    if [[ "${CONFIG[network.ipv6]:-false}" == "true" ]]; then
        turn_vars[IPV6]="true"
    else
        turn_vars[IPV6]="false"
    fi

    # TLS for TURNS (Caddy provides certs)
    local cert_dir="$install_dir/data/caddy/data/caddy/certificates"
    if [[ -d "$cert_dir" ]]; then
        turn_vars[TLS]="true"
        turn_vars[TLS_CERT_DIR]="/etc/coturn/certs"
    else
        turn_vars[TLS]="false"
    fi

    template_render \
        "${SCRIPT_DIR}/templates/configs/turnserver.conf.tpl" \
        "$config_dir/turnserver.conf" \
        turn_vars

    chmod 640 "$config_dir/turnserver.conf"
    rollback_snapshot "coturn" "FILE_CREATED" "$config_dir/turnserver.conf"

    log_substep "turnserver.conf written to $config_dir/turnserver.conf"
    log_substep "Coturn will run rootful with host networking"
    log_success "Coturn configured with CVE-2026-27624 mitigations"
}
