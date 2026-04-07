#!/usr/bin/env bash
# Matrix Stack Setup - Post-Install Report
set -euo pipefail

report_generate() {
    log_step "Generating post-install report"

    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local domain="${CONFIG[domain.name]}"
    local report_file="$install_dir/post-install-report.txt"
    local hs_type="${CONFIG[homeserver.type]:-synapse}"

    {
        echo "=============================================="
        echo "  Matrix Stack — Post-Install Report"
        echo "  Generated: $(date -Iseconds)"
        echo "=============================================="
        echo ""

        echo "--- Service URLs ---"
        echo "  Homeserver:     https://${domain}"
        echo "  Client API:     https://${domain}/_matrix/client/versions"

        if [[ "${CONFIG[federation.enabled]:-true}" == "true" ]]; then
            echo "  Federation:     https://${domain}:${PORT_FEDERATION}"
            echo "  Fed API:        https://${domain}/_matrix/federation/v1/version"
        fi

        if [[ -n "${CONFIG[webclient.type]:-}" && "${CONFIG[webclient.type]}" != "none" ]]; then
            echo "  Web Client:     https://${CONFIG[webclient.subdomain]:-chat}.${domain}"
        fi

        if [[ "${CONFIG[admin_ui.enabled]:-false}" == "true" && "$hs_type" == "synapse" ]]; then
            echo "  Admin UI:       https://${CONFIG[admin_ui.subdomain]:-admin}.${domain}"
        fi

        if [[ "${CONFIG[monitoring.enabled]:-false}" == "true" ]]; then
            echo "  Grafana:        https://${CONFIG[monitoring.grafana_subdomain]:-grafana}.${domain}"
        fi

        echo ""
        echo "--- Ports ---"
        echo "  HTTP:           ${PORT_HTTP}"
        echo "  HTTPS:          ${PORT_HTTPS}"
        if [[ "${CONFIG[federation.enabled]:-true}" == "true" ]]; then
            echo "  Federation:     ${PORT_FEDERATION}"
        fi
        if [[ "${CONFIG[coturn.enabled]:-true}" == "true" ]]; then
            echo "  STUN:           ${PORT_STUN}"
            echo "  STUN TLS:       ${PORT_STUN_TLS}"
            echo "  TURN relay:     ${CONFIG[coturn.min_port]:-$PORT_COTURN_MIN}-${CONFIG[coturn.max_port]:-$PORT_COTURN_MAX}"
        fi

        echo ""
        echo "--- Credentials ---"
        echo "  Admin user:     @${CONFIG[admin.username]:-admin}:${domain}"
        echo "  Secrets file:   ${install_dir}/.env"
        echo "  !! SIGNING KEY: ${install_dir}/data/signing-keys/"
        echo "     ^ This key is CRITICAL. Loss = server identity compromise."
        echo "     ^ Back it up separately and store it safely."

        echo ""
        echo "--- Stack Details ---"
        echo "  Homeserver:     ${hs_type} (${CONFIG[homeserver.image]:-unknown})"
        echo "  Database:       PostgreSQL (${CONFIG[database.host]:-postgres}:${CONFIG[database.port]:-5432})"
        echo "  Compose tool:   ${COMPOSE_CMD:-podman compose}"
        echo "  Networking:     ${COMPOSE_NETWORKING:-dns}"
        echo "  Install dir:    ${install_dir}"
        echo "  Matrix user:    ${CONFIG[matrix_user]:-$DEFAULT_MATRIX_USER}"

        echo ""
        echo "--- Backup ---"
        echo "  Schedule:       Daily at 03:00 (systemd timer)"
        echo "  Location:       ${CONFIG[backup.dir]:-$DEFAULT_BACKUP_DIR}"
        echo "  Retention:      ${CONFIG[backup.retention_daily]:-$DEFAULT_BACKUP_DAILY} daily, ${CONFIG[backup.retention_weekly]:-$DEFAULT_BACKUP_WEEKLY} weekly"
        echo "  Backup script:  ${install_dir}/scripts/backup.sh"
        echo "  Restore script: ${install_dir}/scripts/restore.sh"

        if [[ "${#BRIDGES_ENABLED[@]:-0}" -gt 0 ]]; then
            echo ""
            echo "--- Bridges ---"
            for b in "${BRIDGES_ENABLED[@]}"; do
                echo "  - ${b}"
            done
        fi

        echo ""
        echo "--- Troubleshooting Commands ---"
        echo "  View logs:          ${COMPOSE_CMD:-podman compose} -f ${install_dir}/podman-compose.yml logs -f"
        echo "  Homeserver logs:    ${COMPOSE_CMD:-podman compose} -f ${install_dir}/podman-compose.yml logs -f homeserver"
        echo "  Restart stack:      ${COMPOSE_CMD:-podman compose} -f ${install_dir}/podman-compose.yml restart"
        echo "  Stop stack:         ${COMPOSE_CMD:-podman compose} -f ${install_dir}/podman-compose.yml down"
        echo "  Federation test:    curl -sf https://${domain}/_matrix/federation/v1/version"
        echo "  Check backup timer: systemctl --user status matrix-backup.timer"

        echo ""
        echo "--- Next Steps ---"
        echo "  1. Verify HTTPS: open https://${domain} in a browser"
        if [[ -n "${CONFIG[webclient.type]:-}" && "${CONFIG[webclient.type]}" != "none" ]]; then
            echo "  2. Log in at https://${CONFIG[webclient.subdomain]:-chat}.${domain}"
        fi
        if [[ "${CONFIG[federation.enabled]:-true}" == "true" ]]; then
            echo "  3. Test federation: https://federationtester.matrix.org/api/report?server_name=${domain}"
        fi
        echo "  4. Verify backup: ${install_dir}/scripts/backup.sh"
        echo "  5. Set up monitoring alerts (if Grafana enabled)"
        echo ""
        echo "=============================================="

    } | tee "$report_file"

    chmod 644 "$report_file"
    log_success "Report saved to $report_file"
}
