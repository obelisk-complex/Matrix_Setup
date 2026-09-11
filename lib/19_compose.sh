#!/usr/bin/env bash
# Matrix Stack Setup - Compose File Assembly
# Merges compose fragments into a final podman-compose.yml. Fragments hold
# indented stanzas only and name their top-level key with a '# @section <key>'
# marker, so the assembled file has exactly one 'services:', 'networks:',
# 'volumes:' and 'secrets:' key.
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

    # Render each fragment into the top-level section it declares. Fragments
    # carry no top-level key of their own: concatenating them verbatim produced
    # one 'services:' key per fragment, and a YAML parser keeps only the last,
    # so every service but one silently disappeared.
    declare -A sections=([services]="" [networks]="" [volumes]="" [secrets]="")
    local fragment rendered
    for fragment in "${fragments[@]}"; do
        if [[ ! -f "$fragment" ]]; then
            log_warn "Compose fragment not found: $fragment"
            continue
        fi

        rendered=$(_compose_render_fragment "$fragment" compose_vars) || return 1
        _compose_collect_sections sections "$rendered" "$fragment" || return 1
    done

    # Bridge plugins emit an indented service stanza with no section marker,
    # which _compose_collect_sections files under services.
    if (( ${#BRIDGES_ENABLED[@]} > 0 )); then
        for bridge_name in "${BRIDGES_ENABLED[@]}"; do
            local plugin="${SCRIPT_DIR}/bridges/${bridge_name}.sh"
            if [[ -f "$plugin" ]]; then
                # shellcheck source=/dev/null
                source "$plugin"
                if declare -f bridge_compose_fragment &>/dev/null; then
                    local bridge_fragment
                    bridge_fragment=$(bridge_compose_fragment)
                    _compose_collect_sections sections "$bridge_fragment" "$plugin" || return 1
                fi
            fi
        done
    fi

    _compose_write_file "$compose_file" "$(_compose_emit_sections sections)" \
        "${CONFIG[matrix_user]:-$DEFAULT_MATRIX_USER}"
    _compose_validate_file "$compose_file" || return 1

    log_success "Compose file assembled: $compose_file"

    # Coturn runs rootful with host networking, so it is deployed as its own
    # compose file (or Quadlet unit) rather than merged into the rootless stack.
    # _deploy_start_coturn() falls back to this file when the unit is absent.
    if [[ "${CONFIG[coturn.enabled]:-true}" == "true" ]]; then
        _compose_assemble_coturn "$install_dir" compose_vars || return 1
    fi
}

_compose_assemble_coturn() {
    local install_dir="$1"
    local vars_name="$2"
    local fragment="${SCRIPT_DIR}/templates/compose/coturn.yml"
    local coturn_file="$install_dir/coturn-compose.yml"

    if [[ ! -f "$fragment" ]]; then
        log_warn "Compose fragment not found: $fragment"
        return 0
    fi

    declare -A coturn_sections=([services]="" [networks]="" [volumes]="" [secrets]="")
    local rendered
    rendered=$(_compose_render_fragment "$fragment" "$vars_name") || return 1
    _compose_collect_sections coturn_sections "$rendered" "$fragment" || return 1

    # Coturn is started by root, so this file stays root-owned.
    _compose_write_file "$coturn_file" "$(_compose_emit_sections coturn_sections)"
    _compose_validate_file "$coturn_file" || return 1

    log_success "Coturn compose file assembled: $coturn_file"
}

# Files a fragment's lines under the top-level section it declares with a
# '# @section <key>' marker. Text containing no marker at all (bridge plugins)
# is an indented service stanza and goes under services.
_compose_collect_sections() {
    local -n _sections="$1"
    local text="$2" origin="$3"
    local section="" preamble="" line

    while IFS= read -r line; do
        if [[ "$line" =~ ^#[[:space:]]*@section[[:space:]]+([a-z]+)[[:space:]]*$ ]]; then
            section="${BASH_REMATCH[1]}"
            if [[ -z "${_sections[$section]+set}" ]]; then
                log_error "Compose fragment '$origin': unknown section '$section'"
                return 1
            fi
            continue
        fi

        if [[ -n "$section" ]]; then
            _sections["$section"]+="$line"$'\n'
        else
            preamble+="$line"$'\n'
        fi
    done <<< "$text"

    [[ -n "${preamble//[[:space:]]/}" ]] || return 0

    if [[ -z "$section" ]]; then
        _sections["services"]+="$preamble"
        return 0
    fi

    # A marked fragment may only carry comments ahead of its first marker;
    # anything else would be a top-level key sneaking back in.
    if grep -qv '^[[:space:]]*\(#.*\)\?$' <<< "$preamble"; then
        log_error "Compose fragment '$origin': content before the first '# @section' marker"
        return 1
    fi
}

# Emits each top-level key exactly once, in compose's conventional order.
_compose_emit_sections() {
    local -n _emit="$1"
    local out="# Matrix Stack Setup - generated compose file. Do not edit; re-run setup.sh." out_section
    out+=$'\n'
    for out_section in services networks volumes secrets; do
        [[ -n "${_emit[$out_section]}" ]] || continue
        out+="${out_section}:"$'\n'"${_emit[$out_section]}"
    done
    printf '%s' "$out"
}

_compose_write_file() {
    local path="$1" content="$2" owner="${3:-}"

    # An assembled compose file can contain the Cloudflare API token and DB
    # connection details. Create it with a restrictive umask (no world-readable
    # window), then lock to 0600 owned by the user that runs compose.
    ( umask 077; printf '%s\n' "$content" > "$path" )
    chmod 600 "$path"
    if [[ -n "$owner" ]]; then
        chown "$owner:" "$path" 2>/dev/null || true
    fi
    rollback_snapshot "compose" "FILE_CREATED" "$path"
}

_compose_validate_file() {
    local path="$1"

    log_substep "Validating $(basename "$path")..."
    if [[ -z "${COMPOSE_CMD:-}" ]]; then
        log_warn "No compose command available; skipping validation of $path"
        return 0
    fi

    # Keep stderr, drop stdout: on success `config` echoes the whole file,
    # secrets included. A file the compose engine rejects will not deploy, so
    # this fails the run instead of warning.
    local errors rc=0
    errors=$($COMPOSE_CMD -f "$path" config 2>&1 >/dev/null) || rc=$?
    if (( rc != 0 )); then
        log_error "Compose file is not valid: $path"
        [[ -z "$errors" ]] || printf '%s\n' "$errors" >&2
        return 1
    fi

    log_substep "Compose file valid"
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

    # Ports. PORT_HTTP/PORT_HTTPS are the container-side ports Caddy listens on
    # and never change; CADDY_HTTP_PORT/CADDY_HTTPS_PORT are the host-side ports
    # it is published on, which proxy_detect() moves to 8080/8443 when an
    # existing proxy already holds 80/443.
    _vars[PORT_HTTP]="$PORT_HTTP"
    _vars[PORT_HTTPS]="$PORT_HTTPS"
    _vars[CADDY_HTTP_PORT]="${CONFIG[caddy.http_port]:-$PORT_HTTP}"
    _vars[CADDY_HTTPS_PORT]="${CONFIG[caddy.https_port]:-$PORT_HTTPS}"
    _vars[FEDERATION_PORT]="$PORT_FEDERATION"
    _vars[STUN_PORT]="$PORT_STUN"

    # With an external proxy there is no Caddy on matrix-net, so the operator's
    # own proxy can only reach the homeserver through a published host port.
    # PROXY_BIND defaults to loopback, which leaves the port reachable from this
    # host and not from the network. The two flags are complementary because the
    # fragment renderer has no negative block form.
    # Both homeservers serve their client API on PORT_SYNAPSE (PORT_DENDRITE is
    # the same port), which is the port the snippets tell the proxy to use.
    if [[ "${CONFIG[proxy.external]:-false}" == "true" ]]; then
        _vars[PROXY_EXTERNAL]="true"
        _vars[PROXY_INTERNAL]="false"
    else
        _vars[PROXY_EXTERNAL]="false"
        _vars[PROXY_INTERNAL]="true"
    fi
    _vars[HS_PORT]="$PORT_SYNAPSE"
    _vars[WEBCLIENT_PORT]="$PORT_WEBCLIENT"
    _vars[PROXY_BIND]="$(proxy_bind_host "${CONFIG[proxy.bind_address]:-$DEFAULT_PROXY_BIND_ADDRESS}")"

    # Feature flags
    _vars[FEDERATION]="${CONFIG[federation.enabled]:-true}"
    _vars[HAS_APPSERVICES]="${CONFIG[bridges.has_appservices]:-false}"

    # Secret delivery. In env mode compose interpolates ${VAR} from the .env
    # beside the compose file; in podman mode no .env exists, so every secret
    # has to arrive as a file mounted under /run/secrets/. The two flags are
    # complementary because the fragment renderer has no negative block form.
    if [[ "${CONFIG[secrets.mode]:-env}" == "podman" ]]; then
        _vars[PODMAN_SECRETS]="true"
        _vars[ENV_SECRETS]="false"
    else
        _vars[PODMAN_SECRETS]="false"
        _vars[ENV_SECRETS]="true"
    fi

    # No CF_API_TOKEN for Caddy: DNS-01 was dropped because the pinned stock
    # image carries no DNS provider module, so nothing in that container can
    # use a Cloudflare token (lib/13_caddy.sh).

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

    # Read with $(cat …), not the faster $(<"$input"): bash(1) calls them
    # equivalent under COMMAND SUBSTITUTION, but only for a file that opens. A
    # failed open on the redirection form exits the shell outright, even from a
    # call in a `||` list where set -e is otherwise suppressed. Both call sites
    # below wrap this in a command substitution, which downgraded that to a
    # bare rc=1 with no log line. A directory opens and reads as empty, which
    # dropped the fragment's service silently, so -f is checked too.
    if [[ ! -f "$input" || ! -r "$input" ]]; then
        log_error "Compose fragment '$input': not a readable file"
        return 1
    fi
    content=$(cat -- "$input") || {
        log_error "Compose fragment '$input': failed to read"
        return 1
    }

    # Process conditional blocks. Keys come from the fragment, not from the vars
    # array, so a key the caller never set is falsy and its block is removed
    # rather than leaking {{#KEY}} markers into the compose file.
    local -a block_keys=()
    mapfile -t block_keys < <(grep -o '{{#[A-Za-z0-9_]\+}}' <<< "$content" \
        | sed 's/^{{#//; s/}}$//' | sort -u)

    local key script
    for key in "${block_keys[@]}"; do
        if [[ "${_rvars[$key]:-}" == "true" || "${_rvars[$key]:-}" == "1" ]]; then
            script="/{{#${key}}}/d; /{{\\/${key}}}/d"
        else
            script="/{{#${key}}}/,/{{\\/${key}}}/d"
        fi
        # A failed sed would leave $content empty; report it rather than
        # rendering the fragment as nothing.
        content=$(echo "$content" | sed "$script") || {
            log_error "Compose fragment '$input': failed to process block {{#${key}}}"
            return 1
        }
    done

    # Variable substitution. The `s` command below is delimited by '|', so '|'
    # must be escaped alongside the other metacharacters.
    for key in "${!_rvars[@]}"; do
        local escaped_val
        escaped_val=$(printf '%s' "${_rvars[$key]}" | sed 's/[&/\|]/\\&/g')
        content=$(echo "$content" | sed "s|{{${key}}}|${escaped_val}|g") || {
            log_error "Compose fragment '$input': failed to substitute {{${key}}} (value may contain a newline)"
            return 1
        }
    done

    echo "$content"
}
