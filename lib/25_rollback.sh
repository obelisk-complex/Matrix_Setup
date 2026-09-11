#!/usr/bin/env bash
# Matrix Stack Setup - Rollback System
# shellcheck disable=SC2034
# Phase-based rollback with manifest tracking.
set -euo pipefail

MANIFEST_FILE=""
MANIFEST_POINTER=""

# --- Manifest management ---

# The manifest keeps an unpredictable mktemp name so it cannot be pre-created
# or symlinked by another user. That name is not knowable to a later process,
# so a fixed-name pointer beside it records the path: the ERR/INT traps and
# `setup.sh --rollback` have nothing in memory and resolve through it.
rollback_init_manifest() {
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    MANIFEST_FILE=$(mktemp "${install_dir}/${MATRIX_SETUP_MANIFEST_FILE}.XXXXXXXXXX" 2>/dev/null || \
                    mktemp "${TMPDIR:-/tmp}/${MATRIX_SETUP_MANIFEST_FILE}.XXXXXXXXXX")
    MANIFEST_POINTER="$(dirname "$MANIFEST_FILE")/${MATRIX_SETUP_MANIFEST_FILE}"
    _rollback_write_pointer
    log_debug "Rollback manifest: $MANIFEST_FILE"
}

# Publish the manifest path at the fixed pointer path. Written to a temp file
# and renamed: a rename replaces whatever sits at the target, so a symlink
# planted there is destroyed rather than written through.
_rollback_write_pointer() {
    local tmp
    tmp=$(mktemp "${MANIFEST_POINTER}.ptr.XXXXXXXXXX") || return 1
    printf '%s\n' "$MANIFEST_FILE" > "$tmp"
    mv -f "$tmp" "$MANIFEST_POINTER"
}

# Find the manifest for this run, or one left behind by a process that died.
# Sets MANIFEST_FILE and MANIFEST_POINTER; returns 1 when there is nothing to
# roll back. This is the guard for setup.sh's traps and for --rollback.
rollback_resolve_manifest() {
    if [[ -n "$MANIFEST_FILE" && -f "$MANIFEST_FILE" ]]; then
        return 0
    fi

    local dir pointer candidate
    for dir in "${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}" "${TMPDIR:-/tmp}"; do
        pointer="${dir}/${MATRIX_SETUP_MANIFEST_FILE}"
        # Rollback deletes files and stops services, so refuse to take the
        # path from anything another user could have planted: no symlinks, and
        # the file must be ours (in /tmp the sticky bit makes -O decisive).
        [[ -f "$pointer" && ! -L "$pointer" && -O "$pointer" ]] || continue
        candidate=$(head -n 1 "$pointer")
        [[ -n "$candidate" && -f "$candidate" && ! -L "$candidate" && -O "$candidate" ]] || continue
        MANIFEST_FILE="$candidate"
        MANIFEST_POINTER="$pointer"
        return 0
    done

    return 1
}

# Record a state-change for potential rollback.
# Format: TIMESTAMP|PHASE|ACTION_TYPE|ACTION_DATA
rollback_snapshot() {
    local phase="$1"
    local action_type="$2"
    local action_data="$3"

    if [[ -z "$MANIFEST_FILE" || ! -f "$MANIFEST_FILE" ]]; then
        log_debug "No manifest file, skipping snapshot"
        return 0
    fi

    echo "$(date +%s)|${phase}|${action_type}|${action_data}" >> "$MANIFEST_FILE"
}

# Snapshot a file before modification (backs up existing content)
rollback_snapshot_file() {
    local phase="$1"
    local file="$2"

    if [[ -f "$file" ]]; then
        local backup
        backup="${file}.pre-matrix.$(date +%s)"
        cp "$file" "$backup"
        rollback_snapshot "$phase" "FILE_BACKUP" "${backup}|${file}"
    fi
    rollback_snapshot "$phase" "FILE_CREATED" "$file"
}

# Snapshot a sysctl value before changing it
rollback_snapshot_sysctl() {
    local phase="$1"
    local key="$2"
    local old_val
    old_val=$(sysctl -n "$key" 2>/dev/null || echo "")
    rollback_snapshot "$phase" "SYSCTL_SET" "${key}|${old_val}"
}

# --- Rollback execution ---

# Execute rollback for a specific phase
rollback_execute_phase() {
    local target_phase="$1"

    if ! rollback_resolve_manifest; then
        log_warn "No rollback manifest found"
        return 1
    fi

    log_info "Rolling back phase: $target_phase"
    local line ts phase action_type action_data

    # Process manifest in reverse order
    tac "$MANIFEST_FILE" | while IFS='|' read -r ts phase action_type action_data; do
        [[ "$phase" != "$target_phase" ]] && continue
        _rollback_action "$action_type" "$action_data"
    done
}

# Execute full rollback (all phases, newest first)
rollback_execute_all() {
    if ! rollback_resolve_manifest; then
        log_warn "No rollback manifest found"
        return 1
    fi

    log_info "Rolling back all changes..."
    local line ts phase action_type action_data

    tac "$MANIFEST_FILE" | while IFS='|' read -r ts phase action_type action_data; do
        _rollback_action "$action_type" "$action_data"
    done
}

# Internal: execute a single rollback action
_rollback_action() {
    local action_type="$1"
    local action_data="$2"

    case "$action_type" in
        FILE_CREATED)
            if [[ -f "$action_data" ]]; then
                log_substep "Removing: $action_data"
                rm -f "$action_data"
            fi
            ;;
        FILE_BACKUP)
            local backup_path="${action_data%%|*}"
            local original_path="${action_data#*|}"
            if [[ -f "$backup_path" ]]; then
                log_substep "Restoring: $original_path"
                mv "$backup_path" "$original_path"
            fi
            ;;
        SYSCTL_SET)
            local sysctl_key="${action_data%%|*}"
            local old_val="${action_data#*|}"
            if [[ -n "$old_val" ]]; then
                log_substep "Restoring sysctl: $sysctl_key=$old_val"
                sysctl -w "${sysctl_key}=${old_val}" &>/dev/null || true
            fi
            ;;
        FIREWALL_RULE)
            local fw_tool="${action_data%%|*}"
            local rule="${action_data#*|}"
            log_substep "Removing firewall rule: $rule"
            case "$fw_tool" in
                ufw) ufw delete "$rule" &>/dev/null || true ;;
                firewalld) firewall-cmd --remove-port="$rule" --permanent &>/dev/null || true
                           firewall-cmd --reload &>/dev/null || true ;;
            esac
            ;;
        SERVICE_STARTED)
            local service="$action_data"
            log_substep "Stopping service: $service"
            systemctl --user stop "$service" &>/dev/null || \
                systemctl stop "$service" &>/dev/null || true
            systemctl --user disable "$service" &>/dev/null || \
                systemctl disable "$service" &>/dev/null || true
            ;;
        USER_CREATED)
            log_warn "Skipping user removal for safety: $action_data"
            log_warn "  Remove manually with: userdel $action_data"
            ;;
        SECRET_CREATED)
            if [[ "$action_data" == podman:* ]]; then
                local secret_name="${action_data#podman:}"
                podman secret rm "$secret_name" &>/dev/null || true
            fi
            # .env files handled by FILE_CREATED
            ;;
        DIR_CREATED)
            if [[ -d "$action_data" ]] && [[ -z "$(ls -A "$action_data" 2>/dev/null)" ]]; then
                log_substep "Removing empty directory: $action_data"
                rmdir "$action_data" 2>/dev/null || true
            fi
            ;;
        *)
            log_debug "Unknown rollback action: $action_type"
            ;;
    esac
}

# Clean up manifest after successful completion
rollback_cleanup() {
    # Only retract the pointer if it still names our manifest — a concurrent
    # run may have published its own, and stranding it would make that run's
    # changes unrecoverable.
    if [[ -n "$MANIFEST_POINTER" && -f "$MANIFEST_POINTER" ]] && \
       [[ "$(head -n 1 "$MANIFEST_POINTER" 2>/dev/null)" == "$MANIFEST_FILE" ]]; then
        rm -f "$MANIFEST_POINTER"
    fi

    if [[ -n "$MANIFEST_FILE" && -f "$MANIFEST_FILE" ]]; then
        rm -f "$MANIFEST_FILE"
        log_debug "Rollback manifest cleaned up"
    fi
}

# Guard plus recovery offer for setup.sh's ERR trap. Always returns 0: a trap
# handler that fails would mask the failure it is reporting on.
rollback_on_failure() {
    rollback_resolve_manifest || return 0

    # Don't leave the box half-configured. Interactively offer to undo;
    # otherwise print the exact manual recovery command.
    if [[ "${HEADLESS:-false}" != "true" ]] && \
       confirm_prompt "Roll back the changes made so far?" "y"; then
        rollback_execute_all && log_info "Rollback completed."
    else
        log_warn "A rollback manifest exists. You can undo changes with:"
        log_warn "  sudo bash ${0} --rollback"
    fi

    return 0
}

# Offer rollback choice to user on error
rollback_offer() {
    local current_phase="${1:-unknown}"

    log_error "An error occurred during phase: $current_phase"
    printf '\n%sRollback Options:%s\n' "$C_BOLD" "$C_RESET"
    printf '  [1] Rollback this phase only (%s)\n' "$current_phase"
    printf '  [2] Rollback everything\n'
    printf '  [3] Skip and continue\n'
    printf '  [4] Abort (leave state as-is for later --rollback)\n'

    local choice
    if [[ "$HEADLESS" == "true" ]]; then
        choice="4"
        log_warn "Headless mode: aborting without rollback"
    else
        printf 'Choice [4]: '
        read -r choice
        choice="${choice:-4}"
    fi

    case "$choice" in
        1) rollback_execute_phase "$current_phase" ;;
        2) rollback_execute_all ;;
        3) log_warn "Continuing despite error..." ;;
        4) log_warn "Manifest saved at: $MANIFEST_FILE"
           log_warn "Run with --rollback to undo changes later"
           exit "$E_ROLLBACK" ;;
    esac
}

# Trap handler for errors
setup_error_trap() {
    trap '_on_error $LINENO ${FUNCNAME[0]:-main}' ERR
    trap '_on_interrupt' INT TERM
}

_on_error() {
    local line="$1"
    local func="$2"
    log_error "Error at line $line in $func"
    rollback_offer "${CURRENT_PHASE:-unknown}"
}

_on_interrupt() {
    printf '\n'
    log_warn "Interrupted by user"
    if rollback_resolve_manifest && [[ -s "$MANIFEST_FILE" ]]; then
        # Never roll back unattended on a signal: headless callers get the
        # manifest path so they can decide.
        if [[ "${HEADLESS:-false}" != "true" ]] && \
           confirm_prompt "Roll back changes made so far?" "y"; then
            rollback_execute_all
        else
            log_warn "Manifest saved at: $MANIFEST_FILE"
            log_warn "Run with --rollback to undo changes later"
        fi
    fi
    exit "$E_USER_ABORT"
}
