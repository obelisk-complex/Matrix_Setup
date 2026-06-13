#!/usr/bin/env bash
# Matrix Stack Setup - Upgrade / Reconfigure
# Detects existing installation, offers upgrade options.
set -euo pipefail

# Extract the PostgreSQL major version from an image ref. Portable (no GNU
# grep -P) and digest-aware: drops any @sha256 suffix, takes the tag after the
# last colon, then its leading digits. A digest-only / non-numeric tag yields
# empty so the caller can skip the major-version guard gracefully.
_pg_major_from_image() {
    local ref="${1%%@*}"
    local tag="${ref##*:}"
    printf '%s' "${tag%%[!0-9]*}"
}

upgrade_check() {
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local state_file="$install_dir/$MATRIX_SETUP_STATE_FILE"

    if [[ ! -f "$state_file" ]]; then
        return 1 # No existing install
    fi

    log_info "Existing Matrix installation detected at $install_dir"

    # Load previous state
    declare -A PREV_STATE=()
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
        PREV_STATE["$key"]="$value"
    done < "$state_file"

    local prev_version="${PREV_STATE[version]:-unknown}"
    local prev_domain="${PREV_STATE[domain.name]:-unknown}"
    local prev_hs="${PREV_STATE[homeserver.type]:-unknown}"

    log_info "  Version:    $prev_version"
    log_info "  Domain:     $prev_domain"
    log_info "  Homeserver: $prev_hs"
    log_info "  Installed:  ${PREV_STATE[timestamp]:-unknown}"

    # Domain change protection
    if [[ -n "${CONFIG[domain.name]:-}" && "${CONFIG[domain.name]}" != "$prev_domain" ]]; then
        log_error "Domain change detected: '$prev_domain' -> '${CONFIG[domain.name]}'"
        log_error "Matrix server names are PERMANENT. Changing domains requires a full redeployment."
        log_error "If you want to proceed, remove $state_file and start fresh (DATA WILL BE LOST)."
        exit "$E_CONFIG"
    fi

    # Carry forward domain from previous install
    CONFIG[domain.name]="$prev_domain"
    CONFIG[homeserver.type]="$prev_hs"

    return 0
}

upgrade_prompt() {
    log_step "Upgrade options"

    local choice
    choice=$(prompt_select "What would you like to do?" \
        "Pull latest images (upgrade containers)" \
        "Reconfigure settings" \
        "Add or remove bridges" \
        "Abort")

    case "$choice" in
        0) upgrade_pull_images ;;
        1) return 0 ;; # Continue to wizard/config for reconfigure
        2) upgrade_bridges ;;
        3) log_info "Aborted."; exit "$E_OK" ;;
    esac
}

upgrade_pull_images() {
    log_substep "Checking for image updates..."

    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local compose_file="$install_dir/podman-compose.yml"

    # Check PostgreSQL major version before pulling
    local current_pg_major=""
    current_pg_major=$(podman exec matrix-postgres psql -U synapse -tAc "SHOW server_version" 2>/dev/null | cut -d. -f1) || true

    if [[ -n "$current_pg_major" ]]; then
        local new_pg_major
        new_pg_major=$(_pg_major_from_image "$POSTGRES_IMAGE")
        if [[ -n "$new_pg_major" && "$new_pg_major" != "$current_pg_major" ]]; then
            log_error "PostgreSQL major version change detected: $current_pg_major -> $new_pg_major"
            log_error "Major version upgrades require explicit migration (pg_upgrade or dump/restore)."
            log_error "This is NOT safe to do automatically."
            return 1
        fi
    fi

    # Pull new images
    $COMPOSE_CMD -f "$compose_file" pull 2>&1 | while IFS= read -r line; do
        log_verbose "$line"
    done

    # Restart with new images
    log_substep "Restarting services with updated images..."
    $COMPOSE_CMD -f "$compose_file" up -d 2>&1 | while IFS= read -r line; do
        log_verbose "$line"
    done

    log_success "Images updated and services restarted"
}

upgrade_bridges() {
    log_substep "Bridge reconfiguration..."

    local hs_type="${CONFIG[homeserver.type]:-synapse}"
    if [[ "$hs_type" != "synapse" ]]; then
        log_warn "Bridges require Synapse"
        return 0
    fi

    # Re-run bridge setup
    bridges_setup

    # Re-assemble compose file
    compose_assemble

    log_success "Bridges updated"
}
