#!/usr/bin/env bash
# Matrix Stack Setup - Synapse Admin UI
set -euo pipefail

admin_ui_setup() {
    log_step "Configuring Synapse Admin UI"

    local hs_type="${CONFIG[homeserver.type]:-synapse}"

    if [[ "$hs_type" != "synapse" ]]; then
        log_substep "Admin UI only available with Synapse, skipping"
        return 0
    fi

    if [[ "${CONFIG[admin_ui.enabled]:-false}" != "true" ]]; then
        log_substep "Admin UI disabled, skipping"
        return 0
    fi

    CONFIG[admin_ui.image]="$SYNAPSE_ADMIN_IMAGE"

    local domain="${CONFIG[domain.name]}"
    local subdomain="${CONFIG[admin_ui.subdomain]:-admin}"

    log_substep "Synapse Admin will be available at https://${subdomain}.${domain}"
    log_success "Admin UI configured"
}
