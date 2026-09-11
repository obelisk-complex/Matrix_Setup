#!/usr/bin/env bash
# Matrix Stack Setup - Existing Proxy Detection
# shellcheck disable=SC2034,SC2154
set -euo pipefail

DETECTED_PROXY=""

# Decides whether the stack deploys its own Caddy or defers to a proxy already
# bound to 80/443, and records the decision in CONFIG[proxy.external] — the
# single source of truth read by compose_assemble() (fragment selection),
# caddy_setup() and wizard_step_proxy(). Two names for this fact (a SKIP_CADDY
# global that nothing read, and CONFIG[proxy.external] that nothing wrote) is
# why "skip Caddy" could never take effect.
#
# Called twice on an interactive run — once from wizard_step_proxy, once from
# setup.sh's phase list — so a decision already taken short-circuits the second
# call rather than prompting again.
proxy_detect() {
    if [[ -n "${CONFIG[proxy.external]:-}" ]]; then
        log_debug "Proxy decision already recorded: proxy.external=${CONFIG[proxy.external]}"
        return 0
    fi

    if network_check_ports; then
        log_substep "Ports 80/443 are available"
        CONFIG[proxy.external]="false"
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

    CONFIG[proxy.detected]="$DETECTED_PROXY"
    log_info "Detected existing proxy: $DETECTED_PROXY"

    if [[ "$HEADLESS" == "true" ]]; then
        # No one to ask, and deploying Caddy onto a bound port would just fail
        # to start: defer to the existing proxy and leave the admin the config
        # snippets they need to point it at the homeserver.
        CONFIG[proxy.external]="true"
        log_warn "Headless: skipping Caddy and generating $DETECTED_PROXY config snippets."
        _generate_proxy_snippet
        return 0
    fi

    local choice
    choice=$(prompt_select "An existing proxy is using ports 80/443. How to proceed?" \
        "Generate config snippets for $DETECTED_PROXY and skip Caddy" \
        "Deploy Caddy on alternate ports (8080/8443)" \
        "Stop existing proxy and use Caddy" \
        "Abort setup")

    case "$choice" in
        0) CONFIG[proxy.external]="true"
           _generate_proxy_snippet ;;
        1) CONFIG[proxy.external]="false"
           CONFIG[caddy.http_port]=8080
           CONFIG[caddy.https_port]=8443
           log_warn "Caddy will listen on :8080/:8443. You must proxy 80/443 to these ports." ;;
        2) _stop_existing_proxy
           CONFIG[proxy.external]="false" ;;
        3) exit "$E_USER_ABORT" ;;
    esac
}

# Writes the config the admin needs to point their existing proxy at the
# homeserver (FR-06). The snippets live in templates/snippets/ and are rendered
# from there. They previously existed twice — as those templates and as
# heredocs here — and the two copies had diverged: the heredocs had the
# security headers and the templates did not, while the templates had the
# .well-known routing and the web-client route and the heredocs did not.
_generate_proxy_snippet() {
    local domain="${CONFIG[domain.name]}"
    local hs_port="${PORT_SYNAPSE}"
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local snippet_dir="$install_dir/proxy-snippets"
    mkdir -p "$snippet_dir"

    # The backend address here is the one compose_assemble publishes the
    # homeserver on in this mode, so the two have to be derived the same way:
    # PORT_SYNAPSE (PORT_DENDRITE is the same port) bound to proxy.bind_address.
    local hs_host
    hs_host=$(proxy_bind_host "${CONFIG[proxy.bind_address]:-$DEFAULT_PROXY_BIND_ADDRESS}")

    # shellcheck disable=SC2034  # passed to template_render by name (nameref)
    declare -A snippet_vars=(
        [DOMAIN]="$domain"
        [HS_HOST]="$hs_host"
        [HS_PORT]="$hs_port"
        [WEBCLIENT_PORT]="$PORT_WEBCLIENT"
    )
    if [[ -n "${CONFIG[webclient.type]:-}" && "${CONFIG[webclient.type]}" != "none" ]]; then
        snippet_vars[WEBCLIENT]="true"
        snippet_vars[WEBCLIENT_SUBDOMAIN]="${CONFIG[webclient.subdomain]:-chat}"
    else
        snippet_vars[WEBCLIENT]="false"
    fi

    local template output
    case "$DETECTED_PROXY" in
        nginx)   template="nginx.conf.tpl";   output="matrix-nginx.conf" ;;
        apache)  template="apache.conf.tpl";  output="matrix-apache.conf" ;;
        traefik) template="traefik.yml.tpl";  output="matrix-traefik.yml" ;;
        *)       template="generic.txt.tpl";  output="matrix-proxy-requirements.txt" ;;
    esac

    # Checked here so a missing template is reported against this path rather
    # than as a generic render failure. template_render now returns non-zero on
    # an unreadable input (it previously used `content=$(<"$input")`, whose
    # redirection failure killed the shell under errexit, making call-site
    # handling unreachable).
    local template_path="${SCRIPT_DIR}/templates/snippets/${template}"
    if [[ ! -f "$template_path" ]]; then
        log_error "Proxy snippet template not found: $template_path"
        return 1
    fi

    template_render "$template_path" \
        "$snippet_dir/$output" snippet_vars || {
        log_error "Failed to generate the $DETECTED_PROXY proxy snippet"
        return 1
    }
    # template_render inherits the caller's umask, which would otherwise leave
    # the snippet group-writable.
    chmod 644 "$snippet_dir/$output"

    log_success "Proxy config snippet written to $snippet_dir/$output"
}

_stop_existing_proxy() {
    local services=("nginx" "apache2" "httpd" "traefik" "caddy")
    local svc was_enabled
    for svc in "${services[@]}"; do
        if systemctl is-active "$svc" &>/dev/null; then
            # Recorded as SERVICE_STOPPED — the rollback handler for
            # SERVICE_STARTED stops and disables, which here would shut the
            # operator's proxy down a second time instead of restoring it.
            # `disable` below runs whether or not the unit was enabled, so
            # carry the prior state: re-enabling a hand-started proxy would
            # change its boot behaviour, and only starting an enabled one
            # would lose it at the next boot. systemctl(1): is-enabled exits 0
            # when the unit is enabled, non-zero otherwise.
            was_enabled="false"
            if systemctl is-enabled "$svc" &>/dev/null; then
                was_enabled="true"
            fi
            log_substep "Stopping $svc..."
            systemctl stop "$svc"
            systemctl disable "$svc"
            rollback_snapshot "proxy" "SERVICE_STOPPED" "${svc}|${was_enabled}"
        fi
    done
}
