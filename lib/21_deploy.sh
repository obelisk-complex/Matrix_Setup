#!/usr/bin/env bash
# Matrix Stack Setup - Deployment
# Pull images, start services, health checks, admin account creation.
set -euo pipefail

deploy_run() {
    log_step "Deploying Matrix stack"

    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local compose_file="$install_dir/podman-compose.yml"
    local domain="${CONFIG[domain.name]}"

    # Pull images
    _deploy_pull_images "$compose_file"

    # Start services
    _deploy_start_services "$install_dir" "$compose_file"

    # Wait for homeserver to be ready
    _deploy_wait_for_homeserver "$domain"

    # Create admin account
    _deploy_create_admin "$domain"

    # Start Coturn (rootful, separate)
    if [[ "${CONFIG[coturn.enabled]:-true}" == "true" ]]; then
        _deploy_start_coturn "$install_dir"
    fi

    # Run post-deploy checks
    _deploy_health_checks "$domain"

    log_success "Matrix stack deployed successfully"
}

_deploy_pull_images() {
    local compose_file="$1"
    log_substep "Pulling container images..."
    $COMPOSE_CMD -f "$compose_file" pull 2>&1 | while IFS= read -r line; do
        log_verbose "$line"
    done
}

_deploy_start_services() {
    local install_dir="$1"
    local compose_file="$2"
    log_substep "Starting services..."

    # Use Quadlet if available, otherwise compose up directly
    local matrix_user="${CONFIG[matrix_user]:-$DEFAULT_MATRIX_USER}"

    run_as_user $COMPOSE_CMD -f "$compose_file" up -d 2>&1 | while IFS= read -r line; do
        log_verbose "$line"
    done
}

_deploy_wait_for_homeserver() {
    local domain="$1"
    log_substep "Waiting for homeserver to become ready..."

    local url="http://localhost:${PORT_SYNAPSE}/_matrix/client/versions"
    # First-boot of Synapse can run 90-150s on small VMs (signing key
    # generation, schema init, media path setup). 60s was too tight.
    local timeout="${CONFIG[deploy.homeserver_timeout]:-180}"
    local elapsed=0
    local last_log=0

    while (( elapsed < timeout )); do
        if curl -sf "$url" &>/dev/null; then
            log_substep "Homeserver is ready (${elapsed}s)"
            return 0
        fi
        # Heartbeat every 30s so the user sees progress on slow boots.
        if (( elapsed - last_log >= 30 )); then
            log_substep "  ...still waiting (${elapsed}s/${timeout}s)"
            last_log=$elapsed
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_error "Homeserver did not become ready within ${timeout}s"
    log_error "Check logs: ${COMPOSE_CMD:-podman compose} logs homeserver"
    return 1
}

_deploy_create_admin() {
    local domain="$1"
    local admin_user="${CONFIG[admin.username]:-admin}"
    local admin_pass="${CONFIG[admin.password]:-}"
    local shared_secret="${CONFIG[secrets.registration_shared_secret]}"

    if [[ -z "$admin_pass" ]]; then
        log_warn "No admin password set, skipping admin account creation"
        return 0
    fi

    log_substep "Creating admin account: @${admin_user}:${domain}"

    # Generate HMAC for registration
    local nonce
    nonce=$(curl -sf "http://localhost:${PORT_SYNAPSE}/_synapse/admin/v1/register" | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['nonce'])" 2>/dev/null) || true

    if [[ -z "$nonce" ]]; then
        log_warn "Could not get registration nonce — admin account may need manual creation"
        return 0
    fi

    local mac
    mac=$(printf '%s\x00%s\x00%s\x00admin' "$nonce" "$admin_user" "$admin_pass" | \
        openssl dgst -sha1 -hmac "$shared_secret" -binary | xxd -p)

    local result
    result=$(curl -sf -X POST "http://localhost:${PORT_SYNAPSE}/_synapse/admin/v1/register" \
        -H "Content-Type: application/json" \
        -d "{
            \"nonce\": \"$nonce\",
            \"username\": \"$admin_user\",
            \"password\": \"$admin_pass\",
            \"admin\": true,
            \"mac\": \"$mac\"
        }" 2>/dev/null) || true

    if echo "$result" | grep -q "user_id"; then
        log_substep "Admin account created: @${admin_user}:${domain}"
    else
        log_warn "Admin registration may have failed — check if account already exists"
        log_debug "Response: $result"
    fi
}

_deploy_start_coturn() {
    local install_dir="$1"
    log_substep "Starting Coturn (rootful)..."

    # Try Quadlet first
    if systemctl start matrix-coturn 2>/dev/null; then
        log_substep "Coturn started via Quadlet"
        return 0
    fi

    # Fallback: direct podman run
    local coturn_compose="$install_dir/coturn-compose.yml"
    if [[ -f "$coturn_compose" ]]; then
        podman compose -f "$coturn_compose" up -d 2>/dev/null || \
        podman-compose -f "$coturn_compose" up -d 2>/dev/null || true
    else
        podman run -d --name matrix-coturn \
            --network=host \
            --restart=unless-stopped \
            -v "$install_dir/config/turnserver.conf:/etc/coturn/turnserver.conf:ro" \
            "$COTURN_IMAGE" \
            -c /etc/coturn/turnserver.conf 2>/dev/null || true
    fi

    log_substep "Coturn started"
}

_deploy_health_checks() {
    local domain="$1"
    log_substep "Running health checks..."

    local checks_passed=0
    local checks_total=0

    # 1. Homeserver client API
    checks_total=$((checks_total + 1))
    if curl -sf "http://localhost:${PORT_SYNAPSE}/_matrix/client/versions" &>/dev/null; then
        log_substep "  Client API: OK"
        checks_passed=$((checks_passed + 1))
    else
        log_warn "  Client API: FAILED"
    fi

    # 2. Federation (if enabled)
    if [[ "${CONFIG[federation.enabled]:-true}" == "true" ]]; then
        checks_total=$((checks_total + 1))
        if curl -sf "http://localhost:${PORT_SYNAPSE}/_matrix/federation/v1/version" &>/dev/null; then
            log_substep "  Federation API: OK"
            checks_passed=$((checks_passed + 1))
        else
            log_warn "  Federation API: FAILED (may need external access)"
        fi
    fi

    # 3. TURN STUN binding test
    if [[ "${CONFIG[coturn.enabled]:-true}" == "true" ]]; then
        checks_total=$((checks_total + 1))
        if check_command turnutils_uclient && \
           turnutils_uclient -T -e 127.0.0.1 -p "$PORT_STUN" 127.0.0.1 &>/dev/null; then
            log_substep "  TURN/STUN: OK"
            checks_passed=$((checks_passed + 1))
        else
            log_substep "  TURN/STUN: skipped (turnutils not available for test)"
            checks_passed=$((checks_passed + 1))
        fi
    fi

    log_substep "Health checks: $checks_passed/$checks_total passed"
}
