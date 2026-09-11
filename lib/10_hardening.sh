#!/usr/bin/env bash
# Matrix Stack Setup - Server Hardening
# SSH, firewall, fail2ban, sysctl, SELinux/AppArmor, auto-updates.
set -euo pipefail

CURRENT_PHASE="hardening"

harden_all() {
    log_step "Hardening server"

    [[ "${CONFIG[hardening.ssh]:-true}" == "true" ]] && harden_ssh
    [[ "${CONFIG[hardening.firewall]:-true}" == "true" ]] && harden_firewall
    [[ "${CONFIG[hardening.fail2ban]:-true}" == "true" ]] && harden_fail2ban
    [[ "${CONFIG[hardening.sysctl]:-true}" == "true" ]] && harden_sysctl
    harden_mac  # Always run MAC detection/config
    [[ "${CONFIG[hardening.auto_updates]:-true}" == "true" ]] && harden_auto_updates

    log_success "Server hardening complete"
}

# Return 0 if any SSH public key is installed for root or any /home user.
_ssh_has_authorized_key() {
    local f
    shopt -s nullglob
    local files=(/root/.ssh/authorized_keys /root/.ssh/authorized_keys2 \
                 /home/*/.ssh/authorized_keys /home/*/.ssh/authorized_keys2)
    for f in "${files[@]}"; do
        [[ -s "$f" ]] || continue
        # A non-blank, non-comment line indicates a configured key.
        if grep -qE '^[[:space:]]*[^#[:space:]]' "$f" 2>/dev/null; then
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

harden_ssh() {
    log_substep "Hardening SSH"
    local ssh_dir="/etc/ssh/sshd_config.d"
    local ssh_conf="$ssh_dir/99-matrix-hardening.conf"

    # Refuse to disable password auth / root login unless an SSH public key is
    # actually installed. On a fresh password-only box this lockdown would
    # otherwise lock the only operator out with no recovery path.
    if ! _ssh_has_authorized_key; then
        log_warn "No SSH authorized_keys found for root or any /home user."
        log_warn "Skipping SSH password/root-login lockdown to avoid locking you out."
        log_warn "Install an SSH key, then set 'PasswordAuthentication no' manually or re-run."
        return 0
    fi

    mkdir -p "$ssh_dir"
    rollback_snapshot_file "$CURRENT_PHASE" "$ssh_conf"
    _harden_ssh_write "$ssh_conf" || return 1

    # Test sshd config before reloading
    if sshd -t 2>/dev/null; then
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    else
        log_warn "SSH config test failed, reverting"
        rm -f "$ssh_conf"
    fi
}

# Split from harden_ssh so the generated drop-in can be inspected without
# writing into /etc/ssh or reloading a live sshd.
_harden_ssh_write() {
    local dest="$1"
    # Restricting forwarding is opt-in. The default emits no AllowTcpForwarding
    # line at all rather than an explicit "yes": this drop-in is read ahead of
    # the operator's own sshd_config, so writing "yes" would quietly undo a
    # restriction they had already set for themselves.
    local no_forwarding="false"
    [[ "${CONFIG[hardening.ssh_tcp_forwarding]:-true}" == "true" ]] || no_forwarding="true"

    # shellcheck disable=SC2034  # passed to template_render by name (nameref)
    declare -A ssh_vars=([SSH_NO_TCP_FORWARDING]="$no_forwarding")
    template_render "${SCRIPT_DIR}/templates/hardening/99-matrix-hardening.conf.tpl" \
        "$dest" ssh_vars
}

harden_firewall() {
    log_substep "Configuring firewall"

    if check_command ufw; then
        _harden_ufw
    elif check_command firewall-cmd; then
        _harden_firewalld
    elif check_command nft; then
        _harden_nftables
    else
        log_warn "No firewall tool found. Install ufw or firewalld."
        return 0
    fi
}

_harden_ufw() {
    # Enable if not already. A failure here must be surfaced, not swallowed —
    # otherwise we report "configured" while the firewall is actually inactive.
    if ! ufw --force enable >/dev/null 2>&1; then
        log_error "Failed to enable UFW; firewall is NOT active."
        return 1
    fi

    local ports=("22/tcp" "80/tcp" "443/tcp" "${PORT_STUN}/tcp" "${PORT_STUN}/udp" \
                 "${PORT_STUN_TLS}/tcp" "${PORT_STUN_TLS}/udp")

    # Federation port
    if [[ "${CONFIG[federation.enabled]:-true}" == "true" ]]; then
        ports+=("${PORT_FEDERATION}/tcp")
    fi

    # TURN relay range
    ports+=("${CONFIG[coturn.min_port]:-$PORT_COTURN_MIN}:${CONFIG[coturn.max_port]:-$PORT_COTURN_MAX}/udp")

    for port in "${ports[@]}"; do
        ufw allow "$port" &>/dev/null
        rollback_snapshot "$CURRENT_PHASE" "FIREWALL_RULE" "ufw|allow $port"
    done

    if ! ufw reload >/dev/null 2>&1; then
        log_error "Failed to reload UFW; rules may not be active."
        return 1
    fi
    log_substep "UFW configured and active"
}

_harden_firewalld() {
    if ! systemctl enable --now firewalld >/dev/null 2>&1; then
        log_error "Failed to enable firewalld; firewall is NOT active."
        return 1
    fi

    local ports=("22/tcp" "80/tcp" "443/tcp" "${PORT_STUN}/tcp" "${PORT_STUN}/udp" \
                 "${PORT_STUN_TLS}/tcp" "${PORT_STUN_TLS}/udp")

    if [[ "${CONFIG[federation.enabled]:-true}" == "true" ]]; then
        ports+=("${PORT_FEDERATION}/tcp")
    fi

    ports+=("${CONFIG[coturn.min_port]:-$PORT_COTURN_MIN}-${CONFIG[coturn.max_port]:-$PORT_COTURN_MAX}/udp")

    for port in "${ports[@]}"; do
        if ! firewall-cmd --permanent --add-port="$port" >/dev/null 2>&1; then
            log_error "Failed to add firewall port $port"
            return 1
        fi
        rollback_snapshot "$CURRENT_PHASE" "FIREWALL_RULE" "firewalld|$port"
    done

    # Without a successful reload, --permanent rules are staged but NOT active.
    if ! firewall-cmd --reload >/dev/null 2>&1; then
        log_error "Failed to reload firewalld; permanent rules are not active."
        return 1
    fi
    log_substep "firewalld configured and active"
}

_harden_nftables() {
    # Generate nftables rules as a fallback
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local nft_file="$install_dir/matrix-nftables.conf"

    cat > "$nft_file" << NFT
#!/usr/sbin/nft -f
# Matrix Stack firewall rules
table inet matrix_filter {
    chain input {
        type filter hook input priority 0; policy drop;

        ct state established,related accept
        iif lo accept
        tcp dport { 22, 80, 443, $PORT_STUN, $PORT_STUN_TLS } accept
        udp dport { $PORT_STUN, $PORT_STUN_TLS } accept
        udp dport ${CONFIG[coturn.min_port]:-$PORT_COTURN_MIN}-${CONFIG[coturn.max_port]:-$PORT_COTURN_MAX} accept
$(if [[ "${CONFIG[federation.enabled]:-true}" == "true" ]]; then
    echo "        tcp dport $PORT_FEDERATION accept"
fi)
        icmp type echo-request limit rate 5/second accept
    }
}
NFT
    rollback_snapshot "$CURRENT_PHASE" "FILE_CREATED" "$nft_file"

    # Actually apply the ruleset. Previously this only wrote the file and
    # returned success, leaving hosts without ufw/firewalld with NO firewall at
    # all (silent fail-open of a security control the operator requested).
    if ! nft -f "$nft_file"; then
        log_error "Failed to apply nftables rules from $nft_file; firewall is NOT active."
        return 1
    fi

    # Persist across reboots where the distro nftables service includes this dir.
    if [[ -d /etc/nftables.d ]]; then
        cp "$nft_file" /etc/nftables.d/matrix.conf 2>/dev/null || true
    fi
    systemctl enable nftables >/dev/null 2>&1 || true
    log_substep "nftables rules applied from $nft_file"
}

harden_fail2ban() {
    log_substep "Configuring fail2ban"

    # Install if missing
    if ! check_command fail2ban-server; then
        case "$OS_FAMILY" in
            debian) apt-get install -y -qq fail2ban ;;
            rhel) dnf install -y fail2ban ;;
            arch) pacman -S --noconfirm fail2ban ;;
            suse) zypper install -y fail2ban ;;
        esac
    fi

    # Matrix login jail
    local jail_file="/etc/fail2ban/jail.d/matrix.conf"
    local filter_file="/etc/fail2ban/filter.d/matrix-synapse.conf"

    rollback_snapshot_file "$CURRENT_PHASE" "$jail_file"
    rollback_snapshot_file "$CURRENT_PHASE" "$filter_file"
    _harden_fail2ban_write "$jail_file" "$filter_file" || return 1

    systemctl enable --now fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
}

# Renders the jail and filter from templates/hardening/. Split from
# harden_fail2ban so the generated files can be inspected without writing into
# /etc/fail2ban or restarting a live fail2ban.
_harden_fail2ban_write() {
    local jail_dest="$1" filter_dest="$2"
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"

    # Synapse's logging config writes to /data/logs/homeserver.log inside the
    # container (templates/configs/log.config.tpl, LOG_FILE_PATH in
    # lib/12_homeserver.sh) and templates/compose/synapse.yml bind-mounts
    # <install_dir>/data/logs there. The jail previously tailed
    # <install_dir>/data/synapse/, a directory nothing creates or writes.
    local log_dir="$install_dir/data/logs"
    local log_path="$log_dir/homeserver.log"

    # Dendrite logs to stdout only (templates/configs/homeserver.dendrite.yaml.tpl
    # sets 'logging: - type: std'), so it never writes this file, and the filter's
    # patterns are Synapse-specific regardless. An enabled jail that cannot match
    # anything reads as protection while providing none.
    local synapse_jail="true"
    if [[ "${CONFIG[homeserver.type]:-synapse}" != "synapse" ]]; then
        synapse_jail="false"
        log_warn "Homeserver is Dendrite: it logs to stdout, not to a file fail2ban can tail."
        log_warn "  Installing the sshd jail only; there is no Matrix login jail on Dendrite."
    else
        _harden_fail2ban_log_dir "$log_dir"
    fi

    # shellcheck disable=SC2034  # passed to template_render by name (nameref)
    declare -A jail_vars=(
        [SYNAPSE_JAIL]="$synapse_jail"
        [HTTPS_PORT]="$PORT_HTTPS"
        [FEDERATION_PORT]="$PORT_FEDERATION"
        [SYNAPSE_LOG_PATH]="$log_path"
    )
    template_render "${SCRIPT_DIR}/templates/hardening/fail2ban-matrix.conf.tpl" \
        "$jail_dest" jail_vars || return 1

    # shellcheck disable=SC2034  # passed to template_render by name (nameref)
    declare -A filter_vars=()
    template_render "${SCRIPT_DIR}/templates/hardening/fail2ban-matrix-filter.conf.tpl" \
        "$filter_dest" filter_vars || return 1
}

# Creates the directory the Synapse jail watches, owned by the user the rootless
# container writes as.
#
# Hardening runs before homeserver_setup (setup.sh: hardening, PostgreSQL, then
# Homeserver), so without this the directory does not exist when fail2ban
# starts. fail2ban tolerates a log *file* that is not there yet — the pyinotify
# backend watches the parent directory for IN_CREATE
# (fail2ban/server/filterpyinotify.py: _addFileWatcher calls _addDirWatcher) and
# the polling backend keeps a per-path __file404Cnt (server/filterpoll.py) — but
# neither can watch a directory that does not exist. Creating it here is
# therefore sufficient, and is narrower than reordering the phases.
_harden_fail2ban_log_dir() {
    local log_dir="$1"
    local matrix_user="${CONFIG[matrix_user]:-$DEFAULT_MATRIX_USER}"

    if ! mkdir -p "$log_dir" 2>/dev/null; then
        log_warn "Could not create the Synapse log directory $log_dir."
        log_warn "  The matrix-synapse jail will not start until it exists."
        return 0
    fi

    # The homeserver container runs rootless as this user. A root-owned
    # directory would leave Synapse unable to write its log, and the jail with
    # nothing to read.
    if ! chown "$matrix_user:" "$log_dir" 2>/dev/null; then
        log_warn "Could not give $log_dir to $matrix_user; Synapse may be unable to write its log."
    fi
    chmod 750 "$log_dir" 2>/dev/null || true
    rollback_snapshot "$CURRENT_PHASE" "FILE_CREATED" "$log_dir"
}

harden_sysctl() {
    log_substep "Applying sysctl hardening"
    local sysctl_file="/etc/sysctl.d/99-matrix.conf"

    rollback_snapshot_file "$CURRENT_PHASE" "$sysctl_file"

    # Snapshot current values for rollback
    rollback_snapshot_sysctl "$CURRENT_PHASE" "net.ipv4.ip_unprivileged_port_start"
    rollback_snapshot_sysctl "$CURRENT_PHASE" "net.ipv4.tcp_syncookies"

    _harden_sysctl_write "$sysctl_file" || return 1

    sysctl --system &>/dev/null
}

# Split from harden_sysctl so the generated file can be inspected without
# writing into /etc/sysctl.d or applying anything to the running kernel.
_harden_sysctl_write() {
    local dest="$1"
    # Second argument overrides the /proc key the conntrack option probes for,
    # so the "kernel does not expose this" branch is reachable in a test.
    local conntrack_key="${2:-/proc/sys/net/netfilter/nf_conntrack_max}"

    local conntrack_max="${CONFIG[hardening.conntrack_max]:-}"
    local conntrack_set="false"
    if [[ -n "$conntrack_max" ]]; then
        # nf_conntrack is a module: on a host that has never loaded it the key
        # does not exist and `sysctl --system` fails on the whole file, taking
        # the rest of the hardening down with it.
        if [[ -e "$conntrack_key" ]]; then
            conntrack_set="true"
        else
            log_warn "Kernel does not expose $conntrack_key (nf_conntrack module not loaded)."
            log_warn "  Skipping hardening.conntrack_max=$conntrack_max; the rest of the sysctl settings still apply."
        fi
    fi

    # shellcheck disable=SC2034  # passed to template_render by name (nameref)
    declare -A sysctl_vars=(
        [IPV6_PRIVACY]="${CONFIG[hardening.ipv6_privacy]:-false}"
        [CONNTRACK_MAX_SET]="$conntrack_set"
        [CONNTRACK_MAX]="$conntrack_max"
    )
    template_render "${SCRIPT_DIR}/templates/hardening/sysctl-matrix.conf.tpl" \
        "$dest" sysctl_vars
}

# Reports the mandatory-access-control confinement actually in force. SELinux
# (RHEL/Fedora/CentOS) and AppArmor (Debian/Ubuntu/openSUSE) are mutually
# exclusive in practice, and a host may run neither (Arch); all three cases are
# stated rather than passed over silently. detect_selinux/detect_apparmor in
# lib/02_detect.sh set SELINUX_MODE and APPARMOR_ACTIVE.
harden_mac() {
    local configured="false"

    if [[ "$SELINUX_MODE" == "enforcing" || "$SELINUX_MODE" == "permissive" ]]; then
        log_substep "SELinux detected ($SELINUX_MODE), configuring booleans"
        setsebool -P container_manage_cgroup on 2>/dev/null || true
        log_substep "Container volumes are labelled :Z (see VOLUME_LABEL in lib/19_compose.sh)"
        configured="true"
    fi

    if [[ "$APPARMOR_ACTIVE" == "true" ]]; then
        # No custom profile is generated or loaded, and the reason is not that
        # one would be redundant: the stack's services run under rootless
        # Podman (lib/21_deploy.sh starts compose via run_as_user), and Podman
        # does not apply AppArmor confinement in rootless mode. Its AppArmor
        # support check consults unshare.IsRootless() and it reports
        # "AppArmor is not supported in rootless mode" /
        # "Skipping loading default AppArmor profile (rootless mode)"
        # (containers/common pkg/apparmor; strings present in the podman
        # binary). Loading a profile here would leave a policy in the kernel
        # that nothing attaches to, which reads as protection but is none.
        # Profile syntax and loading, for whoever revisits this:
        # apparmor.d(5) and apparmor_parser(8) ("-r, --replace").
        log_substep "AppArmor is active on this host"
        log_substep "No custom profile is loaded: rootless Podman does not apply AppArmor confinement"
        log_substep "  Containers are isolated by the user namespace instead; see README for the model"
        configured="true"
    fi

    if [[ "$configured" != "true" ]]; then
        log_warn "Neither SELinux nor AppArmor is active on this host."
        log_warn "  No mandatory access control confines the containers; user-namespace"
        log_warn "  isolation and the seccomp defaults are the only container boundaries."
    fi
}

harden_auto_updates() {
    log_substep "Enabling automatic security updates"

    case "$OS_FAMILY" in
        debian)
            if ! check_command unattended-upgrades; then
                apt-get install -y -qq unattended-upgrades
            fi
            # Enable automatic security updates
            cat > /etc/apt/apt.conf.d/20auto-upgrades << 'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT
            rollback_snapshot "$CURRENT_PHASE" "FILE_CREATED" "/etc/apt/apt.conf.d/20auto-upgrades"
            ;;
        rhel)
            if check_command dnf; then
                dnf install -y dnf-automatic 2>/dev/null || true
                sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf 2>/dev/null || true
                systemctl enable --now dnf-automatic.timer 2>/dev/null || true
            fi
            ;;
        arch)
            log_warn "Arch Linux: automatic updates not recommended. Use 'pacman -Syu' regularly."
            ;;
        suse)
            zypper install -y yast2-online-update-configuration 2>/dev/null || true
            ;;
    esac
}
