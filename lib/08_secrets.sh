#!/usr/bin/env bash
# Matrix Stack Setup - Secret Generation and Storage
# shellcheck disable=SC1090
set -euo pipefail

# Name in the Podman secret store : CONFIG key holding the value. The names are
# what templates/compose/*.yml reference under a service's 'secrets:' key, so
# renaming one means renaming it in the fragments too.
PODMAN_SECRET_NAMES=(
    "matrix-registration-secret:secrets.registration_shared_secret"
    "matrix-macaroon-key:secrets.macaroon_secret_key"
    "matrix-form-secret:secrets.form_secret"
    "matrix-postgres-password:secrets.postgres_password"
    "matrix-coturn-secret:secrets.coturn_secret"
    "matrix-redis-password:secrets.redis_password"
)

# The set this install needs. Grafana's password joins it only when monitoring
# is deployed: minting a secret no service consumes is how matrix-redis-password
# ended up inert, and an unconditional addition would fail the next run of every
# existing install that has no monitoring.
_secret_set() {
    local -n _set="$1"
    _set=("${PODMAN_SECRET_NAMES[@]}")
    if [[ "${CONFIG[monitoring.enabled]:-false}" == "true" ]]; then
        _set+=("matrix-grafana-password:secrets.grafana_admin_password")
    fi
}

secrets_generate_all() {
    log_step "Generating secrets"

    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local env_file="$install_dir/.env"
    local mode="${CONFIG[secrets.mode]:-env}"

    if [[ "$mode" == "podman" ]]; then
        # What this mode does and does not buy: no secret reaches a compose-
        # adjacent .env, and postgres and Grafana read theirs from
        # /run/secrets. The homeserver config is unchanged — Synapse has no
        # file-based option for database.args.password, so homeserver.yaml
        # still holds that password, and (until the *_path options are wired)
        # the registration, macaroon, form and TURN secrets, in plaintext.
        #
        # This mode writes no .env, so the stored Podman secrets are themselves
        # the re-run signal: a complete set is read back, an empty store falls
        # through to generation, anything else is an error.
        local loaded=0
        _load_podman_secrets || loaded=$?
        (( loaded == 2 )) || return "$loaded"
    elif [[ -f "$env_file" ]]; then
        log_substep "Existing .env found, preserving secrets"
        # Source existing secrets
        # shellcheck source=/dev/null
        set -a; source "$env_file"; set +a
        # Sourcing only sets environment variables; every consumer reads the
        # CONFIG array, which config_save_state deliberately never persists.
        _load_env_secrets "$env_file" || return 1
        return 0
    fi

    # Generate all secrets
    CONFIG[secrets.registration_shared_secret]=$(_gen_secret)
    CONFIG[secrets.macaroon_secret_key]=$(_gen_secret)
    CONFIG[secrets.form_secret]=$(_gen_secret)
    CONFIG[secrets.postgres_password]=$(_gen_secret)
    CONFIG[secrets.coturn_secret]=$(_gen_secret)
    CONFIG[secrets.redis_password]=$(_gen_secret)
    if [[ "${CONFIG[monitoring.enabled]:-false}" == "true" ]]; then
        CONFIG[secrets.grafana_admin_password]=$(_gen_secret)
    fi

    if [[ "$mode" == "podman" ]]; then
        _store_podman_secrets || return 1
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

# Mirror the secrets from an already-sourced .env back into CONFIG. A .env that
# lacks one is fatal rather than regenerated: a fresh macaroon key invalidates
# every live access token, and a fresh postgres password desyncs from the
# database that already exists on disk.
_load_env_secrets() {
    local env_file="$1"
    local pairs=(
        "secrets.registration_shared_secret:REGISTRATION_SHARED_SECRET"
        "secrets.macaroon_secret_key:MACAROON_SECRET_KEY"
        "secrets.form_secret:FORM_SECRET"
        "secrets.postgres_password:POSTGRES_PASSWORD"
        "secrets.coturn_secret:COTURN_SECRET"
        "secrets.redis_password:REDIS_PASSWORD"
    )
    if [[ "${CONFIG[monitoring.enabled]:-false}" == "true" ]]; then
        pairs+=("secrets.grafana_admin_password:GRAFANA_ADMIN_PASSWORD")
    fi
    local missing=()
    local entry key var value

    for entry in "${pairs[@]}"; do
        key="${entry%%:*}"
        var="${entry#*:}"
        value="${!var:-}"
        if [[ -z "$value" ]]; then
            missing+=("$var")
            continue
        fi
        CONFIG["$key"]="$value"
    done

    if (( ${#missing[@]} > 0 )); then
        log_error "Existing $env_file is missing required secrets: ${missing[*]}"
        log_error "Add them by hand, or delete $env_file to regenerate the whole set"
        return 1
    fi

    log_substep "Loaded ${#pairs[@]} secrets from existing .env"
}

_store_env_file() {
    local env_file="$1"
    local install_dir
    install_dir=$(dirname "$env_file")

    mkdir -p "$install_dir"

    # Create the secret file with restrictive permissions from the outset
    # (umask 077 in a subshell) so there is no world-readable window between
    # creation and the chmod below.
    ( umask 077; cat > "$env_file" << EOF
# Matrix Stack Setup - Generated Secrets
# Created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
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
    # Only present when monitoring is deployed, so that a stack without Grafana
    # does not carry a credential nothing consumes.
    if [[ -n "${CONFIG[secrets.grafana_admin_password]:-}" ]]; then
        cat >> "$env_file" << EOF

# Monitoring
GRAFANA_ADMIN_PASSWORD=${CONFIG[secrets.grafana_admin_password]}
EOF
    fi
    )

    chmod 600 "$env_file"
    rollback_snapshot "secrets" "FILE_CREATED" "$env_file"
    log_substep "Secrets written to $env_file (chmod 600)"
}

# Mirrors the stored secret set back into CONFIG so a re-run renders the same
# values into homeserver.yaml. Returns 0 when the whole set was loaded, 2 when
# the store is empty (the caller generates), 1 on a partial or unreadable set.
_load_podman_secrets() {
    local wanted=() present=() missing=()
    local entry name key value
    _secret_set wanted

    for entry in "${wanted[@]}"; do
        name="${entry%%:*}"
        if run_as_user podman secret exists "$name" 2>/dev/null; then
            present+=("$name")
        else
            missing+=("$name")
        fi
    done

    (( ${#present[@]} > 0 )) || return 2

    # Regenerating the rest would mint a postgres password that no longer
    # matches the database on disk, so a half-present set is fatal in the same
    # way a half-filled .env is.
    if (( ${#missing[@]} > 0 )); then
        log_error "Podman secret store holds only part of the set; missing: ${missing[*]}"
        log_error "Add them by hand, or 'podman secret rm' the rest to regenerate the whole set"
        return 1
    fi

    for entry in "${wanted[@]}"; do
        name="${entry%%:*}"
        key="${entry#*:}"
        value=$(run_as_user podman secret inspect --showsecret \
            --format '{{.SecretData}}' "$name" 2>/dev/null) || value=""
        if [[ -z "$value" ]]; then
            log_error "Cannot read Podman secret '$name' back"
            log_error "--podman-secrets re-runs need Podman >= 4.7.0, which added 'podman secret inspect --showsecret'"
            return 1
        fi
        CONFIG["$key"]="$value"
    done

    log_substep "Loaded ${#wanted[@]} secrets from the Podman secret store"
}

_store_podman_secrets() {
    local wanted=()
    local entry name key value
    _secret_set wanted

    for entry in "${wanted[@]}"; do
        name="${entry%%:*}"
        key="${entry#*:}"
        value="${CONFIG[$key]}"

        # Idempotent: preserve an existing secret (re-run safety). Any other
        # failure is fatal rather than silently swallowed — a missing secret
        # would otherwise surface only as an opaque container start failure.
        if run_as_user podman secret exists "$name" 2>/dev/null; then
            log_substep "Podman secret '$name' already exists, preserving"
            continue
        fi
        if ! printf '%s' "$value" | run_as_user podman secret create "$name" - >/dev/null 2>&1; then
            log_error "Failed to create Podman secret '$name'"
            return 1
        fi
        rollback_snapshot "secrets" "SECRET_CREATED" "podman:$name"
    done

    log_substep "Secrets stored as Podman secrets"
}
