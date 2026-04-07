#!/usr/bin/env bash
# Matrix Stack Setup - System Detection
# Detects OS, hardware, security modules, network, and existing installations.
set -euo pipefail

# --- Globals populated by detection ---
OS_ID=""
OS_VERSION=""
OS_FAMILY=""     # debian, rhel, arch, suse
OS_PRETTY=""
SYSTEM_ARCH=""
SYSTEM_RAM_MB=0
DISK_FREE_GB=0
VIRT_TYPE=""
SELINUX_MODE="absent"     # enforcing, permissive, disabled, absent
APPARMOR_ACTIVE="false"
HAS_IPV6="false"
IPV6_ADDRESS=""
PUBLIC_IPV4=""
PUBLIC_IPV6=""
RESOLVED_ACTIVE="false"
UPSTREAM_DNS=""
EXISTING_INSTALL="false"
EXISTING_VERSION=""
INIT_SYSTEM=""
COMPOSE_CMD=""
COMPOSE_NETWORKING=""   # pod (localhost) or dns (service names)
PODMAN_VERSION=""
PODMAN_STORAGE_DRIVER=""

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VERSION}"
    else
        OS_ID="unknown"
        OS_VERSION="unknown"
        OS_PRETTY="Unknown Linux"
    fi

    case "$OS_ID" in
        ubuntu|debian|linuxmint|pop)
            OS_FAMILY="debian" ;;
        fedora|centos|rhel|rocky|alma|ol)
            OS_FAMILY="rhel" ;;
        arch|manjaro|endeavouros)
            OS_FAMILY="arch" ;;
        opensuse*|sles)
            OS_FAMILY="suse" ;;
        *)
            OS_FAMILY="unknown" ;;
    esac

    log_debug "Detected OS: $OS_PRETTY (family=$OS_FAMILY)"
}

detect_arch() {
    SYSTEM_ARCH="$(uname -m)"
    log_debug "Architecture: $SYSTEM_ARCH"
}

detect_ram() {
    if [[ -f /proc/meminfo ]]; then
        local mem_kb
        mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
        SYSTEM_RAM_MB=$((mem_kb / 1024))
    fi
    log_debug "RAM: ${SYSTEM_RAM_MB}MB"
}

detect_disk() {
    local target="${1:-/}"
    DISK_FREE_GB=$(df -BG "$target" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')
    DISK_FREE_GB="${DISK_FREE_GB:-0}"
    log_debug "Disk free: ${DISK_FREE_GB}GB on $target"
}

detect_virtualization() {
    if check_command systemd-detect-virt; then
        VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "none")
    elif [[ -f /sys/hypervisor/type ]]; then
        VIRT_TYPE=$(cat /sys/hypervisor/type)
    else
        VIRT_TYPE="unknown"
    fi
    log_debug "Virtualization: $VIRT_TYPE"
}

detect_init_system() {
    if [[ -d /run/systemd/system ]]; then
        INIT_SYSTEM="systemd"
    else
        INIT_SYSTEM="other"
    fi
    log_debug "Init system: $INIT_SYSTEM"
}

detect_selinux() {
    if check_command getenforce; then
        SELINUX_MODE=$(getenforce 2>/dev/null || echo "absent")
        SELINUX_MODE="${SELINUX_MODE,,}" # lowercase
    else
        SELINUX_MODE="absent"
    fi
    log_debug "SELinux: $SELINUX_MODE"
}

detect_apparmor() {
    if check_command aa-status && aa-status --enabled 2>/dev/null; then
        APPARMOR_ACTIVE="true"
    else
        APPARMOR_ACTIVE="false"
    fi
    log_debug "AppArmor: $APPARMOR_ACTIVE"
}

detect_ipv6() {
    # Check for global IPv6 address (not just link-local)
    local ipv6_addr
    ipv6_addr=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2; exit}' | cut -d/ -f1)
    if [[ -n "$ipv6_addr" ]]; then
        HAS_IPV6="true"
        IPV6_ADDRESS="$ipv6_addr"
    fi
    log_debug "IPv6: $HAS_IPV6 ($IPV6_ADDRESS)"
}

detect_resolved() {
    if systemctl is-active systemd-resolved &>/dev/null; then
        RESOLVED_ACTIVE="true"
        # Extract upstream DNS servers
        if check_command resolvectl; then
            UPSTREAM_DNS=$(resolvectl status 2>/dev/null | awk '/DNS Servers:/ {for(i=3;i<=NF;i++) printf "%s ", $i}' | xargs)
        fi
        if [[ -z "$UPSTREAM_DNS" ]]; then
            UPSTREAM_DNS="8.8.8.8 1.1.1.1"
        fi
    fi
    log_debug "systemd-resolved: $RESOLVED_ACTIVE (upstream: $UPSTREAM_DNS)"
}

detect_public_ip() {
    PUBLIC_IPV4=$(curl -4 -sf --connect-timeout 5 https://ifconfig.me 2>/dev/null || echo "")
    if [[ "$HAS_IPV6" == "true" ]]; then
        PUBLIC_IPV6=$(curl -6 -sf --connect-timeout 5 https://ifconfig.me 2>/dev/null || echo "")
    fi
    log_debug "Public IP: v4=$PUBLIC_IPV4 v6=$PUBLIC_IPV6"
}

detect_podman() {
    if check_command podman; then
        PODMAN_VERSION=$(podman --version 2>/dev/null | awk '{print $NF}')
        PODMAN_STORAGE_DRIVER=$(podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null || echo "unknown")
    fi
    log_debug "Podman: $PODMAN_VERSION (storage: $PODMAN_STORAGE_DRIVER)"
}

detect_compose_command() {
    # Prefer podman compose (v5+ built-in) > podman-compose (Python) > docker-compose
    if podman compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="podman compose"
        COMPOSE_NETWORKING="dns"  # service-name-based networking
    elif check_command podman-compose; then
        COMPOSE_CMD="podman-compose"
        COMPOSE_NETWORKING="pod"  # pod-based, use localhost
    elif check_command docker-compose; then
        COMPOSE_CMD="docker-compose"
        COMPOSE_NETWORKING="dns"
    else
        COMPOSE_CMD=""
        COMPOSE_NETWORKING=""
    fi
    log_debug "Compose: $COMPOSE_CMD (networking: $COMPOSE_NETWORKING)"
}

detect_existing_install() {
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    if [[ -f "$install_dir/$MATRIX_SETUP_STATE_FILE" ]]; then
        EXISTING_INSTALL="true"
        EXISTING_VERSION=$(grep -oP 'version=\K.*' "$install_dir/$MATRIX_SETUP_STATE_FILE" 2>/dev/null || echo "unknown")
    fi
    log_debug "Existing install: $EXISTING_INSTALL (v$EXISTING_VERSION)"
}

# Run all detection in sequence
detect_all() {
    log_verbose "Detecting system configuration..."
    detect_os
    detect_arch
    detect_ram
    detect_disk "/"
    detect_virtualization
    detect_init_system
    detect_selinux
    detect_apparmor
    detect_ipv6
    detect_resolved
    detect_podman
    detect_compose_command
}

# Print system summary
print_system_summary() {
    printf '\n%sSystem Summary%s\n' "$C_BOLD" "$C_RESET"
    printf '  %-20s %s\n' "OS:" "$OS_PRETTY"
    printf '  %-20s %s\n' "Architecture:" "$SYSTEM_ARCH"
    printf '  %-20s %s MB\n' "RAM:" "$SYSTEM_RAM_MB"
    printf '  %-20s %s GB free\n' "Disk:" "$DISK_FREE_GB"
    printf '  %-20s %s\n' "Virtualization:" "$VIRT_TYPE"
    printf '  %-20s %s\n' "Init:" "$INIT_SYSTEM"
    printf '  %-20s %s\n' "SELinux:" "$SELINUX_MODE"
    printf '  %-20s %s\n' "AppArmor:" "$APPARMOR_ACTIVE"
    printf '  %-20s %s\n' "IPv6:" "$HAS_IPV6"
    printf '  %-20s %s\n' "Podman:" "${PODMAN_VERSION:-not installed}"
    printf '  %-20s %s\n' "Compose:" "${COMPOSE_CMD:-not installed}"
    printf '  %-20s %s\n' "Storage driver:" "$PODMAN_STORAGE_DRIVER"
    printf '  %-20s %s\n' "systemd-resolved:" "$RESOLVED_ACTIVE"
    printf '\n'
}
