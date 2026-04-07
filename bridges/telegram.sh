#!/usr/bin/env bash
# Bridge Plugin: Telegram (mautrix-telegram)
# shellcheck disable=SC2154
set -euo pipefail

bridge_name()        { echo "Telegram"; }
bridge_description() { echo "Bridge Telegram groups and DMs to Matrix via mautrix-telegram"; }
bridge_image()       { echo "$BRIDGE_TELEGRAM_IMAGE"; }
bridge_requires_synapse() { echo "true"; }

bridge_prompt_credentials() {
    log_substep "Telegram bridge requires a Bot API token from @BotFather"
    CONFIG[bridges.telegram.api_id]=$(prompt_value "Telegram API ID (from https://my.telegram.org)")
    CONFIG[bridges.telegram.api_hash]=$(prompt_value "Telegram API Hash")
    CONFIG[bridges.telegram.bot_token]=$(prompt_value "Telegram Bot Token (from @BotFather)" "disabled")
}

bridge_validate_credentials() {
    [[ -n "${CONFIG[bridges.telegram.api_id]:-}" && \
       -n "${CONFIG[bridges.telegram.api_hash]:-}" ]]
}

bridge_generate_registration() {
    local output="$1" as_token="$2" hs_token="$3" domain="$4"

    cat > "$output" << YAML
id: telegram
url: "http://bridge-telegram:29317"
as_token: "${as_token}"
hs_token: "${hs_token}"
sender_localpart: "telegrambot"
rate_limited: false
namespaces:
  users:
    - exclusive: true
      regex: "@telegram_.*:${domain}"
  aliases:
    - exclusive: true
      regex: "#telegram_.*:${domain}"
YAML
}

bridge_compose_fragment() {
    local install_dir="${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}"
    local vol_label="${VOLUME_LABEL:-}"

    cat << YAML
  bridge-telegram:
    image: ${BRIDGE_TELEGRAM_IMAGE}
    container_name: matrix-bridge-telegram
    restart: unless-stopped
    networks:
      - matrix-net
    depends_on:
      homeserver:
        condition: service_healthy
    volumes:
      - ${install_dir}/config/bridges/telegram:/data${vol_label}
YAML
}
