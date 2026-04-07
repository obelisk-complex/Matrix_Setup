#!/usr/bin/env bash
# Matrix Stack Setup - Web Client (Element / Cinny / SchildiChat)
set -euo pipefail

webclient_setup() {
    log_step "Configuring web client"

    local wc_type="${CONFIG[webclient.type]:-element}"

    if [[ "$wc_type" == "none" ]]; then
        log_substep "Web client disabled, skipping"
        return 0
    fi

    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local config_dir="$install_dir/config"
    local domain="${CONFIG[domain.name]}"
    local subdomain="${CONFIG[webclient.subdomain]:-chat}"

    mkdir -p "$config_dir"

    case "$wc_type" in
        element)
            CONFIG[webclient.image]="$ELEMENT_IMAGE"
            _webclient_element_config "$config_dir" "$domain"
            ;;
        cinny)
            CONFIG[webclient.image]="$CINNY_IMAGE"
            _webclient_cinny_config "$config_dir" "$domain"
            ;;
        schildichat)
            CONFIG[webclient.image]="$SCHILDICHAT_IMAGE"
            _webclient_element_config "$config_dir" "$domain"
            ;;
    esac

    log_success "Web client ($wc_type) configured at ${subdomain}.${domain}"
}

_webclient_element_config() {
    local config_dir="$1"
    local domain="$2"

    cat > "$config_dir/element-config.json" << ELEMJSON
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://${domain}",
            "server_name": "${domain}"
        },
        "m.identity_server": {
            "base_url": "https://vector.im"
        }
    },
    "disable_custom_urls": false,
    "disable_guests": true,
    "disable_login_language_selector": false,
    "disable_3pid_login": false,
    "brand": "Element",
    "integrations_ui_url": "https://scalar.vector.im/",
    "integrations_rest_url": "https://scalar.vector.im/api",
    "integrations_widgets_urls": [
        "https://scalar.vector.im/_matrix/integrations/v1",
        "https://scalar.vector.im/api",
        "https://scalar-staging.vector.im/_matrix/integrations/v1",
        "https://scalar-staging.vector.im/api"
    ],
    "default_country_code": "US",
    "show_labs_settings": false,
    "features": {},
    "default_federate": true,
    "default_theme": "light",
    "room_directory": {
        "servers": ["${domain}", "matrix.org"]
    },
    "setting_defaults": {
        "breadcrumbs": true
    }
}
ELEMJSON

    rollback_snapshot "webclient" "FILE_CREATED" "$config_dir/element-config.json"
    log_substep "Element Web config written"
}

_webclient_cinny_config() {
    local config_dir="$1"
    local domain="$2"

    cat > "$config_dir/cinny-config.json" << CINNYJSON
{
    "defaultHomeserver": 0,
    "homeserverList": [
        "${domain}"
    ],
    "allowCustomHomeservers": true
}
CINNYJSON

    rollback_snapshot "webclient" "FILE_CREATED" "$config_dir/cinny-config.json"
    log_substep "Cinny config written"
}
