#!/usr/bin/env bash
# Matrix Stack Setup - Secret Generation and Storage
# shellcheck disable=SC1090
set -euo pipefail

secrets_generate_all() {
    log_step "Generating secrets"

    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local env_file="$install_dir/.env"

    # Don't regenerate on re-run
    if [[ -f "$env_file" ]]; then
        log_substep "Existing .env found, preserving secrets"
        # Source existing secrets
        # shellcheck source=/dev/null
        set -a; source "$env_file"; set +a
        return 0
    fi

    # Generate all secrets
    CONFIG[secrets.registration_shared_secret]=$(_gen_secret)
    CONFIG[secrets.macaroon_secret_key]=$(_gen_secret)
    CONFIG[secrets.form_secret]=$(_gen_secret)
    CONFIG[secrets.postgres_password]=$(_gen_secret)
    CONFIG[secrets.coturn_secret]=$(_gen_secret)
    CONFIG[secrets.redis_password]=$(_gen_secret)

    if [[ "${CONFIG[secrets.mode]:-env}" == "podman" ]]; then
        _store_podman_secrets
    else
        _store_env_file "$env_file"
    fi

    log_success "All secrets generated"
}

# Generate per-bridge appservice tokens
secrets_generate_bridge_tokens() {
    local bridge="$1"
    CONFIG["secrets.${bridge}_as_token"]=$(_gen_secret)
    CONFIG["secrets.${bridge}_hs_token"]=$(_gen_secret)
}

# --- Internal ---

_gen_secret() {
    openssl rand -base64 48 | tr -d '\n'
}

_store_env_file() {
    local env_file="$1"
    local install_dir
    install_dir=$(dirname "$env_file")

    mkdir -p "$install_dir"

    cat > "$env_file" << EOF
# Matrix Stack Setup - Generated Secrets
# Created: $(date -Iseconds)
# DO NOT COMMIT THIS FILE TO VERSION CONTROL

# Homeserver secrets
REGISTRATION_SHARED_SECRET=${CONFIG[secrets.registration_shared_secret]}
MACAROON_SECRET_KEY=${CONFIG[secrets.macaroon_secret_key]}
FORM_SECRET=${CONFIG[secrets.form_secret]}

# Database
POSTGRES_USER=synapse
POSTGRES_DB=synapse
POSTGRES_PASSWORD=${CONFIG[secrets.postgres_password]}

# TURN server
COTURN_SECRET=${CONFIG[secrets.coturn_secret]}

# Redis (for future worker mode)
REDIS_PASSWORD=${CONFIG[secrets.redis_password]}

# Domain
MATRIX_DOMAIN=${CONFIG[domain.name]:-}
EOF

    chmod 600 "$env_file"
    rollback_snapshot "secrets" "FILE_CREATED" "$env_file"
    log_substep "Secrets written to $env_file (chmod 600)"
}

_store_podman_secrets() {
    local matrix_user="${CONFIG[matrix_user]:-$DEFAULT_MATRIX_USER}"
    local secrets=(
        "matrix-registration-secret:${CONFIG[secrets.registration_shared_secret]}"
        "matrix-macaroon-key:${CONFIG[secrets.macaroon_secret_key]}"
        "matrix-form-secret:${CONFIG[secrets.form_secret]}"
        "matrix-postgres-password:${CONFIG[secrets.postgres_password]}"
        "matrix-coturn-secret:${CONFIG[secrets.coturn_secret]}"
        "matrix-redis-password:${CONFIG[secrets.redis_password]}"
    )

    for entry in "${secrets[@]}"; do
        local name="${entry%%:*}"
        local value="${entry#*:}"

        echo -n "$value" | run_as_user podman secret create "$name" - 2>/dev/null || true
        rollback_snapshot "secrets" "SECRET_CREATED" "podman:$name"
    done

    log_substep "Secrets stored as Podman secrets"
}
