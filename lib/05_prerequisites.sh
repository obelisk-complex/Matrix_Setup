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
                _podman_too_old_message "$PODMAN_VERSION"
                exit "$E_PREREQ"
            fi
        else
            _podman_too_old_message "$PODMAN_VERSION"
            exit "$E_PREREQ"
        fi
    fi

    if ! version_gte "$PODMAN_VERSION" "$REC_PODMAN_VERSION"; then
        log_warn "Podman >= $REC_PODMAN_VERSION recommended (found $PODMAN_VERSION)"
        log_warn "  Older versions may have networking issues with pasta/slirp4netns."
    fi

    # Enable podman.socket for rootless Podman systemd integration (Quadlet)
    _enable_podman_socket

    log_substep "Podman $PODMAN_VERSION"
}

# The AUR builds and runs code from a community repository that nobody vetted.
# We therefore: never build as root (makepkg and yay both refuse anyway), build in a
# private temp dir, show the user the PKGBUILD, and ask before executing it. In HEADLESS
# mode we refuse by default: standing up a Matrix server must not silently compile
# arbitrary third-party build scripts. Set MATRIX_ALLOW_AUR=true to opt in.

# Resolve an unprivileged user to build as. setup.sh runs as root, but makepkg refuses to
# run as root, so we need the human behind the sudo. Echoes the username, or fails.
_aur_build_user() {
    local user="${SUDO_USER:-}"
    if [[ -z "$user" || "$user" == "root" ]]; then
        log_error "Cannot build from the AUR: no unprivileged user found."
        log_error "makepkg refuses to run as root. Re-run this installer with sudo from a"
        log_error "normal user account, or install the package yourself and re-run."
        return 1
    fi
    echo "$user"
}

# Drop privileges to run a command as the build user. Prefers runuser (util-linux, always
# present on Arch); falls back to sudo. Arch installs do not always ship sudo.
_as_user() {
    local user="$1"; shift
    if check_command runuser; then
        runuser -u "$user" -- "$@"
    elif check_command sudo; then
        sudo -u "$user" "$@"
    else
        log_error "Neither runuser nor sudo is available; cannot drop privileges to build."
        return 1
    fi
}

# Ask before we compile and install something from the AUR.
_aur_consent() {
    local what="$1"

    if [[ "$HEADLESS" == "true" ]]; then
        if [[ "${MATRIX_ALLOW_AUR:-false}" == "true" ]]; then
            log_warn "HEADLESS: building '$what' from the AUR (MATRIX_ALLOW_AUR=true)"
            return 0
        fi
        log_error "'$what' is only available from the AUR, which builds unvetted third-party"
        log_error "code. Refusing in HEADLESS mode. Set MATRIX_ALLOW_AUR=true to permit it,"
        log_error "or install '$what' yourself before re-running."
        return 1
    fi

    confirm_prompt "Build and install '$what' from the AUR? It compiles unvetted third-party code." "n"
}

# Install a package from the AUR using the given helper. Runs the helper as the
# unprivileged user; it will escalate via sudo for the pacman step itself.
_install_aur_package() {
    local package="$1"
    local helper="${2:-yay}"
    local build_user

    build_user="$(_aur_build_user)" || return 1

    if ! check_command "$helper"; then
        _aur_consent "$helper (AUR helper)" || return 1
        log_info "Installing $helper AUR helper..."
        if ! _install_aur_helper "$helper" "$build_user"; then
            log_error "Failed to install AUR helper '$helper'"
            return 1
        fi
    fi

    _aur_consent "$package" || return 1

    log_info "Installing $package from AUR via $helper..."
    if _as_user "$build_user" "$helper" -S --needed "$package"; then
        log_substep "$package installed from AUR"
        return 0
    fi
    log_error "AUR install of '$package' failed"
    return 1
}

# Bootstrap an AUR helper (yay or aura) from source.
# Builds as the unprivileged user, installs the built package as root.
_install_aur_helper() {
    local helper="$1"
    local build_user="$2"
    local tmp_dir pkg

    case "$helper" in
        yay|aura) ;;
        *)
            log_error "Unsupported AUR helper: '$helper' (expected yay or aura)"
            return 1
            ;;
    esac

    # mktemp, not a predictable /tmp/...-$$ path: that is a symlink-race target on a
    # shared machine, and we are about to execute what lands in it.
    tmp_dir="$(mktemp -d -t "matrix-setup-aur-XXXXXXXX")" || {
        log_error "Could not create a temporary build directory"
        return 1
    }
    # shellcheck disable=SC2064  # intentional: expand tmp_dir now, not at trap time
    trap "rm -rf '$tmp_dir'" RETURN
    chown "$build_user" "$tmp_dir"

    log_info "Cloning $helper from the AUR..."
    if ! _as_user "$build_user" git clone --depth 1 "https://aur.archlinux.org/${helper}.git" "$tmp_dir/$helper"; then
        log_error "Failed to clone $helper from the AUR"
        return 1
    fi

    # Show what we are about to execute. This is the whole point of the exercise.
    if [[ "$HEADLESS" != "true" ]]; then
        log_info "PKGBUILD for $helper (this is the code that will run on your machine):"
        cat "$tmp_dir/$helper/PKGBUILD"
        confirm_prompt "Proceed with building $helper from the PKGBUILD above?" "n" || {
            log_info "Skipped building $helper"
            return 1
        }
    fi

    log_info "Building $helper as '$build_user' (makepkg cannot run as root)..."
    if ! _as_user "$build_user" bash -c "cd '$tmp_dir/$helper' && makepkg --noconfirm"; then
        log_error "makepkg failed for $helper"
        return 1
    fi

    pkg="$(find "$tmp_dir/$helper" -maxdepth 1 -name '*.pkg.tar.*' -print -quit)"
    if [[ -z "$pkg" ]]; then
        log_error "makepkg reported success but produced no package for $helper"
        return 1
    fi

    log_info "Installing $helper package..."
    if ! pacman -U --noconfirm "$pkg"; then
        log_error "pacman failed to install the built $helper package"
        return 1
    fi

    log_substep "$helper installed"
    return 0
}

# Auto-enable podman.socket for rootless Podman systemd integration
_enable_podman_socket() {
    if systemctl list-unit-files podman.socket &>/dev/null; then
        if ! systemctl is-enabled --quiet podman.socket 2>/dev/null; then
            log_info "Enabling podman.socket for rootless Podman systemd integration..."
            if systemctl enable --now podman.socket 2>/dev/null; then
                log_substep "podman.socket enabled"
            else
                log_warn "Failed to enable podman.socket (may need manual enable)"
            fi
        fi
    fi
}

# Explains a Podman that is present but below the Quadlet floor. The distro
# repo is the only source we install from, so when it is too old the only
# honest advice is "use a newer release of this distro".
_podman_too_old_message() {
    local found="$1"
    log_error "Podman $found is below the required $MIN_PODMAN_VERSION on ${OS_PRETTY:-this system}."
    log_error "  Quadlet, which this installer uses for every systemd unit, needs"
    log_error "  Podman 4.4.0, and --podman-secrets reads secrets back with"
    log_error "  'podman secret inspect --showsecret', which needs 4.7.0."
    log_error "  Nothing below $MIN_PODMAN_VERSION can work."
    log_error "  Your options:"
    log_error "    - Install on a distro release whose own repository ships Podman"
    log_error "      $MIN_PODMAN_VERSION or newer (see the Requirements section of README.md)."
    log_error "    - Upgrade this machine to such a release, then re-run setup.sh."
    log_error "  This installer will not add third-party repositories on your behalf."
}

# newuidmap/newgidmap for rootless Podman. The owning package differs per
# family, and on openSUSE it also differs per release: `shadow` on Leap 15.6
# and 16.0, shadow-pw-mgmt on Leap 16.1, account-utils on Tumbleweed. Asking
# zypper for the binary lets it resolve whichever package owns it.
_install_rootless_uidmap() {
    case "$OS_FAMILY" in
        debian) apt-get install -y -qq uidmap ;;
        rhel)   dnf install -y shadow-utils ;;
        arch)   pacman -S --noconfirm --needed shadow ;;
        suse)   zypper --non-interactive install --no-recommends /usr/bin/newuidmap ;;
        *)
            # Unknown family: nothing to install from. _check_tools re-checks
            # for the binaries afterwards, so warn rather than abort here.
            log_warn "Cannot install newuidmap/newgidmap automatically on ${OS_ID:-this system}."
            ;;
    esac
}

_install_podman() {
    log_info "Installing Podman..."
    # podman-compose is deliberately not in these lists: it is absent from
    # CentOS Stream 9 AppStream and from openSUSE Leap 16.x, and dnf/zypper
    # abort the whole transaction on an unknown package. _check_compose
    # installs it afterwards and has a pip fallback.
    case "$OS_FAMILY" in
        debian)
            apt-get update -qq
            apt-get install -y -qq podman podman-compose uidmap slirp4netns
            ;;
        rhel)
            # `uidmap` is a Debian package name; the RHEL family ships these
            # binaries in shadow-utils.
            if check_command dnf; then
                dnf install -y podman shadow-utils slirp4netns
            else
                yum install -y podman shadow-utils slirp4netns
            fi
            ;;
        arch)
            pacman -Sy --noconfirm podman fuse-overlayfs slirp4netns
            # Try official repo first, fall back to AUR for podman-compose
            if ! pacman -Qq podman-compose &>/dev/null; then
                if ! _install_aur_package "podman-compose" "yay"; then
                    log_warn "podman-compose AUR install failed, falling back to a pinned virtualenv"
                    _pip_install_compose || true
                fi
            fi
            # Ensure uidmap for rootless
            pacman -S --noconfirm --needed shadow 2>/dev/null || true
            ;;
        suse)
            # No `uidmap` package exists on any openSUSE release; see
            # _install_rootless_uidmap for where those binaries actually live.
            zypper --non-interactive install --no-recommends \
                podman slirp4netns fuse-overlayfs
            _install_rootless_uidmap
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
                _pip_install_compose || true
            ;;
        rhel)
            dnf install -y podman-compose 2>/dev/null || \
                _pip_install_compose || true
            ;;
        arch)
            # Try official repo first, then AUR, then the pinned virtualenv
            if ! pacman -S --noconfirm podman-compose 2>/dev/null; then
                if ! _install_aur_package "podman-compose" "yay"; then
                    _pip_install_compose || true
                fi
            fi
            ;;
        suse)
            # "podman-compose" is a virtual capability here, provided by
            # python311-podman-compose (Leap 15.6) and python313/314-podman-compose
            # (Tumbleweed). Leap 16.x has no provider at all, so the pip
            # fallback is the only route there.
            zypper --non-interactive install --no-recommends podman-compose 2>/dev/null || \
                _pip_install_compose || true
            ;;
    esac
}

# Python's venv module is a separate package on Debian and Ubuntu. On the rhel
# family it is in python3-libs, on Arch in `python`, and on openSUSE in
# python3-base / pythonNNN-base, all of which the interpreter already pulls in.
_install_venv_module() {
    case "$OS_FAMILY" in
        debian) apt-get install -y -qq python3-venv ;;
        *)
            log_warn "Python's venv module is missing and no package providing it is known on ${OS_ID:-this system}."
            return 1
            ;;
    esac
}

# Installs podman-compose into a dedicated virtualenv. This is the only pip
# call site in the installer: a system-wide install is refused outright on
# PEP 668 distributions, and the version is pinned so a fallback path does not
# silently pull whatever is newest on PyPI.
_pip_install_compose() {
    if ! check_command python3; then
        log_warn "python3 not available; cannot install podman-compose."
        return 1
    fi
    if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
        log_warn "Python >= 3.8 required for podman-compose; skipping."
        return 1
    fi
    if ! python3 -m venv --help >/dev/null 2>&1; then
        if ! _install_venv_module; then
            log_warn "Cannot install podman-compose without Python's venv module."
            return 1
        fi
    fi

    log_info "Installing podman-compose $PODMAN_COMPOSE_VERSION into $PODMAN_COMPOSE_VENV"
    install -d -m 0755 "$(dirname "$PODMAN_COMPOSE_VENV")" || return 1
    if ! python3 -m venv "$PODMAN_COMPOSE_VENV"; then
        log_error "Failed to create the virtualenv at $PODMAN_COMPOSE_VENV"
        return 1
    fi
    if ! "$PODMAN_COMPOSE_VENV/bin/pip" install --quiet \
            "podman-compose==$PODMAN_COMPOSE_VERSION"; then
        log_error "Failed to install podman-compose $PODMAN_COMPOSE_VERSION"
        return 1
    fi

    # Created by root, but executed as the unprivileged matrix user by
    # run_as_user. A restrictive root umask would leave this 0700 and the
    # failure would surface at deploy time instead of here. Ownership stays
    # with root so that user cannot modify the code it is about to run.
    chmod -R a+rX "$PODMAN_COMPOSE_VENV"

    if ! "$PODMAN_COMPOSE_VENV_BIN" --version >/dev/null 2>&1; then
        log_error "podman-compose installed but will not run from $PODMAN_COMPOSE_VENV_BIN"
        return 1
    fi

    log_substep "podman-compose $PODMAN_COMPOSE_VERSION installed in $PODMAN_COMPOSE_VENV"
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
                suse) zypper --non-interactive install --no-recommends "${missing[@]}" ;;
            esac
        else
            log_error "Required tools: ${missing[*]}"
            exit "$E_PREREQ"
        fi
    fi

    # Check for newuidmap/newgidmap (needed for rootless). Every service in the
    # stack runs rootless, so if these are still absent after the install
    # attempt the deployment cannot work: fail here rather than let containers
    # fail to start later with nothing pointing back to this cause.
    if ! check_command newuidmap || ! check_command newgidmap; then
        log_warn "newuidmap/newgidmap not found (needed for rootless Podman)"
        _install_rootless_uidmap
        if ! check_command newuidmap || ! check_command newgidmap; then
            log_error "newuidmap/newgidmap are still missing."
            log_error "  Rootless Podman cannot map subordinate uids without them, and"
            log_error "  every service in this stack runs rootless."
            log_error "  Install your distribution's shadow / uidmap package and re-run."
            exit "$E_PREREQ"
        fi
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
