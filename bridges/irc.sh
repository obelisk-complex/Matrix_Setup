#!/usr/bin/env bash
# Bridge Plugin: IRC (Heisenbridge)
# shellcheck disable=SC2154
set -euo pipefail

bridge_name()        { echo "IRC"; }
bridge_description() { echo "Bridge IRC networks to Matrix via Heisenbridge"; }
bridge_image()       { echo "$BRIDGE_IRC_IMAGE"; }
bridge_requires_synapse() { echo "true"; }

bridge_prompt_credentials() {
    CONFIG[bridges.irc.owner]=$(prompt_value "IRC bridge owner Matrix ID" "@admin:${CONFIG[domain.name]}")
}

bridge_validate_credentials() {
    [[ -n "${CONFIG[bridges.irc.owner]:-}" ]]
}

bridge_generate_registration() {
    local output="$1" as_token="$2" hs_token="$3" domain="$4"

    cat > "$output" << YAML
id: heisenbridge
url: "http://bridge-irc:9898"
as_token: "${as_token}"
hs_token: "${hs_token}"
sender_localpart: "heisenbridge"
rate_limited: false
namespaces:
  users:
    - exclusive: true
      regex: "@irc_.*:${domain}"
  aliases:
    - exclusive: true
      regex: "#irc_.*:${domain}"
YAML
}

bridge_compose_fragment() {
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local vol_label="${VOLUME_LABEL:-}"
    local owner="${CONFIG[bridges.irc.owner]:-@admin:${CONFIG[domain.name]}}"
    local hs_url
    if [[ "${COMPOSE_NETWORKING:-dns}" == "pod" ]]; then
        hs_url="http://localhost:8008"
    else
        hs_url="http://homeserver:8008"
    fi

    cat << YAML
  bridge-irc:
    image: ${BRIDGE_IRC_IMAGE}
    container_name: matrix-bridge-irc
    restart: unless-stopped
    networks:
      - matrix-net
    depends_on:
      homeserver:
        condition: service_healthy
    command: ["-c", "/data/registration.yaml", "--owner", "${owner}", "${hs_url}"]
    volumes:
      - ${install_dir}/config/bridges/irc:/data${vol_label}
YAML
}
