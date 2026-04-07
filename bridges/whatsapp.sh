#!/usr/bin/env bash
# Bridge Plugin: WhatsApp (mautrix-whatsapp)
set -euo pipefail

bridge_name()        { echo "WhatsApp"; }
bridge_description() { echo "Bridge WhatsApp chats to Matrix via mautrix-whatsapp"; }
bridge_image()       { echo "$BRIDGE_WHATSAPP_IMAGE"; }
bridge_requires_synapse() { echo "true"; }

bridge_prompt_credentials() {
    log_substep "WhatsApp bridge uses QR code pairing — no credentials needed at setup time"
}

bridge_validate_credentials() {
    return 0
}

bridge_generate_registration() {
    local output="$1" as_token="$2" hs_token="$3" domain="$4"

    cat > "$output" << YAML
id: whatsapp
url: "http://bridge-whatsapp:29318"
as_token: "${as_token}"
hs_token: "${hs_token}"
sender_localpart: "whatsappbot"
rate_limited: false
namespaces:
  users:
    - exclusive: true
      regex: "@whatsapp_.*:${domain}"
  aliases:
    - exclusive: true
      regex: "#whatsapp_.*:${domain}"
YAML
}

bridge_compose_fragment() {
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local vol_label="${VOLUME_LABEL:-}"

    cat << YAML
  bridge-whatsapp:
    image: ${BRIDGE_WHATSAPP_IMAGE}
    container_name: matrix-bridge-whatsapp
    restart: unless-stopped
    networks:
      - matrix-net
    depends_on:
      homeserver:
        condition: service_healthy
    volumes:
      - ${install_dir}/config/bridges/whatsapp:/data${vol_label}
YAML
}
