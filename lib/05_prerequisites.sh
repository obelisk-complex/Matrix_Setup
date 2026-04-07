#!/usr/bin/env bash
# Matrix Stack Setup - Prerequisites
# Check and install Podman, compose, and other dependencies.
set -euo pipefail

prereq_check_all() {
    log_step "Checking prerequisites"

    _check_init_system
    _check_podman
    _check_compose
    _check_tools
    _check_system_resources
    _check_resolved_dns
    _check_storage_driver
}

_check_init_system() {
    if [[ "$INIT_SYSTEM" != "systemd" ]]; then
        log_error "systemd is required (Quadlet integration). Detected: $INIT_SYSTEM"
        exit "$E_PREREQ"
    fi
}

_check_podman() {
    if ! check_command podman; then
        log_warn "Podman is not installed."
        if confirm_prompt "Install Podman now?" "y"; then
            _install_podman
            detect_podman
        else
            log_error "Podman is required. Install it and re-run."
            exit "$E_PREREQ"
        fi
    fi

    if [[ -z "$PODMAN_VERSION" ]]; then
        detect_podman
    fi

    if ! version_gte "$PODMAN_VERSION" "$MIN_PODMAN_VERSION"; then
        log_error "Podman >= $MIN_PODMAN_VERSION required (found $PODMAN_VERSION)"
        if confirm_prompt "Attempt to install a newer version?" "y"; then
            _install_podman
            detect_podman
            if ! version_gte "$PODMAN_VERSION" "$MIN_PODMAN_VERSION"; then
                log_error "Still too old after install attempt. Please upgrade manually."
                exit "$E_PREREQ"
            fi
        else
            exit "$E_PREREQ"
        fi
    fi

    if ! version_gte "$PODMAN_VERSION" "$REC_PODMAN_VERSION"; then
        log_warn "Podman >= $REC_PODMAN_VERSION recommended (found $PODMAN_VERSION)"
        log_warn "  Older versions may have networking issues with pasta/slirp4netns."
    fi

    log_substep "Podman $PODMAN_VERSION"
}

_install_podman() {
    log_info "Installing Podman..."
    case "$OS_FAMILY" in
        debian)
            apt-get update -qq
            apt-get install -y -qq podman podman-compose uidmap slirp4netns
            ;;
        rhel)
            if check_command dnf; then
                dnf install -y podman podman-compose uidmap slirp4netns
            else
                yum install -y podman podman-compose uidmap slirp4netns
            fi
            ;;
        arch)
            pacman -Sy --noconfirm podman podman-compose fuse-overlayfs slirp4netns
            ;;
        suse)
            zypper install -y podman podman-compose uidmap slirp4netns
            ;;
        *)
            log_error "Cannot auto-install on $OS_ID. Install Podman manually."
            return 1
            ;;
    esac
}

_check_compose() {
    if [[ -z "$COMPOSE_CMD" ]]; then
        detect_compose_command
    fi

    if [[ -z "$COMPOSE_CMD" ]]; then
        log_warn "No compose tool found."
        if confirm_prompt "Install podman-compose?" "y"; then
            _install_compose
            detect_compose_command
        fi
    fi

    if [[ -z "$COMPOSE_CMD" ]]; then
        log_error "A compose tool is required."
        exit "$E_PREREQ"
    fi

    log_substep "Compose: $COMPOSE_CMD (networking: $COMPOSE_NETWORKING)"
}

_install_compose() {
    case "$OS_FAMILY" in
        debian)
            apt-get install -y -qq podman-compose 2>/dev/null || \
                pip3 install podman-compose 2>/dev/null || true
            ;;
        rhel)
            dnf install -y podman-compose 2>/dev/null || \
                pip3 install podman-compose 2>/dev/null || true
            ;;
        arch)
            pacman -S --noconfirm podman-compose 2>/dev/null || true
            ;;
        suse)
            zypper install -y podman-compose 2>/dev/null || \
                pip3 install podman-compose 2>/dev/null || true
            ;;
    esac
}

_check_tools() {
    local missing=()

    for tool in curl openssl jq; do
        if ! check_command "$tool"; then
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing tools: ${missing[*]}"
        if confirm_prompt "Install missing tools?" "y"; then
            case "$OS_FAMILY" in
                debian) apt-get install -y -qq "${missing[@]}" ;;
                rhel) dnf install -y "${missing[@]}" ;;
                arch) pacman -S --noconfirm "${missing[@]}" ;;
                suse) zypper install -y "${missing[@]}" ;;
            esac
        else
            log_error "Required tools: ${missing[*]}"
            exit "$E_PREREQ"
        fi
    fi

    # Check for newuidmap/newgidmap (needed for rootless)
    if ! check_command newuidmap || ! check_command newgidmap; then
        log_warn "newuidmap/newgidmap not found (needed for rootless Podman)"
        case "$OS_FAMILY" in
            debian) apt-get install -y -qq uidmap ;;
            rhel) dnf install -y shadow-utils ;;
            arch) pacman -S --noconfirm shadow ;;
            suse) zypper install -y shadow ;;
        esac
    fi

    log_substep "Required tools present"
}

_check_system_resources() {
    if (( SYSTEM_RAM_MB < MIN_RAM_MB )); then
        log_error "Minimum ${MIN_RAM_MB}MB RAM required (found ${SYSTEM_RAM_MB}MB)"
        exit "$E_PREREQ"
    fi

    if (( SYSTEM_RAM_MB < WARN_RAM_MB )); then
        log_warn "Only ${SYSTEM_RAM_MB}MB RAM detected. Dendrite recommended for low-RAM systems."
    fi

    if (( DISK_FREE_GB < MIN_DISK_GB )); then
        log_error "Minimum ${MIN_DISK_GB}GB free disk required (found ${DISK_FREE_GB}GB)"
        exit "$E_PREREQ"
    fi

    if (( DISK_FREE_GB < WARN_DISK_GB )); then
        log_warn "Only ${DISK_FREE_GB}GB free disk. Matrix servers accumulate media over time."
    fi

    log_substep "Resources: ${SYSTEM_RAM_MB}MB RAM, ${DISK_FREE_GB}GB disk"
}

_check_resolved_dns() {
    if [[ "$RESOLVED_ACTIVE" == "true" ]]; then
        log_substep "systemd-resolved detected, will configure Podman DNS"
    fi
}

_check_storage_driver() {
    if [[ "$PODMAN_STORAGE_DRIVER" == "fuse-overlayfs" ]] && \
       [[ "$SELINUX_MODE" == "enforcing" ]]; then
        log_warn "Using fuse-overlayfs with SELinux enforcing (20%+ I/O penalty)"
        log_warn "  Consider switching to native overlay if kernel >= 5.11"
    fi
}
