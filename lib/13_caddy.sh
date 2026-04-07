#!/usr/bin/env bash
# Matrix Stack Setup - Caddy Reverse Proxy
# shellcheck disable=SC2034,SC2154
set -euo pipefail

caddy_setup() {
    log_step "Configuring Caddy reverse proxy"

    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local config_dir="$install_dir/config"
    local data_dir="$install_dir/data/caddy"

    mkdir -p "$config_dir" "$data_dir/data" "$data_dir/config"

    CONFIG[caddy.image]="$CADDY_IMAGE"

    # Determine homeserver backend address
    local hs_backend
    if [[ "${COMPOSE_NETWORKING:-dns}" == "pod" ]]; then
        hs_backend="localhost:${PORT_SYNAPSE}"
    else
        hs_backend="homeserver:${PORT_SYNAPSE}"
    fi

    declare -A caddy_vars=(
        [DOMAIN]="${CONFIG[domain.name]}"
        [HS_BACKEND]="$hs_backend"
        [FEDERATION]="${CONFIG[federation.enabled]:-true}"
        [FEDERATION_PORT]="$PORT_FEDERATION"
    )

    # Web client
    if [[ -n "${CONFIG[webclient.type]:-}" && "${CONFIG[webclient.type]}" != "none" ]]; then
        caddy_vars[WEBCLIENT]="true"
        caddy_vars[WEBCLIENT_SUBDOMAIN]="${CONFIG[webclient.subdomain]:-chat}"
        local wc_backend
        if [[ "${COMPOSE_NETWORKING:-dns}" == "pod" ]]; then
            wc_backend="localhost:8080"
        else
            wc_backend="webclient:80"
        fi
        caddy_vars[WEBCLIENT_BACKEND]="$wc_backend"

        # CSP for Element Web
        if [[ "${CONFIG[webclient.type]}" == "element" ]]; then
            caddy_vars[WEBCLIENT_CSP]="default-src 'none'; script-src 'self' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' https: data: blob:; font-src 'self' data:; media-src 'self' https: blob:; connect-src 'self' https://${CONFIG[domain.name]} wss://${CONFIG[domain.name]} https://matrix.org https://scalar.vector.im; frame-src 'self' blob:; frame-ancestors 'self'; form-action 'self'; base-uri 'self'; manifest-src 'self'; worker-src 'self' blob:"
        else
            caddy_vars[WEBCLIENT_CSP]="default-src 'self'; script-src 'self' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' https: data: blob:; connect-src 'self' https://${CONFIG[domain.name]} wss://${CONFIG[domain.name]}; frame-ancestors 'none'"
        fi
    else
        caddy_vars[WEBCLIENT]="false"
    fi

    # Admin UI
    if [[ "${CONFIG[admin_ui.enabled]:-false}" == "true" ]]; then
        caddy_vars[ADMIN_UI]="true"
        caddy_vars[ADMIN_SUBDOMAIN]="${CONFIG[admin_ui.subdomain]:-admin}"
        local admin_backend
        if [[ "${COMPOSE_NETWORKING:-dns}" == "pod" ]]; then
            admin_backend="localhost:8081"
        else
            admin_backend="synapse-admin:80"
        fi
        caddy_vars[ADMIN_BACKEND]="$admin_backend"
    else
        caddy_vars[ADMIN_UI]="false"
    fi

    # Monitoring / Grafana
    if [[ "${CONFIG[monitoring.enabled]:-false}" == "true" ]]; then
        caddy_vars[GRAFANA]="true"
        caddy_vars[GRAFANA_SUBDOMAIN]="${CONFIG[monitoring.grafana_subdomain]:-grafana}"
        local grafana_backend
        if [[ "${COMPOSE_NETWORKING:-dns}" == "pod" ]]; then
            grafana_backend="localhost:${PORT_GRAFANA}"
        else
            grafana_backend="grafana:${PORT_GRAFANA}"
        fi
        caddy_vars[GRAFANA_BACKEND]="$grafana_backend"
    else
        caddy_vars[GRAFANA]="false"
    fi

    # DNS-01 challenge fallback (e.g., behind Cloudflare proxy)
    if [[ -n "${CONFIG[dns.cloudflare_api_token]:-}" ]]; then
        caddy_vars[DNS_CHALLENGE]="true"
        caddy_vars[CF_API_TOKEN]="${CONFIG[dns.cloudflare_api_token]}"
    else
        caddy_vars[DNS_CHALLENGE]="false"
    fi

    template_render \
        "${SCRIPT_DIR}/templates/configs/Caddyfile.tpl" \
        "$config_dir/Caddyfile" \
        caddy_vars

    rollback_snapshot "caddy" "FILE_CREATED" "$config_dir/Caddyfile"
    log_substep "Caddyfile written to $config_dir/Caddyfile"
    log_success "Caddy reverse proxy configured"
}
