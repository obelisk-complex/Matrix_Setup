#!/usr/bin/env bash
# Matrix Stack Setup - Media Retention
# Configures remote media cache cleanup timer.
set -euo pipefail

media_retention_setup() {
    log_step "Configuring media retention"

    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local matrix_user="${CONFIG[matrix_user]:-$DEFAULT_MATRIX_USER}"
    local user_home
    user_home=$(eval echo "~${matrix_user}")
    local timer_dir="${user_home}/.config/systemd/user"
    local retention_days="${CONFIG[media_retention.days]:-$DEFAULT_MEDIA_RETENTION_DAYS}"

    mkdir -p "$timer_dir"

    # Cleanup script
    cat > "$install_dir/scripts/media-cleanup.sh" << SCRIPT
#!/usr/bin/env bash
# Matrix media cleanup — purges remote media cache older than ${retention_days} days
set -euo pipefail

ADMIN_TOKEN="\$(cat ${install_dir}/.admin-token 2>/dev/null || true)"
DOMAIN="${CONFIG[domain.name]}"
RETENTION_MS=$((${retention_days} * 86400 * 1000))
BEFORE_TS=\$(( (\$(date +%s) - ${retention_days} * 86400) * 1000 ))

log() { printf '[%s] %s\n' "\$(date -Iseconds)" "\$*"; }

# Purge remote media cache
log "Purging remote media older than ${retention_days} days..."
curl -sf -X POST "http://localhost:${PORT_SYNAPSE}/_synapse/admin/v1/purge_media_cache?before_ts=\${BEFORE_TS}" \\
    -H "Authorization: Bearer \${ADMIN_TOKEN}" || log "WARNING: Media purge failed (admin token may be needed)"

# Check disk usage
MEDIA_DIR="${install_dir}/data/media"
if [[ -d "\$MEDIA_DIR" ]]; then
    USAGE=\$(df "\$MEDIA_DIR" --output=pcent | tail -1 | tr -d ' %')
    if (( USAGE >= 90 )); then
        log "ALERT: Disk usage at \${USAGE}% — consider expanding storage"
    elif (( USAGE >= 80 )); then
        log "WARNING: Disk usage at \${USAGE}%"
    fi
fi

log "Media cleanup completed"
SCRIPT

    chmod 750 "$install_dir/scripts/media-cleanup.sh"

    # Systemd timer
    cat > "$timer_dir/matrix-media-cleanup.service" << UNIT
[Unit]
Description=Matrix media cache cleanup

[Service]
Type=oneshot
ExecStart=${install_dir}/scripts/media-cleanup.sh
StandardOutput=journal
StandardError=journal
UNIT

    cat > "$timer_dir/matrix-media-cleanup.timer" << UNIT
[Unit]
Description=Weekly Matrix media cleanup

[Timer]
OnCalendar=Sun *-*-* 04:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
UNIT

    chown -R "${matrix_user}:" "$timer_dir"
    run_as_user systemctl --user enable matrix-media-cleanup.timer 2>/dev/null || true

    rollback_snapshot "media" "TIMER_INSTALLED" "$timer_dir/matrix-media-cleanup.timer"
    log_substep "Media cleanup timer installed (weekly, ${retention_days}-day retention)"
    log_success "Media retention configured"
}
