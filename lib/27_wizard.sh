#!/usr/bin/env bash
# Matrix Stack Setup - Interactive Wizard
# 17-step guided setup flow.
# shellcheck disable=SC2034,SC2154
set -euo pipefail

TOTAL_STEPS=17

wizard_run() {
    log_banner
    log_info "Welcome to the Matrix Stack Setup Wizard"
    log_info "This will deploy a complete Matrix communication server."
    echo ""

    wizard_step_system_check        # 1
    wizard_step_domain              # 2
    wizard_step_homeserver          # 3
    wizard_step_federation          # 4
    wizard_step_registration        # 5
    wizard_step_admin               # 6
    wizard_step_database            # 7
    wizard_step_webclient           # 8
    wizard_step_bridges             # 9
    wizard_step_smtp                # 10
    wizard_step_admin_ui            # 11
    wizard_step_monitoring          # 12
    wizard_step_backup              # 13
    wizard_step_hardening           # 14
    wizard_step_proxy               # 15
    wizard_step_secrets             # 16
    wizard_step_confirmation        # 17
}

# --- Step 1: System Check ---
wizard_step_system_check() {
    log_step "System Check"

    log_substep "OS: ${OS_ID:-unknown} ${OS_VERSION:-} (${OS_FAMILY:-unknown})"
    log_substep "Arch: ${SYSTEM_ARCH:-$(uname -m)}"
    log_substep "RAM: ${SYSTEM_RAM_MB:-?} MB"
    log_substep "Disk: ${DISK_FREE_GB:-?} GB free"

    if [[ "${SYSTEM_RAM_MB:-0}" -lt "$MIN_RAM_MB" ]]; then
        log_error "Insufficient RAM: ${SYSTEM_RAM_MB:-0} MB (minimum: ${MIN_RAM_MB} MB)"
        exit "$E_PREREQ"
    elif [[ "${SYSTEM_RAM_MB:-0}" -lt "$WARN_RAM_MB" ]]; then
        log_warn "Low RAM (${SYSTEM_RAM_MB:-0} MB). Dendrite is recommended for <2GB."
    fi

    if [[ "${DISK_FREE_GB:-0}" -lt "$MIN_DISK_GB" ]]; then
        log_error "Insufficient disk: ${DISK_FREE_GB:-0} GB (minimum: ${MIN_DISK_GB} GB)"
        exit "$E_PREREQ"
    fi

    # Check for existing install
    if upgrade_check 2>/dev/null; then
        upgrade_prompt
        return 0
    fi
}

# --- Step 2: Domain ---

# Normalise a user-entered domain: strip surrounding whitespace, any
# leading scheme (http:// or https://), any leading "//", any trailing
# slash, and a trailing "." (root-zone dot in FQDNs). Lowercase the
# result. Returns the cleaned value on stdout.
_normalize_domain() {
    local d="$1"
    # Strip ANSI CSI sequences (left over when read -e is unavailable and
    # cursor keys leak into the input as e.g. \e[D).
    d=$(printf '%s' "$d" | LC_ALL=C sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g; s/\x1b[][^ ]*//g')
    # Strip every C0 control character and DEL (0x00-0x1f, 0x7f).
    d=$(printf '%s' "$d" | LC_ALL=C tr -d '\000-\037\177')
    # Strip ASCII whitespace anywhere in the string.
    d="${d// /}"
    d="${d//$'\t'/}"
    # Strip scheme.
    d="${d#http://}"
    d="${d#https://}"
    d="${d#//}"
    # Strip trailing slash and trailing FQDN dot.
    d="${d%/}"
    d="${d%.}"
    # Lowercase.
    d="${d,,}"
    printf '%s' "$d"
}

wizard_step_domain() {
    log_step "Domain Configuration"

    echo ""
    printf '%s%s  WARNING: The Matrix server name is PERMANENT.%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
    printf '%s  Once set, it cannot be changed without losing all data and federation history.%s\n' "$C_YELLOW" "$C_RESET"
    printf '%s  Use a bare domain (e.g. example.com), not a URL or subdomain.%s\n\n' "$C_YELLOW" "$C_RESET"

    local domain raw
    raw=$(prompt_value "Matrix server name (bare domain, e.g. example.com)" "")
    domain=$(_normalize_domain "$raw")

    if [[ -z "$domain" ]]; then
        log_error "Domain is required"
        exit "$E_CONFIG"
    fi

    if ! _validate_domain "$domain"; then
        log_error "Invalid domain format: '$domain' (${#domain} bytes)"
        log_error "  Expected a bare domain like 'example.com'."
        log_error "  Allowed: lowercase letters, digits, hyphens, dots."
        log_error "  Disallowed: schemes (http://), spaces, paths, ports, underscores."
        exit "$E_CONFIG"
    fi

    # Double entry confirmation
    local domain_confirm raw_confirm
    raw_confirm=$(prompt_value "Confirm domain (type it again)" "")
    domain_confirm=$(_normalize_domain "$raw_confirm")

    if [[ "$domain" != "$domain_confirm" ]]; then
        log_error "Domains do not match: '$domain' vs '$domain_confirm'"
        exit "$E_CONFIG"
    fi

    CONFIG[domain.name]="$domain"
    CONFIG[domain.confirmed]="true"
}

# --- Step 3: Homeserver ---
wizard_step_homeserver() {
    log_step "Homeserver Selection"

    local ram="${SYSTEM_RAM_MB:-4096}"
    local recommendation=""
    if (( ram < 2048 )); then
        recommendation=" (recommended for <2GB RAM)"
    fi

    local choice
    choice=$(prompt_select "Choose your homeserver" \
        "Synapse — full-featured, most bridges and tools supported" \
        "Dendrite — lightweight, less mature${recommendation}")

    # prompt_select returns a 0-based index; match the same case convention used
    # by the other wizard steps rather than a fragile string comparison.
    case "$choice" in
        1)  CONFIG[homeserver.type]="dendrite"; log_substep "Selected: Dendrite" ;;
        *)  CONFIG[homeserver.type]="synapse";  log_substep "Selected: Synapse" ;;
    esac
}

# --- Step 4: Federation ---
wizard_step_federation() {
    log_step "Federation"
    log_substep "Federation allows your server to communicate with other Matrix servers."

    if confirm_prompt "Enable federation?" "y"; then
        CONFIG[federation.enabled]="true"
    else
        CONFIG[federation.enabled]="false"
    fi
}

# --- Step 5: Registration ---
wizard_step_registration() {
    log_step "Registration Policy"

    local choice
    choice=$(prompt_select "Who can create accounts?" \
        "Invite-only (admin creates invites)" \
        "Closed (only admin can create accounts)" \
        "Open with email verification (requires SMTP)" \
        "Open with CAPTCHA (requires reCAPTCHA keys)")

    case "$choice" in
        0) CONFIG[registration.policy]="invite-only" ;;
        1) CONFIG[registration.policy]="closed" ;;
        2) CONFIG[registration.policy]="open-email"
           CONFIG[smtp.enabled]="true" ;;
        3) CONFIG[registration.policy]="open-captcha"
           CONFIG[registration.recaptcha_public_key]=$(prompt_value "reCAPTCHA public key")
           CONFIG[registration.recaptcha_private_key]=$(prompt_value "reCAPTCHA private key") ;;
    esac
}

# --- Step 6: Admin Account ---
wizard_step_admin() {
    log_step "Admin Account"

    CONFIG[admin.username]=$(prompt_value "Admin username" "admin")

    local pass1 pass2
    pass1=$(prompt_password "Admin password (min 8 chars)")
    pass2=$(prompt_password "Confirm password")

    if [[ "$pass1" != "$pass2" ]]; then
        log_error "Passwords do not match"
        exit "$E_CONFIG"
    fi

    if [[ ${#pass1} -lt 8 ]]; then
        log_error "Password must be at least 8 characters"
        exit "$E_CONFIG"
    fi

    CONFIG[admin.password]="$pass1"
}

# --- Step 7: Database ---
wizard_step_database() {
    log_step "Database"
    # Handled by postgres_setup auto-detection
    CONFIG[database.mode]="auto"
    log_substep "Will auto-detect PostgreSQL (containerize if not found)"
}

# --- Step 8: Web Client ---
wizard_step_webclient() {
    log_step "Web Client"

    local choice
    choice=$(prompt_select "Choose a web client" \
        "Element Web (recommended)" \
        "Cinny (modern, minimal)" \
        "SchildiChat Web (Element fork)" \
        "None (skip)")

    case "$choice" in
        0) CONFIG[webclient.type]="element" ;;
        1) CONFIG[webclient.type]="cinny" ;;
        2) CONFIG[webclient.type]="schildichat" ;;
        3) CONFIG[webclient.type]="none" ;;
    esac

    if [[ "${CONFIG[webclient.type]}" != "none" ]]; then
        CONFIG[webclient.subdomain]=$(prompt_value "Web client subdomain" "chat")
    fi
}

# --- Step 9: Bridges ---
wizard_step_bridges() {
    log_step "Chat Bridges"

    if [[ "${CONFIG[homeserver.type]}" != "synapse" ]]; then
        log_substep "Bridges require Synapse — skipping"
        return 0
    fi

    local selected
    selected=$(prompt_multiselect "Select bridges to install" \
        "Telegram" "Discord" "WhatsApp" "Signal" "Slack" "IRC")

    if [[ -z "$selected" ]]; then
        log_substep "No bridges selected"
        return 0
    fi

    local bridge_names=("telegram" "discord" "whatsapp" "signal" "slack" "irc")
    local enabled=()

    for idx in $selected; do
        enabled+=("${bridge_names[$idx]}")
    done

    CONFIG[bridges.enabled]=$(IFS=','; echo "${enabled[*]}")
    log_substep "Selected: ${CONFIG[bridges.enabled]}"

    # Prompt for bridge-specific credentials
    for bridge in "${enabled[@]}"; do
        local plugin="${SCRIPT_DIR}/bridges/${bridge}.sh"
        if [[ -f "$plugin" ]]; then
            # shellcheck source=/dev/null
            source "$plugin"
            if declare -f bridge_prompt_credentials &>/dev/null; then
                bridge_prompt_credentials
            fi
        fi
    done
}

# --- Step 10: SMTP ---
wizard_step_smtp() {
    log_step "Email (SMTP)"

    # Already enabled if open-email registration was chosen
    if [[ "${CONFIG[smtp.enabled]:-false}" == "true" ]]; then
        log_substep "SMTP required for email verification"
    else
        if ! confirm_prompt "Configure SMTP for email notifications?" "n"; then
            CONFIG[smtp.enabled]="false"
            return 0
        fi
        CONFIG[smtp.enabled]="true"
    fi

    CONFIG[smtp.host]=$(prompt_value "SMTP host")
    CONFIG[smtp.port]=$(prompt_value "SMTP port" "587")
    CONFIG[smtp.user]=$(prompt_value "SMTP username")
    CONFIG[smtp.password]=$(prompt_password "SMTP password")
    CONFIG[smtp.from]=$(prompt_value "From address" "noreply@${CONFIG[domain.name]}")
}

# --- Step 11: Admin UI ---
wizard_step_admin_ui() {
    log_step "Admin Panel"

    if [[ "${CONFIG[homeserver.type]}" != "synapse" ]]; then
        log_substep "Admin UI only available with Synapse — skipping"
        CONFIG[admin_ui.enabled]="false"
        return 0
    fi

    if confirm_prompt "Enable Synapse Admin web panel?" "y"; then
        CONFIG[admin_ui.enabled]="true"
        CONFIG[admin_ui.subdomain]=$(prompt_value "Admin UI subdomain" "admin")
    else
        CONFIG[admin_ui.enabled]="false"
    fi
}

# --- Step 12: Monitoring ---
wizard_step_monitoring() {
    log_step "Monitoring"

    if confirm_prompt "Enable Prometheus + Grafana monitoring?" "n"; then
        CONFIG[monitoring.enabled]="true"
        CONFIG[monitoring.grafana_subdomain]=$(prompt_value "Grafana subdomain" "grafana")
    else
        CONFIG[monitoring.enabled]="false"
    fi
}

# --- Step 13: Backup ---
wizard_step_backup() {
    log_step "Backup Configuration"

    log_substep "Backups will run daily at 03:00"

    CONFIG[backup.retention_daily]=$(prompt_value "Daily backups to keep" "$DEFAULT_BACKUP_DAILY")
    CONFIG[backup.retention_weekly]=$(prompt_value "Weekly backups to keep" "$DEFAULT_BACKUP_WEEKLY")

    local enc_choice
    enc_choice=$(prompt_select "Backup encryption" \
        "None" \
        "GPG (requires GPG key)" \
        "age (requires age public key)")

    case "$enc_choice" in
        0) CONFIG[backup.encryption]="none" ;;
        1) CONFIG[backup.encryption]="gpg"
           CONFIG[backup.encryption_key]=$(prompt_value "GPG recipient (key ID or email)") ;;
        2) CONFIG[backup.encryption]="age"
           CONFIG[backup.encryption_key]=$(prompt_value "age public key") ;;
    esac
}

# --- Step 14: Hardening ---
wizard_step_hardening() {
    log_step "Server Hardening"

    log_substep "All hardening options are enabled by default."

    if ! confirm_prompt "Customize hardening options?" "n"; then
        return 0
    fi

    confirm_prompt "  Harden SSH (key-only, no root)?" "y" && CONFIG[hardening.ssh]="true" || CONFIG[hardening.ssh]="false"
    confirm_prompt "  Configure firewall?" "y" && CONFIG[hardening.firewall]="true" || CONFIG[hardening.firewall]="false"
    confirm_prompt "  Install fail2ban?" "y" && CONFIG[hardening.fail2ban]="true" || CONFIG[hardening.fail2ban]="false"
    confirm_prompt "  Apply sysctl tuning?" "y" && CONFIG[hardening.sysctl]="true" || CONFIG[hardening.sysctl]="false"
    confirm_prompt "  Enable auto-updates?" "y" && CONFIG[hardening.auto_updates]="true" || CONFIG[hardening.auto_updates]="false"
}

# --- Step 15: Existing Proxy ---
wizard_step_proxy() {
    log_step "Reverse Proxy"

    # Auto-detect existing proxy
    if declare -f proxy_detect &>/dev/null; then
        proxy_detect
    fi

    if [[ "${CONFIG[proxy.detected]:-}" != "" ]]; then
        log_substep "Detected existing proxy: ${CONFIG[proxy.detected]}"
        if confirm_prompt "Use existing proxy instead of Caddy?" "n"; then
            CONFIG[proxy.external]="true"
            log_substep "Caddy will be skipped. Config snippets will be generated."
            return 0
        fi
    fi

    CONFIG[proxy.external]="false"
    log_substep "Caddy will handle HTTPS and reverse proxying"
}

# --- Step 16: Secrets Mode ---
wizard_step_secrets() {
    log_step "Secrets Storage"

    local choice
    choice=$(prompt_select "How should secrets be stored?" \
        ".env file (chmod 600, standard)" \
        "Podman native secrets (more secure)")

    case "$choice" in
        0) CONFIG[secrets.mode]="env" ;;
        1) CONFIG[secrets.mode]="podman" ;;
    esac
}

# --- Step 17: Confirmation ---
wizard_step_confirmation() {
    log_step "Confirmation"

    echo ""
    printf '%s%s  Setup Summary%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    echo "  ────────────────────────────────────────────"
    printf '  Domain:         %s%s%s\n' "$C_BOLD" "${CONFIG[domain.name]}" "$C_RESET"
    printf '  Homeserver:     %s\n' "${CONFIG[homeserver.type]}"
    printf '  Federation:     %s\n' "${CONFIG[federation.enabled]}"
    printf '  Registration:   %s\n' "${CONFIG[registration.policy]}"
    printf '  Admin user:     @%s:%s\n' "${CONFIG[admin.username]}" "${CONFIG[domain.name]}"
    printf '  Web client:     %s\n' "${CONFIG[webclient.type]:-none}"
    printf '  Bridges:        %s\n' "${CONFIG[bridges.enabled]:-none}"
    printf '  Admin UI:       %s\n' "${CONFIG[admin_ui.enabled]}"
    printf '  Monitoring:     %s\n' "${CONFIG[monitoring.enabled]}"
    printf '  SMTP:           %s\n' "${CONFIG[smtp.enabled]}"
    printf '  Coturn:         %s\n' "${CONFIG[coturn.enabled]:-true}"
    printf '  Secrets mode:   %s\n' "${CONFIG[secrets.mode]}"
    echo "  ────────────────────────────────────────────"
    echo ""

    if ! confirm_prompt "Proceed with setup?" "y"; then
        log_info "Setup cancelled."
        exit "$E_USER_ABORT"
    fi
}
