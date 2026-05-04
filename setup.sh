#!/usr/bin/env bash
# Matrix Stack Setup — Entry Point
# Deploys a complete Matrix communication stack using Podman Compose.
# Usage: sudo bash setup.sh [OPTIONS]
#
# Options:
#   --headless          Non-interactive mode (requires --config)
#   --config FILE       Path to TOML configuration file
#   --quiet             Suppress verbose output
#   --podman-secrets    Use Podman native secrets instead of .env
#   --generate-config   Print example TOML config and exit
#   --upgrade           Skip wizard, go straight to upgrade menu
#   --rollback          Roll back the last setup run
#   -h, --help          Show this help message
#
# shellcheck disable=SC2154
set -Eeuo pipefail

# --- Resolve script directory ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# --- Source all library modules in order ---
for lib in "$SCRIPT_DIR"/lib/[0-9][0-9]_*.sh; do
    # shellcheck source=/dev/null
    source "$lib"
done

# --- Argument parsing ---
HEADLESS="false"
QUIET="false"
CONFIG_FILE=""
DO_UPGRADE="false"
DO_ROLLBACK="false"
export HEADLESS QUIET

while [[ $# -gt 0 ]]; do
    case "$1" in
        --headless)        HEADLESS="true"; shift ;;
        --config)          CONFIG_FILE="$2"; shift 2 ;;
        --quiet)           QUIET="true"; shift ;;
        --podman-secrets)  CONFIG[secrets.mode]="podman"; shift ;;
        --generate-config) config_generate_example; exit 0 ;;
        --upgrade)         DO_UPGRADE="true"; shift ;;
        --rollback)        DO_ROLLBACK="true"; shift ;;
        -h|--help)         head -17 "$0" | tail -14; exit 0 ;;
        *)                 log_error "Unknown option: $1"; exit "$E_CONFIG" ;;
    esac
done

# --- Error handler ---
trap_handler() {
    local exit_code=$?
    local line_no="${BASH_LINENO[0]}"
    local command="${BASH_COMMAND}"

    if [[ $exit_code -ne 0 ]]; then
        echo ""
        log_error "Setup failed at line $line_no: $command (exit code: $exit_code)"
        log_error ""

        if [[ -f "${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}/$MATRIX_SETUP_MANIFEST_FILE" ]]; then
            log_warn "A rollback manifest exists. You can undo changes with:"
            log_warn "  sudo bash $0 --rollback"
        fi

        log_error "Check the output above for details."
    fi
}
trap trap_handler ERR

# Ctrl+C handler
trap_sigint() {
    echo ""
    log_warn "Setup interrupted (Ctrl+C)"

    if [[ -f "${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}/$MATRIX_SETUP_MANIFEST_FILE" ]]; then
        if confirm_prompt "Would you like to rollback changes made so far?" "y"; then
            rollback_execute_all
            log_info "Rollback completed."
        fi
    fi

    exit "$E_USER_ABORT"
}
trap trap_sigint SIGINT

# --- Main flow ---
main() {
    require_root

    # Rollback mode
    if [[ "$DO_ROLLBACK" == "true" ]]; then
        rollback_execute_all
        log_success "Rollback completed."
        exit "$E_OK"
    fi

    # Load config (TOML or defaults)
    config_load "$CONFIG_FILE"

    # Upgrade mode
    if [[ "$DO_UPGRADE" == "true" ]]; then
        if ! upgrade_check; then
            log_error "No existing installation found for upgrade."
            exit "$E_CONFIG"
        fi
        upgrade_prompt
        exit "$E_OK"
    fi

    # System detection must run before the wizard so the system-check step
    # has real values (RAM, disk, OS) instead of the defaults from 02_detect.sh.
    run_phase "System detection"        detect_all

    # Interactive wizard or headless
    if [[ "$HEADLESS" == "true" ]]; then
        log_banner
        log_info "Running in headless mode"
        if [[ -z "$CONFIG_FILE" ]]; then
            log_error "Headless mode requires --config FILE"
            exit "$E_CONFIG"
        fi
    else
        wizard_run
    fi

    # Validate config
    if ! config_validate; then
        log_error "Configuration validation failed"
        exit "$E_CONFIG"
    fi

    # Initialize rollback manifest
    rollback_init_manifest

    # === Phase 3: System Preparation ===
    run_phase "Prerequisites"           prereq_check_all
    run_phase "Matrix user setup"       user_setup
    run_phase "Network validation"      network_validate
    run_phase "Secret generation"       secrets_generate_all
    run_phase "Proxy detection"         proxy_detect

    # === Phase 4: Hardening ===
    run_phase "Server hardening"        harden_all

    # === Phase 5: Core Services ===
    run_phase "PostgreSQL"              postgres_setup
    run_phase "Homeserver"              homeserver_setup
    run_phase "Caddy reverse proxy"     caddy_setup
    run_phase "Coturn TURN/STUN"        coturn_setup

    # === Phase 6: Optional Services ===
    run_phase "Web client"              webclient_setup
    run_phase "Bridges"                 bridges_setup
    run_phase "Admin UI"                admin_ui_setup
    run_phase "Monitoring"              monitoring_setup

    # === Phase 7: Assembly & Deployment ===
    run_phase "Compose assembly"        compose_assemble
    run_phase "Quadlet systemd setup"   quadlet_setup
    run_phase "Deploy"                  deploy_run

    # === Phase 8: Post-Deployment ===
    run_phase "Backup setup"            backup_setup
    run_phase "Media retention"         media_retention_setup
    run_phase "Post-install report"     report_generate

    # Save state for future re-runs
    config_save_state

    echo ""
    log_success "Matrix Stack setup complete!"
    log_info "Report saved to: ${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}/post-install-report.txt"
}

# Phase runner with error context
run_phase() {
    local phase_name="$1"
    shift

    log_debug "Starting phase: $phase_name"

    if ! "$@"; then
        log_error "Phase '$phase_name' failed."
        return 1
    fi

    log_debug "Phase completed: $phase_name"
}

main "$@"
