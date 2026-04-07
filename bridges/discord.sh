#!/usr/bin/env bash
# Bridge Plugin: Discord (mautrix-discord)
set -euo pipefail

bridge_name()        { echo "Discord"; }
bridge_description() { echo "Bridge Discord servers and DMs to Matrix via mautrix-discord"; }
bridge_image()       { echo "$BRIDGE_DISCORD_IMAGE"; }
bridge_requires_synapse() { echo "true"; }

bridge_prompt_credentials() {
    log_substep "Discord bridge uses user login — no bot token needed for basic bridging"
}

bridge_validate_credentials() {
    return 0
}

bridge_generate_registration() {
    local output="$1" as_token="$2" hs_token="$3" domain="$4"

    cat > "$output" << YAML
id: discord
url: "http://bridge-discord:29334"
as_token: "${as_token}"
hs_token: "${hs_token}"
sender_localpart: "discordbot"
rate_limited: false
namespaces:
  users:
    - exclusive: true
      regex: "@discord_.*:${domain}"
  aliases:
    - exclusive: true
      regex: "#discord_.*:${domain}"
YAML
}

bridge_compose_fragment() {
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local vol_label="${VOLUME_LABEL:-}"

    cat << YAML
  bridge-discord:
    image: ${BRIDGE_DISCORD_IMAGE}
    container_name: matrix-bridge-discord
    restart: unless-stopped
    networks:
      - matrix-net
    depends_on:
      homeserver:
        condition: service_healthy
    volumes:
      - ${install_dir}/config/bridges/discord:/data${vol_label}
YAML
}
