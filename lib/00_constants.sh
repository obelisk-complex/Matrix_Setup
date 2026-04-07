#!/usr/bin/env bash
# Matrix Stack Setup - Constants
# All shared constants, exit codes, image tags, and thresholds.
# shellcheck disable=SC2034
set -euo pipefail

readonly MATRIX_SETUP_VERSION="0.0.1"
readonly MATRIX_SETUP_STATE_FILE=".matrix-setup.state"
readonly MATRIX_SETUP_MANIFEST_FILE=".rollback-manifest"

# --- Exit codes ---
readonly E_OK=0
readonly E_PREREQ=1
readonly E_CONFIG=2
readonly E_NETWORK=3
readonly E_DEPLOY=4
readonly E_ROLLBACK=5
readonly E_HARDENING=6
readonly E_USER_ABORT=130

# --- Podman version constraints ---
readonly MIN_PODMAN_VERSION="4.4.0"
readonly REC_PODMAN_VERSION="5.0.0"
readonly MIN_PG_VERSION="13"

# --- Pinned container image tags (never use :latest) ---
readonly SYNAPSE_IMAGE="docker.io/matrixdotorg/synapse:v1.127.1"
readonly DENDRITE_IMAGE="ghcr.io/matrix-org/dendrite-monolith:v0.14.1"
readonly POSTGRES_IMAGE="docker.io/postgres:16-alpine"
readonly CADDY_IMAGE="docker.io/library/caddy:2.9-alpine"
readonly COTURN_IMAGE="docker.io/coturn/coturn:4.9.0-alpine"
readonly ELEMENT_IMAGE="docker.io/vectorim/element-web:v1.11.96"
readonly CINNY_IMAGE="ghcr.io/cinnyapp/cinny:v4.3.1"
readonly SCHILDICHAT_IMAGE="ghcr.io/nicoding-group/schildichat-web:v1.11.81-sc.1"
readonly SYNAPSE_ADMIN_IMAGE="ghcr.io/etkecc/synapse-admin:latest-etke"
readonly PROMETHEUS_IMAGE="docker.io/prom/prometheus:v3.2.1"
readonly GRAFANA_IMAGE="docker.io/grafana/grafana:11.5.2"

# Bridge images
readonly BRIDGE_TELEGRAM_IMAGE="dock.mau.dev/mautrix/telegram:v0.15.2"
readonly BRIDGE_DISCORD_IMAGE="dock.mau.dev/mautrix/discord:v0.7.2"
readonly BRIDGE_WHATSAPP_IMAGE="dock.mau.dev/mautrix/whatsapp:v0.11.3"
readonly BRIDGE_SIGNAL_IMAGE="dock.mau.dev/mautrix/signal:v0.7.4"
readonly BRIDGE_SLACK_IMAGE="dock.mau.dev/mautrix/slack:v0.1.3"
readonly BRIDGE_IRC_IMAGE="docker.io/halfshot/heisenbridge:1.15.0"

# --- System thresholds ---
readonly MIN_RAM_MB=512
readonly WARN_RAM_MB=2048
readonly MIN_DISK_GB=1
readonly WARN_DISK_GB=5

# --- Default paths ---
readonly DEFAULT_INSTALL_DIR="/opt/matrix"
readonly DEFAULT_DATA_DIR="/opt/matrix/data"
readonly DEFAULT_BACKUP_DIR="/opt/matrix/backups"
readonly DEFAULT_MATRIX_USER="matrix"

# --- Default retention ---
readonly DEFAULT_MEDIA_RETENTION_DAYS=90
readonly DEFAULT_BACKUP_DAILY=7
readonly DEFAULT_BACKUP_WEEKLY=4

# --- Default ports ---
readonly PORT_HTTP=80
readonly PORT_HTTPS=443
readonly PORT_FEDERATION=8448
readonly PORT_SYNAPSE=8008
readonly PORT_DENDRITE=8008
readonly PORT_STUN=3478
readonly PORT_STUN_TLS=5349
readonly PORT_COTURN_MIN=49152
readonly PORT_COTURN_MAX=65535
readonly PORT_PROMETHEUS=9090
readonly PORT_GRAFANA=3000

# --- Colors (respect NO_COLOR env var, see https://no-color.org/) ---
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    readonly C_RED=$'\033[0;31m'
    readonly C_GREEN=$'\033[0;32m'
    readonly C_YELLOW=$'\033[0;33m'
    readonly C_BLUE=$'\033[0;34m'
    readonly C_MAGENTA=$'\033[0;35m'
    readonly C_CYAN=$'\033[0;36m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[2m'
    readonly C_RESET=$'\033[0m'
else
    readonly C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
    readonly C_MAGENTA='' C_CYAN='' C_BOLD='' C_DIM='' C_RESET=''
fi
