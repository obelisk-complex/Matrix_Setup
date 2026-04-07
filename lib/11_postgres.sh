#!/usr/bin/env bash
# Matrix Stack Setup - PostgreSQL
set -euo pipefail

PG_HOST=""      # "localhost" (host) or container service name
PG_PORT="5432"
PG_USE_CONTAINER="true"

postgres_setup() {
    log_step "Setting up PostgreSQL"

    local mode="${CONFIG[database.mode]:-auto}"

    case "$mode" in
        auto) _postgres_auto_detect ;;
        container) PG_USE_CONTAINER="true" ;;
        host) PG_USE_CONTAINER="false"
              PG_HOST="${CONFIG[database.host]:-localhost}"
              PG_PORT="${CONFIG[database.port]:-5432}" ;;
    esac

    if [[ "$PG_USE_CONTAINER" == "true" ]]; then
        _postgres_container_setup
    else
        _postgres_host_setup
    fi

    # Set connection info for homeserver config
    if [[ "$PG_USE_CONTAINER" == "true" ]]; then
        if [[ "$COMPOSE_NETWORKING" == "pod" ]]; then
            CONFIG[database.host]="localhost"
        else
            CONFIG[database.host]="postgres"
        fi
    else
        CONFIG[database.host]="$PG_HOST"
    fi
    CONFIG[database.port]="$PG_PORT"

    log_success "PostgreSQL configured"
}

_postgres_auto_detect() {
    log_substep "Auto-detecting PostgreSQL..."

    # Check if PG is running on default port
    if ss -tlnp 'sport = :5432' 2>/dev/null | grep -q LISTEN; then
        log_info "PostgreSQL detected on port 5432"

        # Check version
        local pg_version=""
        if check_command psql; then
            pg_version=$(psql --version 2>/dev/null | awk '{print $3}' | cut -d. -f1)
        fi

        if [[ -n "$pg_version" ]] && (( pg_version < MIN_PG_VERSION )); then
            log_warn "PostgreSQL $pg_version is too old (minimum: $MIN_PG_VERSION)"
            log_warn "Will deploy containerized PostgreSQL instead"
            PG_USE_CONTAINER="true"
            return
        fi

        if confirm_prompt "Use existing PostgreSQL installation?" "y"; then
            PG_USE_CONTAINER="false"
            PG_HOST="localhost"
            return
        fi
    fi

    PG_USE_CONTAINER="true"
    log_substep "Will deploy PostgreSQL in container"
}

_postgres_container_setup() {
    log_substep "Configuring containerized PostgreSQL ($POSTGRES_IMAGE)"

    # Ensure the compose fragment uses the right image and locale
    CONFIG[database.image]="$POSTGRES_IMAGE"
    CONFIG[database.user]="synapse"
    CONFIG[database.name]="synapse"
    CONFIG[database.init_args]="ENCODING='UTF8' LC_COLLATE='C' LC_CTYPE='C' template=template0"
}

_postgres_host_setup() {
    log_substep "Configuring host PostgreSQL"

    local pg_user="${CONFIG[database.user]:-synapse}"
    local pg_db="${CONFIG[database.name]:-synapse}"
    local pg_pass="${CONFIG[secrets.postgres_password]:-}"

    # Create user and database if possible
    if check_command sudo && sudo -u postgres psql -c "" 2>/dev/null; then
        log_substep "Creating database user and database..."

        sudo -u postgres psql -c "
            DO \$\$
            BEGIN
                IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$pg_user') THEN
                    CREATE ROLE $pg_user LOGIN PASSWORD '$pg_pass';
                END IF;
            END
            \$\$;
        " 2>/dev/null || true

        sudo -u postgres psql -c "
            SELECT 'CREATE DATABASE $pg_db OWNER $pg_user ENCODING \"UTF8\" LC_COLLATE \"C\" LC_CTYPE \"C\" TEMPLATE template0'
            WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$pg_db')
        " -t | sudo -u postgres psql 2>/dev/null || true

        log_substep "Database '$pg_db' ready"
    else
        log_warn "Cannot access PostgreSQL. Ensure database and user exist:"
        log_warn "  CREATE ROLE $pg_user LOGIN PASSWORD '<password>';"
        log_warn "  CREATE DATABASE $pg_db OWNER $pg_user ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;"
    fi
}
