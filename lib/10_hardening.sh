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

harden_ssh() {
    log_substep "Hardening SSH"
    local ssh_dir="/etc/ssh/sshd_config.d"
    local ssh_conf="$ssh_dir/99-matrix-hardening.conf"

    mkdir -p "$ssh_dir"
    rollback_snapshot_file "$CURRENT_PHASE" "$ssh_conf"

    cat > "$ssh_conf" << 'SSH'
# Matrix Stack SSH Hardening - managed by matrix-setup
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
SSH

    # Test sshd config before reloading
    if sshd -t 2>/dev/null; then
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    else
        log_warn "SSH config test failed, reverting"
        rm -f "$ssh_conf"
    fi
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
    # Enable if not already
    ufw --force enable 2>/dev/null || true

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

    ufw reload 2>/dev/null || true
    log_substep "UFW configured"
}

_harden_firewalld() {
    systemctl enable --now firewalld 2>/dev/null || true

    local ports=("22/tcp" "80/tcp" "443/tcp" "${PORT_STUN}/tcp" "${PORT_STUN}/udp" \
                 "${PORT_STUN_TLS}/tcp" "${PORT_STUN_TLS}/udp")

    if [[ "${CONFIG[federation.enabled]:-true}" == "true" ]]; then
        ports+=("${PORT_FEDERATION}/tcp")
    fi

    ports+=("${CONFIG[coturn.min_port]:-$PORT_COTURN_MIN}-${CONFIG[coturn.max_port]:-$PORT_COTURN_MAX}/udp")

    for port in "${ports[@]}"; do
        firewall-cmd --permanent --add-port="$port" 2>/dev/null || true
        rollback_snapshot "$CURRENT_PHASE" "FIREWALL_RULE" "firewalld|$port"
    done

    firewall-cmd --reload 2>/dev/null || true
    log_substep "firewalld configured"
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
    log_warn "nftables rules written to $nft_file (apply manually: nft -f $nft_file)"
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
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"

    rollback_snapshot_file "$CURRENT_PHASE" "$jail_file"
    cat > "$jail_file" << JAIL
[matrix-synapse]
enabled = true
port = 443,$PORT_FEDERATION
filter = matrix-synapse
logpath = $install_dir/data/synapse/homeserver.log
maxretry = 5
findtime = 300
bantime = 3600
backend = auto

[sshd]
enabled = true
maxretry = 3
findtime = 300
bantime = 3600
JAIL

    rollback_snapshot_file "$CURRENT_PHASE" "$filter_file"
    cat > "$filter_file" << 'FILTER'
[Definition]
failregex = ^.* Received request: POST /_matrix/client/.*/login.*from <HOST>.*$
            ^.* Failed password login attempt.*from <HOST>.*$
            ^.*\[synapse\.rest\.client\.login\].*<HOST>.*403.*$
ignoreregex =
FILTER

    systemctl enable --now fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
}

harden_sysctl() {
    log_substep "Applying sysctl hardening"
    local sysctl_file="/etc/sysctl.d/99-matrix.conf"

    rollback_snapshot_file "$CURRENT_PHASE" "$sysctl_file"

    # Snapshot current values for rollback
    rollback_snapshot_sysctl "$CURRENT_PHASE" "net.ipv4.ip_unprivileged_port_start"
    rollback_snapshot_sysctl "$CURRENT_PHASE" "net.ipv4.tcp_syncookies"

    cat > "$sysctl_file" << 'SYSCTL'
# Matrix Stack sysctl hardening - managed by matrix-setup

# Allow rootless Podman to bind ports 80/443
net.ipv4.ip_unprivileged_port_start=80

# Network hardening
net.core.somaxconn=1024
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0

# Reduce information disclosure
net.ipv4.icmp_ignore_bogus_error_responses=1
SYSCTL

    sysctl --system &>/dev/null
}

harden_mac() {
    if [[ "$SELINUX_MODE" == "enforcing" || "$SELINUX_MODE" == "permissive" ]]; then
        log_substep "SELinux detected ($SELINUX_MODE), configuring booleans"
        setsebool -P container_manage_cgroup on 2>/dev/null || true
    fi

    if [[ "$APPARMOR_ACTIVE" == "true" ]]; then
        log_substep "AppArmor detected, no custom profiles needed for Podman"
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
