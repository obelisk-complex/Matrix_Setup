#!/usr/bin/env bash
# Matrix Stack Setup - Upgrade / Reconfigure
# Detects existing installation, offers upgrade options.
set -euo pipefail

# upgrade_prompt returns this when the operator picks "Reconfigure settings":
# the caller continues into the ordinary wizard/phase run instead of exiting.
# A status rather than a global, so the signal cannot be read stale.
readonly E_UPGRADE_RECONFIGURE=10

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

    # Carry forward domain from previous install. The domain is confirmed by
    # construction here - it is the one the existing install was built with,
    # and a mismatch aborted above - so a headless upgrade is not asked to
    # re-confirm it.
    CONFIG[domain.name]="$prev_domain"
    CONFIG[domain.confirmed]="true"
    CONFIG[homeserver.type]="$prev_hs"

    return 0
}

# Returns 0 when the chosen action is finished and the caller should stop,
# E_UPGRADE_RECONFIGURE when it should continue into the wizard, and the
# action's own non-zero status if one failed.
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
        1) return "$E_UPGRADE_RECONFIGURE" ;;
        2) upgrade_bridges ;;
        3) log_info "Aborted."; exit "$E_OK" ;;
    esac
}

upgrade_pull_images() {
    log_substep "Checking for image updates..."

    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local compose_file="$install_dir/podman-compose.yml"

    local db_user="${CONFIG[database.user]:-synapse}"
    local db_name="${CONFIG[database.name]:-synapse}"

    # Check PostgreSQL major version before pulling. The stack is rootless, so
    # this has to be asked as the matrix user: root's podman owns none of these
    # containers and answers with nothing at all.
    local current_pg_major=""
    current_pg_major=$(run_as_user podman exec matrix-postgres \
        psql -U "$db_user" -d "$db_name" -tAc "SHOW server_version" 2>/dev/null \
        | cut -d. -f1) || true

    if [[ -z "$current_pg_major" ]]; then
        # Failing open here would pull a new major over a data directory the
        # server cannot then read.
        log_error "Cannot read the running PostgreSQL version from matrix-postgres."
        log_error "Start the stack and re-run: the major-version check must pass before pulling."
        return 1
    fi

    local new_pg_major
    new_pg_major=$(_pg_major_from_image "$POSTGRES_IMAGE")
    if [[ -n "$new_pg_major" && "$new_pg_major" != "$current_pg_major" ]]; then
        log_error "PostgreSQL major version change detected: $current_pg_major -> $new_pg_major"
        log_error "Major version upgrades require explicit migration (pg_upgrade or dump/restore)."
        log_error "This is NOT safe to do automatically."
        return 1
    fi

    # Pull new images
    local -a compose=()
    compose_argv compose
    run_as_user "${compose[@]}" -f "$compose_file" pull 2>&1 | while IFS= read -r line; do
        log_verbose "$line"
    done

    # Restart with new images
    log_substep "Restarting services with updated images..."
    run_as_user "${compose[@]}" -f "$compose_file" up -d 2>&1 | while IFS= read -r line; do
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
