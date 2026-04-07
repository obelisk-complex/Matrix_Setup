#!/usr/bin/env bash
# Matrix Stack Setup - Existing Proxy Detection
# shellcheck disable=SC2034,SC2154
set -euo pipefail

DETECTED_PROXY=""
SKIP_CADDY="false"

proxy_detect() {
    if network_check_ports; then
        log_substep "Ports 80/443 are available"
        return 0
    fi

    log_warn "Ports already in use:"
    [[ -n "$PORT_80_PROCESS" ]] && log_warn "  Port 80: $PORT_80_PROCESS"
    [[ -n "$PORT_443_PROCESS" ]] && log_warn "  Port 443: $PORT_443_PROCESS"

    # Try to identify the proxy
    DETECTED_PROXY="unknown"
    for proc in "$PORT_80_PROCESS" "$PORT_443_PROCESS"; do
        case "$proc" in
            nginx*) DETECTED_PROXY="nginx"; break ;;
            apache*|httpd*) DETECTED_PROXY="apache"; break ;;
            traefik*) DETECTED_PROXY="traefik"; break ;;
            caddy*) DETECTED_PROXY="caddy"; break ;;
        esac
    done

    log_info "Detected existing proxy: $DETECTED_PROXY"

    if [[ "$HEADLESS" == "true" ]]; then
        SKIP_CADDY="true"
        return 0
    fi

    local choice
    choice=$(prompt_select "An existing proxy is using ports 80/443. How to proceed?" \
        "Generate config snippets for $DETECTED_PROXY and skip Caddy" \
        "Deploy Caddy on alternate ports (8080/8443)" \
        "Stop existing proxy and use Caddy" \
        "Abort setup")

    case "$choice" in
        0) SKIP_CADDY="true"
           _generate_proxy_snippet ;;
        1) CONFIG[caddy.http_port]=8080
           CONFIG[caddy.https_port]=8443
           log_warn "Caddy will listen on :8080/:8443. You must proxy 80/443 to these ports." ;;
        2) _stop_existing_proxy ;;
        3) exit "$E_USER_ABORT" ;;
    esac
}

_generate_proxy_snippet() {
    local domain="${CONFIG[domain.name]}"
    local hs_port="${PORT_SYNAPSE}"
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local snippet_dir="$install_dir/proxy-snippets"
    mkdir -p "$snippet_dir"

    case "$DETECTED_PROXY" in
        nginx)
            _gen_nginx_snippet "$domain" "$hs_port" "$snippet_dir" ;;
        apache)
            _gen_apache_snippet "$domain" "$hs_port" "$snippet_dir" ;;
        traefik)
            _gen_traefik_snippet "$domain" "$hs_port" "$snippet_dir" ;;
        *)
            _gen_generic_requirements "$domain" "$hs_port" "$snippet_dir" ;;
    esac

    log_success "Proxy config snippets written to $snippet_dir/"
}

_gen_nginx_snippet() {
    local domain="$1" hs_port="$2" dir="$3"
    cat > "$dir/matrix-nginx.conf" << NGINX
# Matrix reverse proxy for nginx
# Add to your server block or include this file

server {
    listen 443 ssl http2;
    server_name $domain;

    # TLS - update paths to your certificates
    # ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    client_max_body_size 100M;

    # Security headers
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # .well-known for Matrix
    location /.well-known/matrix/server {
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.server":"$domain:443"}';
    }

    location /.well-known/matrix/client {
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.homeserver":{"base_url":"https://$domain"}}';
    }

    # Synapse/Dendrite
    location ~ ^(/_matrix|/_synapse) {
        proxy_pass http://127.0.0.1:$hs_port;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 600s;
        proxy_buffering off;
    }
}
NGINX
}

_gen_apache_snippet() {
    local domain="$1" hs_port="$2" dir="$3"
    cat > "$dir/matrix-apache.conf" << APACHE
# Matrix reverse proxy for Apache
# Enable: a2enmod proxy proxy_http proxy_wstunnel headers ssl rewrite

<VirtualHost *:443>
    ServerName $domain

    SSLEngine on
    # SSLCertificateFile /etc/letsencrypt/live/$domain/fullchain.pem
    # SSLCertificateKeyFile /etc/letsencrypt/live/$domain/privkey.pem

    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "DENY"

    ProxyPreserveHost On
    ProxyRequests Off

    # .well-known
    RewriteEngine On
    RewriteRule ^/.well-known/matrix/server$ - [L]
    RewriteRule ^/.well-known/matrix/client$ - [L]

    <Location /.well-known/matrix/server>
        Header set Content-Type "application/json"
        Header set Access-Control-Allow-Origin "*"
    </Location>

    # Matrix API
    ProxyPass /_matrix http://127.0.0.1:$hs_port/_matrix
    ProxyPassReverse /_matrix http://127.0.0.1:$hs_port/_matrix
    ProxyPass /_synapse http://127.0.0.1:$hs_port/_synapse
    ProxyPassReverse /_synapse http://127.0.0.1:$hs_port/_synapse

    # WebSocket for sync
    RewriteCond %{HTTP:Upgrade} =websocket [NC]
    RewriteRule /_matrix/(.*) ws://127.0.0.1:$hs_port/_matrix/\$1 [P,L]
</VirtualHost>
APACHE
}

_gen_traefik_snippet() {
    local domain="$1" hs_port="$2" dir="$3"
    cat > "$dir/matrix-traefik.yml" << TRAEFIK
# Matrix dynamic config for Traefik
# Place in your Traefik dynamic config directory

http:
  routers:
    matrix:
      rule: "Host(\`$domain\`)"
      entryPoints:
        - websecure
      service: matrix
      tls:
        certResolver: letsencrypt

  services:
    matrix:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:$hs_port"
TRAEFIK
}

_gen_generic_requirements() {
    local domain="$1" hs_port="$2" dir="$3"
    cat > "$dir/matrix-proxy-requirements.txt" << GENERIC
Matrix Reverse Proxy Requirements
==================================
Domain: $domain
Homeserver backend: http://127.0.0.1:$hs_port

Required routes:
  /_matrix/*    -> http://127.0.0.1:$hs_port
  /_synapse/*   -> http://127.0.0.1:$hs_port

Required .well-known responses:
  /.well-known/matrix/server  -> {"m.server":"$domain:443"}
  /.well-known/matrix/client  -> {"m.homeserver":{"base_url":"https://$domain"}}

Required headers:
  Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY
  Access-Control-Allow-Origin: * (on .well-known endpoints)

WebSocket upgrade required for:
  /_matrix/client/*/sync

Max upload size: 100MB (client_max_body_size or equivalent)
GENERIC
}

_stop_existing_proxy() {
    local services=("nginx" "apache2" "httpd" "traefik" "caddy")
    for svc in "${services[@]}"; do
        if systemctl is-active "$svc" &>/dev/null; then
            log_substep "Stopping $svc..."
            systemctl stop "$svc"
            systemctl disable "$svc"
            rollback_snapshot "proxy" "SERVICE_STARTED" "$svc"
        fi
    done
}
