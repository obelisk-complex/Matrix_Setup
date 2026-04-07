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
    line=$(ss -tlnp 'sport = :80' 2>/dev/null | tail -1)
    if [[ -n "$line" && "$line" != *"State"* ]]; then
        PORT_80_PROCESS=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' || echo "unknown")
    fi

    line=$(ss -tlnp 'sport = :443' 2>/dev/null | tail -1)
    if [[ -n "$line" && "$line" != *"State"* ]]; then
        PORT_443_PROCESS=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' || echo "unknown")
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

# Cloudflare DNS record creation
network_cloudflare_create_records() {
    local domain="$1"
    local token="$2"
    local ipv4="$3"
    local ipv6="${4:-}"

    log_substep "Creating DNS records via Cloudflare API..."

    # Get zone ID
    local zone_name
    zone_name=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')

    local zone_id
    zone_id=$(curl -sf -H "Authorization: Bearer $token" \
        "https://api.cloudflare.com/client/v4/zones?name=$zone_name" | \
        jq -r '.result[0].id // empty')

    if [[ -z "$zone_id" ]]; then
        log_error "Could not find Cloudflare zone for $zone_name"
        return 1
    fi

    # Create A record
    if [[ -n "$ipv4" ]]; then
        local result
        result=$(curl -sf -X POST \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
            -d "{\"type\":\"A\",\"name\":\"$domain\",\"content\":\"$ipv4\",\"ttl\":300,\"proxied\":false}")

        if echo "$result" | jq -r '.success' | grep -q true; then
            log_substep "A record created: $domain -> $ipv4"
        else
            log_warn "Failed to create A record: $(echo "$result" | jq -r '.errors[0].message // "unknown"')"
        fi
    fi

    # Create AAAA record
    if [[ -n "$ipv6" ]]; then
        local result
        result=$(curl -sf -X POST \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
            -d "{\"type\":\"AAAA\",\"name\":\"$domain\",\"content\":\"$ipv6\",\"ttl\":300,\"proxied\":false}")

        if echo "$result" | jq -r '.success' | grep -q true; then
            log_substep "AAAA record created: $domain -> $ipv6"
        else
            log_warn "Failed to create AAAA record"
        fi
    fi
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
