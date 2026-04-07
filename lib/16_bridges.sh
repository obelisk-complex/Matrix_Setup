#!/usr/bin/env bash
# Matrix Stack Setup - Bridge Plugin Loader
# Discovers bridge plugins in bridges/, validates interface, generates registrations.
# shellcheck disable=SC2034
set -euo pipefail

# Loaded bridge metadata
declare -gA BRIDGE_NAMES=()
declare -gA BRIDGE_IMAGES=()
declare -ga BRIDGES_ENABLED=()

bridges_setup() {
    log_step "Configuring bridges"

    local hs_type="${CONFIG[homeserver.type]:-synapse}"

    if [[ "$hs_type" != "synapse" ]]; then
        log_substep "Bridges require Synapse, skipping"
        return 0
    fi

    local enabled="${CONFIG[bridges.enabled]:-}"
    if [[ -z "$enabled" ]]; then
        log_substep "No bridges selected, skipping"
        return 0
    fi

    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local config_dir="$install_dir/config"
    local appservice_dir="$config_dir/appservices"
    mkdir -p "$appservice_dir"

    # Discover available plugins
    _bridges_discover

    # Process each enabled bridge
    IFS=',' read -ra bridge_list <<< "$enabled"
    for bridge_name in "${bridge_list[@]}"; do
        bridge_name="${bridge_name// /}" # trim whitespace
        _bridge_setup_single "$bridge_name" "$appservice_dir"
    done

    CONFIG[bridges.has_appservices]="true"
    log_success "Bridges configured (${#bridge_list[@]} enabled)"
}

_bridges_discover() {
    local bridge_dir="${SCRIPT_DIR}/bridges"

    if [[ ! -d "$bridge_dir" ]]; then
        log_warn "No bridges directory found"
        return 0
    fi

    local plugin
    for plugin in "$bridge_dir"/*.sh; do
        [[ -f "$plugin" ]] || continue
        local basename
        basename=$(basename "$plugin" .sh)

        # Skip template
        [[ "$basename" == _* ]] && continue

        # Source the plugin in a subshell to get metadata
        local plugin_output
        plugin_output=$(
            # shellcheck source=/dev/null
            source "$plugin"

            # Validate plugin interface
            if ! declare -f bridge_name &>/dev/null || \
               ! declare -f bridge_image &>/dev/null; then
                exit 0
            fi

            echo "$(bridge_name):$(bridge_image)"
        ) || true

        if [[ -n "$plugin_output" ]]; then
            local name image
            IFS=: read -r name image <<< "$plugin_output"
            BRIDGE_NAMES["$basename"]="$name"
            BRIDGE_IMAGES["$basename"]="$image"
        fi
    done
}

_bridge_setup_single() {
    local bridge_name="$1"
    local appservice_dir="$2"
    local bridge_dir="${SCRIPT_DIR}/bridges"
    local plugin="$bridge_dir/${bridge_name}.sh"

    if [[ ! -f "$plugin" ]]; then
        log_warn "Bridge plugin not found: $bridge_name"
        return 0
    fi

    log_substep "Setting up bridge: $bridge_name"

    # Generate bridge tokens
    secrets_generate_bridge_tokens "$bridge_name"

    # Source plugin and call its functions
    # shellcheck source=/dev/null
    source "$plugin"

    local as_token="${CONFIG[secrets.${bridge_name}_as_token]}"
    local hs_token="${CONFIG[secrets.${bridge_name}_hs_token]}"
    local domain="${CONFIG[domain.name]}"

    # Generate registration YAML
    if declare -f bridge_generate_registration &>/dev/null; then
        bridge_generate_registration \
            "$appservice_dir/${bridge_name}-registration.yaml" \
            "$as_token" "$hs_token" "$domain"

        chmod 640 "$appservice_dir/${bridge_name}-registration.yaml"
        rollback_snapshot "bridges" "FILE_CREATED" "$appservice_dir/${bridge_name}-registration.yaml"

        # Register with homeserver
        homeserver_add_appservice "/data/appservices/${bridge_name}-registration.yaml"
    fi

    # Store image for compose assembly
    if declare -f bridge_image &>/dev/null; then
        CONFIG["bridges.${bridge_name}.image"]=$(bridge_image)
    fi

    BRIDGES_ENABLED+=("$bridge_name")
    log_substep "Bridge $bridge_name configured"
}
