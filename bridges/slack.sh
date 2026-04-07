#!/usr/bin/env bash
# Bridge Plugin: Slack (mautrix-slack)
set -euo pipefail

bridge_name()        { echo "Slack"; }
bridge_description() { echo "Bridge Slack workspaces to Matrix via mautrix-slack"; }
bridge_image()       { echo "$BRIDGE_SLACK_IMAGE"; }
bridge_requires_synapse() { echo "true"; }

bridge_prompt_credentials() {
    log_substep "Slack bridge uses user token login — configured after deployment"
}

bridge_validate_credentials() {
    return 0
}

bridge_generate_registration() {
    local output="$1" as_token="$2" hs_token="$3" domain="$4"

    cat > "$output" << YAML
id: slack
url: "http://bridge-slack:29335"
as_token: "${as_token}"
hs_token: "${hs_token}"
sender_localpart: "slackbot"
rate_limited: false
namespaces:
  users:
    - exclusive: true
      regex: "@slack_.*:${domain}"
  aliases:
    - exclusive: true
      regex: "#slack_.*:${domain}"
YAML
}

bridge_compose_fragment() {
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local vol_label="${VOLUME_LABEL:-}"

    cat << YAML
  bridge-slack:
    image: ${BRIDGE_SLACK_IMAGE}
    container_name: matrix-bridge-slack
    restart: unless-stopped
    networks:
      - matrix-net
    depends_on:
      homeserver:
        condition: service_healthy
    volumes:
      - ${install_dir}/config/bridges/slack:/data${vol_label}
YAML
}
