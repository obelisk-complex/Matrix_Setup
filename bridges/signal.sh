#!/usr/bin/env bash
# Bridge Plugin: Signal (mautrix-signal)
set -euo pipefail

bridge_name()        { echo "Signal"; }
bridge_description() { echo "Bridge Signal chats to Matrix via mautrix-signal"; }
bridge_image()       { echo "$BRIDGE_SIGNAL_IMAGE"; }
bridge_requires_synapse() { echo "true"; }

bridge_prompt_credentials() {
    log_substep "Signal bridge uses device linking — no credentials needed at setup time"
}

bridge_validate_credentials() {
    return 0
}

bridge_generate_registration() {
    local output="$1" as_token="$2" hs_token="$3" domain="$4"

    cat > "$output" << YAML
id: signal
url: "http://bridge-signal:29328"
as_token: "${as_token}"
hs_token: "${hs_token}"
sender_localpart: "signalbot"
rate_limited: false
namespaces:
  users:
    - exclusive: true
      regex: "@signal_.*:${domain}"
  aliases:
    - exclusive: true
      regex: "#signal_.*:${domain}"
YAML
}

bridge_compose_fragment() {
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local vol_label="${VOLUME_LABEL:-}"

    cat << YAML
  bridge-signal:
    image: ${BRIDGE_SIGNAL_IMAGE}
    container_name: matrix-bridge-signal
    restart: unless-stopped
    networks:
      - matrix-net
    depends_on:
      homeserver:
        condition: service_healthy
    volumes:
      - ${install_dir}/config/bridges/signal:/data${vol_label}
YAML
}
