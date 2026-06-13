#!/usr/bin/env bash
# Matrix Stack Setup - Homeserver Configuration (Synapse / Dendrite)
# shellcheck disable=SC2034,SC2154
set -euo pipefail

homeserver_setup() {
    log_step "Configuring homeserver"

    local hs_type="${CONFIG[homeserver.type]:-synapse}"
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local config_dir="$install_dir/config"
    local data_dir="$install_dir/data"

    mkdir -p "$config_dir" "$data_dir/media" "$data_dir/signing-keys"

    case "$hs_type" in
        synapse)  _homeserver_synapse "$config_dir" "$data_dir" ;;
        dendrite) _homeserver_dendrite "$config_dir" "$data_dir" ;;
    esac

    # Store final image reference for compose assembly
    log_success "Homeserver ($hs_type) configured"
}

# --- Synapse ---

_homeserver_synapse() {
    local config_dir="$1"
    local data_dir="$2"
    local domain="${CONFIG[domain.name]}"

    log_substep "Generating Synapse configuration"

    CONFIG[homeserver.image]="$SYNAPSE_IMAGE"

    # Build template variables
    declare -A hs_vars=()
    _homeserver_common_vars hs_vars

    # Synapse-specific
    hs_vars[MACAROON_SECRET_KEY]="${CONFIG[secrets.macaroon_secret_key]:-GENERATE_ME}"
    hs_vars[FORM_SECRET]="${CONFIG[secrets.form_secret]:-GENERATE_ME}"
    hs_vars[SIGNING_KEY_PATH]="/data/signing-keys/${domain}.signing.key"

    # Registration policy
    local reg="${CONFIG[registration.policy]:-invite-only}"
    case "$reg" in
        closed)
            hs_vars[ENABLE_REGISTRATION]="false"
            hs_vars[REGISTRATION_REQUIRES_TOKEN]="false"
            ;;
        invite-only)
            hs_vars[ENABLE_REGISTRATION]="true"
            hs_vars[REGISTRATION_REQUIRES_TOKEN]="true"
            ;;
        open-email)
            hs_vars[ENABLE_REGISTRATION]="true"
            hs_vars[REGISTRATION_REQUIRES_TOKEN]="false"
            hs_vars[REGISTRATIONS_REQUIRE_3PID]="true"
            ;;
        open-captcha)
            hs_vars[ENABLE_REGISTRATION]="true"
            hs_vars[REGISTRATION_REQUIRES_TOKEN]="false"
            hs_vars[ENABLE_CAPTCHA]="true"
            hs_vars[RECAPTCHA_PUBLIC_KEY]="${CONFIG[registration.recaptcha_public_key]:-}"
            hs_vars[RECAPTCHA_PRIVATE_KEY]="${CONFIG[registration.recaptcha_private_key]:-}"
            ;;
    esac

    # SMTP
    if [[ "${CONFIG[smtp.enabled]:-false}" == "true" ]]; then
        hs_vars[SMTP]="true"
        hs_vars[SMTP_HOST]="${CONFIG[smtp.host]:-}"
        hs_vars[SMTP_PORT]="${CONFIG[smtp.port]:-587}"
        hs_vars[SMTP_USER]="${CONFIG[smtp.user]:-}"
        hs_vars[SMTP_PASS]="${CONFIG[smtp.password]:-}"
        hs_vars[SMTP_FROM]="${CONFIG[smtp.from]:-noreply@${domain}}"
    else
        hs_vars[SMTP]="false"
    fi

    # Federation room version
    if [[ "${CONFIG[federation.enabled]:-true}" == "true" ]]; then
        hs_vars[DEFAULT_ROOM_VERSION]="12"
    else
        hs_vars[DEFAULT_ROOM_VERSION]="12"
    fi

    # Metrics endpoint for monitoring
    if [[ "${CONFIG[monitoring.enabled]:-false}" == "true" ]]; then
        hs_vars[METRICS]="true"
    else
        hs_vars[METRICS]="false"
    fi

    # Logging to file for fail2ban
    hs_vars[LOG_FILE_PATH]="/data/logs/homeserver.log"
    mkdir -p "$data_dir/logs"

    # Appservice registrations (populated by bridge setup later)
    hs_vars[APPSERVICE_CONFIG_FILES]=""

    # Render template
    template_render \
        "${SCRIPT_DIR}/templates/configs/homeserver.synapse.yaml.tpl" \
        "$config_dir/homeserver.yaml" \
        hs_vars

    rollback_snapshot "homeserver" "FILE_CREATED" "$config_dir/homeserver.yaml"
    log_substep "Synapse config written to $config_dir/homeserver.yaml"

    # Ensure signing key directory is owned by matrix user
    log_substep "Signing key will be stored at $data_dir/signing-keys/"
}

# --- Dendrite ---

_homeserver_dendrite() {
    local config_dir="$1"
    local data_dir="$2"

    log_substep "Generating Dendrite configuration"

    CONFIG[homeserver.image]="$DENDRITE_IMAGE"

    declare -A hs_vars=()
    _homeserver_common_vars hs_vars

    hs_vars[SIGNING_KEY_PATH]="/etc/dendrite/matrix_key.pem"

    # Registration
    local reg="${CONFIG[registration.policy]:-invite-only}"
    case "$reg" in
        closed|invite-only)
            hs_vars[ENABLE_REGISTRATION]="false"
            ;;
        open-email|open-captcha)
            hs_vars[ENABLE_REGISTRATION]="true"
            ;;
    esac

    # Metrics
    if [[ "${CONFIG[monitoring.enabled]:-false}" == "true" ]]; then
        hs_vars[METRICS]="true"
    else
        hs_vars[METRICS]="false"
    fi

    template_render \
        "${SCRIPT_DIR}/templates/configs/homeserver.dendrite.yaml.tpl" \
        "$config_dir/dendrite.yaml" \
        hs_vars

    rollback_snapshot "homeserver" "FILE_CREATED" "$config_dir/dendrite.yaml"
    log_substep "Dendrite config written to $config_dir/dendrite.yaml"
}

# --- Shared variable builder ---

_homeserver_common_vars() {
    local -n _vars="$1"
    local domain="${CONFIG[domain.name]}"

    _vars[SERVER_NAME]="$domain"
    _vars[DOMAIN]="$domain"
    _vars[REGISTRATION_SHARED_SECRET]="${CONFIG[secrets.registration_shared_secret]:-GENERATE_ME}"

    # Database connection
    local db_host="${CONFIG[database.host]:-postgres}"
    local db_port="${CONFIG[database.port]:-5432}"
    local db_user="${CONFIG[database.user]:-synapse}"
    local db_name="${CONFIG[database.name]:-synapse}"
    local db_pass="${CONFIG[secrets.postgres_password]:-}"

    _vars[DB_HOST]="$db_host"
    _vars[DB_PORT]="$db_port"
    _vars[DB_USER]="$db_user"
    _vars[DB_NAME]="$db_name"
    _vars[DB_PASSWORD]="$db_pass"

    # TURN server
    if [[ "${CONFIG[coturn.enabled]:-true}" == "true" ]]; then
        _vars[TURN]="true"
        _vars[TURN_URI_UDP]="turn:${domain}:${PORT_STUN}?transport=udp"
        _vars[TURN_URI_TCP]="turn:${domain}:${PORT_STUN}?transport=tcp"
        _vars[TURN_URI_TLS]="turns:${domain}:${PORT_STUN_TLS}?transport=tcp"
        _vars[TURN_SHARED_SECRET]="${CONFIG[secrets.coturn_secret]:-}"
    else
        _vars[TURN]="false"
    fi

    # Federation
    if [[ "${CONFIG[federation.enabled]:-true}" == "true" ]]; then
        _vars[FEDERATION]="true"
    else
        _vars[FEDERATION]="false"
    fi

    # Media retention
    _vars[MEDIA_RETENTION_DAYS]="${CONFIG[media_retention.days]:-$DEFAULT_MEDIA_RETENTION_DAYS}"
}

# Add appservice registration file to homeserver config (called by bridge setup)
homeserver_add_appservice() {
    local registration_file="$1"
    local config_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}/config"
    local hs_config="$config_dir/homeserver.yaml"

    if [[ ! -f "$hs_config" ]]; then
        log_warn "Homeserver config not found, cannot add appservice"
        return 1
    fi

    local hs_type="${CONFIG[homeserver.type]:-synapse}"
    if [[ "$hs_type" == "synapse" ]]; then
        # Append to app_service_config_files list in homeserver.yaml
        if grep -q "^app_service_config_files:" "$hs_config"; then
            # Insert into the existing list immediately after the key line.
            # Use awk + ENVIRON (not `sed -i`/`a\`, which are GNU-specific and
            # mangle some characters) so the path is inserted literally and
            # portably, and the file's permissions/owner are preserved.
            local tmp
            tmp=$(make_temp_file)
            REG_LINE="  - \"$registration_file\"" awk '
                { print }
                /^app_service_config_files:/ && !inserted { print ENVIRON["REG_LINE"]; inserted=1 }
            ' "$hs_config" > "$tmp"
            cat "$tmp" > "$hs_config"
            rm -f "$tmp"
        else
            # Create the list
            printf '\napp_service_config_files:\n  - "%s"\n' "$registration_file" >> "$hs_config"
        fi
    fi

    log_substep "Registered appservice: $registration_file"
}
