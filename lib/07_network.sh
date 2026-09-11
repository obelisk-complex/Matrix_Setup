#!/usr/bin/env bash
# Matrix Stack Setup - Network Validation
# DNS checks, IPv6, Cloudflare API, port detection.
set -euo pipefail

# --- Globals ---
DNS_A=""
DNS_AAAA=""
PORT_80_PROCESS=""
PORT_443_PROCESS=""

# --- Public API ---

# Phase entry point invoked from setup.sh main(). Orchestrates the
# domain/DNS/port checks against the wizard-confirmed CONFIG[domain.name].
# Treats DNS-mismatch and port-in-use as warnings (non-fatal) so an admin
# can proceed with an existing reverse proxy or pre-DNS-propagation host;
# treats a syntactically invalid domain as fatal.
network_validate() {
    local domain="${CONFIG[domain.name]:-}"

    if [[ -z "$domain" ]]; then
        log_error "No domain configured (CONFIG[domain.name])."
        return 1
    fi

    if ! network_validate_domain "$domain"; then
        log_error "Invalid domain: $domain"
        return 1
    fi

    if network_check_dns "$domain"; then
        log_substep "DNS resolves: $domain -> ${DNS_A:-${DNS_AAAA}}"
        if network_dns_matches_server "$domain"; then
            log_substep "DNS matches this host"
        else
            log_warn "DNS does not point to this server's public IP."
            log_warn "  Domain resolves to: ${DNS_A:-none} ${DNS_AAAA:+(v6: $DNS_AAAA)}"
            log_warn "  Server public IP:   ${PUBLIC_IPV4:-unknown} ${PUBLIC_IPV6:+(v6: $PUBLIC_IPV6)}"
            log_warn "  Federation, TLS issuance, and inbound reachability will fail until DNS is corrected."
        fi
    else
        log_warn "DNS lookup for $domain returned no records."
        log_warn "  TLS issuance via Let's Encrypt and federation will fail until DNS is configured."
    fi

    if network_check_ports; then
        log_substep "Ports 80/443 free"
    else
        [[ -n "$PORT_80_PROCESS"  ]] && log_warn "Port 80 in use by: $PORT_80_PROCESS"
        [[ -n "$PORT_443_PROCESS" ]] && log_warn "Port 443 in use by: $PORT_443_PROCESS"
        log_warn "Existing proxy will be detected in the next phase."
    fi

    return 0
}

network_validate_domain() {
    local domain="$1"
    _validate_domain "$domain"
}

network_check_dns() {
    local domain="$1"
    DNS_A=""
    DNS_AAAA=""

    # Try multiple resolution tools
    if check_command dig; then
        DNS_A=$(dig +short A "$domain" 2>/dev/null | head -1)
        DNS_AAAA=$(dig +short AAAA "$domain" 2>/dev/null | head -1)
    elif check_command host; then
        DNS_A=$(host -t A "$domain" 2>/dev/null | awk '/has address/ {print $NF; exit}')
        DNS_AAAA=$(host -t AAAA "$domain" 2>/dev/null | awk '/has IPv6 address/ {print $NF; exit}')
    elif check_command getent; then
        DNS_A=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}')
        DNS_AAAA=$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1; exit}')
    fi

    [[ -n "$DNS_A" || -n "$DNS_AAAA" ]]
}

network_dns_matches_server() {
    local domain="$1"

    if [[ -z "$PUBLIC_IPV4" ]]; then
        detect_public_ip
    fi

    if [[ -n "$DNS_A" && "$DNS_A" == "$PUBLIC_IPV4" ]]; then
        return 0
    fi
    if [[ -n "$DNS_AAAA" && "$DNS_AAAA" == "$PUBLIC_IPV6" ]]; then
        return 0
    fi

    return 1
}

network_check_ports() {
    PORT_80_PROCESS=""
    PORT_443_PROCESS=""

    local line
    # Portable extraction of the process name from ss output
    # (users:(("nginx",pid=...))) — avoids GNU `grep -oP \K`.
    line=$(ss -tlnp 'sport = :80' 2>/dev/null | tail -1)
    if [[ -n "$line" && "$line" != *"State"* ]]; then
        PORT_80_PROCESS=$(echo "$line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p')
        [[ -n "$PORT_80_PROCESS" ]] || PORT_80_PROCESS="unknown"
    fi

    line=$(ss -tlnp 'sport = :443' 2>/dev/null | tail -1)
    if [[ -n "$line" && "$line" != *"State"* ]]; then
        PORT_443_PROCESS=$(echo "$line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p')
        [[ -n "$PORT_443_PROCESS" ]] || PORT_443_PROCESS="unknown"
    fi

    [[ -z "$PORT_80_PROCESS" && -z "$PORT_443_PROCESS" ]]
}

network_check_port_reachable() {
    # Pre-flight: check if our port 80 is reachable from outside
    # Uses a lightweight external check
    local domain="${CONFIG[domain.name]:-}"
    if [[ -z "$domain" ]]; then
        return 1
    fi

    # Try connecting to our own port 80 via the domain
    if curl -sf --connect-timeout 5 -o /dev/null "http://${domain}/" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Print manual DNS instructions
network_print_dns_instructions() {
    local domain="$1"

    printf '\n%sDNS Records Required:%s\n' "$C_BOLD" "$C_RESET"
    printf '  A    %-40s -> %s\n' "$domain" "${PUBLIC_IPV4:-<your-server-ip>}"
    if [[ "$HAS_IPV6" == "true" && -n "$PUBLIC_IPV6" ]]; then
        printf '  AAAA %-40s -> %s\n' "$domain" "$PUBLIC_IPV6"
    fi

    local webclient_sub="${CONFIG[webclient.subdomain]:-chat}"
    if [[ "${CONFIG[webclient.type]:-none}" != "none" ]]; then
        printf '  A    %-40s -> %s\n' "${webclient_sub}.${domain}" "${PUBLIC_IPV4:-<your-server-ip>}"
    fi

    if [[ "${CONFIG[admin_ui.enabled]:-false}" == "true" ]]; then
        local admin_sub="${CONFIG[admin_ui.subdomain]:-admin}"
        printf '  A    %-40s -> %s\n' "${admin_sub}.${domain}" "${PUBLIC_IPV4:-<your-server-ip>}"
    fi

    if [[ "${CONFIG[monitoring.enabled]:-false}" == "true" ]]; then
        local grafana_sub="${CONFIG[monitoring.grafana_subdomain]:-grafana}"
        printf '  A    %-40s -> %s\n' "${grafana_sub}.${domain}" "${PUBLIC_IPV4:-<your-server-ip>}"
    fi
    printf '\n'
}
