#!/usr/bin/env bash
# Matrix Stack Setup - System User Management
# Creates the dedicated matrix user with rootless Podman prerequisites.
# shellcheck disable=SC2034
set -euo pipefail

user_setup() {
    log_step "Setting up matrix system user"
    local matrix_user="${CONFIG[matrix_user]:-$DEFAULT_MATRIX_USER}"

    _create_user "$matrix_user"
    _setup_subuid "$matrix_user"
    _setup_linger "$matrix_user"
    _setup_xdg_dirs "$matrix_user"
    _setup_podman_dns "$matrix_user"

    log_success "User '$matrix_user' configured for rootless Podman"
}

_create_user() {
    local user="$1"

    if id "$user" &>/dev/null; then
        log_substep "User '$user' already exists"
        return 0
    fi

    log_substep "Creating system user: $user"
    useradd --system --create-home --shell /bin/bash "$user"
    rollback_snapshot "user-setup" "USER_CREATED" "$user"
}

_setup_subuid() {
    local user="$1"
    local uid
    uid=$(id -u "$user")

    # Ensure /etc/subuid and /etc/subgid exist
    touch /etc/subuid /etc/subgid

    # Check if user has subuid/subgid entries with at least 65536 range
    if ! grep -q "^${user}:" /etc/subuid 2>/dev/null; then
        log_substep "Allocating subordinate UIDs for $user"
        usermod --add-subuids 100000-165535 "$user"
        rollback_snapshot "user-setup" "FILE_MODIFIED" "/etc/subuid"
    fi

    if ! grep -q "^${user}:" /etc/subgid 2>/dev/null; then
        log_substep "Allocating subordinate GIDs for $user"
        usermod --add-subgids 100000-165535 "$user"
        rollback_snapshot "user-setup" "FILE_MODIFIED" "/etc/subgid"
    fi

    # Verify user.max_user_namespaces sysctl
    local ns_max
    ns_max=$(sysctl -n user.max_user_namespaces 2>/dev/null || echo "0")
    if (( ns_max < 1 )); then
        log_substep "Enabling user namespaces (sysctl)"
        rollback_snapshot_sysctl "user-setup" "user.max_user_namespaces"
        sysctl -w user.max_user_namespaces=28633 &>/dev/null
        echo "user.max_user_namespaces=28633" > /etc/sysctl.d/99-matrix-userns.conf
        rollback_snapshot "user-setup" "FILE_CREATED" "/etc/sysctl.d/99-matrix-userns.conf"
    fi

    # Run podman system migrate for the user
    log_substep "Running podman system migrate"
    run_as_user podman system migrate 2>/dev/null || true
}

_setup_linger() {
    local user="$1"

    if ! loginctl show-user "$user" --property=Linger 2>/dev/null | grep -q "Linger=yes"; then
        log_substep "Enabling loginctl linger for $user"
        loginctl enable-linger "$user"
    fi
}

_setup_xdg_dirs() {
    local user="$1"
    local home
    home=$(get_user_home "$user")

    # Ensure required directories exist
    local dirs=(
        "$home/.config/containers"
        "$home/.config/containers/systemd"
        "$home/.config/systemd/user"
        "$home/.local/share/containers"
    )

    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            chown "$user:$user" "$dir"
        fi
    done
}

_setup_podman_dns() {
    local user="$1"

    # Fix DNS for systemd-resolved hosts
    if [[ "$RESOLVED_ACTIVE" != "true" ]]; then
        return 0
    fi

    local home
    home=$(get_user_home "$user")
    local conf_file="$home/.config/containers/containers.conf"

    if [[ -f "$conf_file" ]] && grep -q "dns_servers" "$conf_file"; then
        log_substep "Podman DNS already configured"
        return 0
    fi

    log_substep "Configuring Podman DNS (systemd-resolved workaround)"

    # Get upstream DNS from resolvectl
    local dns_servers="$UPSTREAM_DNS"
    if [[ -z "$dns_servers" ]]; then
        dns_servers="8.8.8.8 1.1.1.1"
    fi

    # Format as TOML array
    local dns_array=""
    for server in $dns_servers; do
        [[ -n "$dns_array" ]] && dns_array+=", "
        dns_array+="\"$server\""
    done

    mkdir -p "$(dirname "$conf_file")"
    cat > "$conf_file" << EOF
[containers]
dns_servers=[$dns_array]
EOF
    chown "$user:$user" "$conf_file"
    rollback_snapshot "user-setup" "FILE_CREATED" "$conf_file"
}
