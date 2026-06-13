#!/usr/bin/env bash
# Matrix Stack Setup - Constants
# All shared constants, exit codes, image tags, and thresholds.
# shellcheck disable=SC2034
set -euo pipefail

readonly MATRIX_SETUP_VERSION="0.1.1"
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

# --- Pinned container images (tag + immutable @sha256 digest) ---
# Every image is pinned to "tag@sha256:digest". The digest is the immutable
# source of truth; the tag is kept for human readability. Regenerate after any
# version bump with: scripts/pin-digests.sh  (verify in CI: --check).
# See docs/SUPPLY_CHAIN.md for SBOM/signing/provenance.
readonly SYNAPSE_IMAGE="docker.io/matrixdotorg/synapse:v1.127.1@sha256:c3c4a9de2a0b7de37d9af8101f6196748d76cd6355e6e282d7b550dd0a833519"
readonly DENDRITE_IMAGE="ghcr.io/element-hq/dendrite-monolith:v0.14.1@sha256:a0212bbbfdee8f38a1b6680eedffa3ad4d9f3cfb86c9d1f0250c8ea122d54ea2"
readonly POSTGRES_IMAGE="docker.io/postgres:16.14-alpine@sha256:16bc17c64a573ef34162af9298258d1aec548232985b33ed7b1eac33ba35c229"
readonly CADDY_IMAGE="docker.io/library/caddy:2.11.4-alpine@sha256:77c07d5ebfa5be9fd6c820d2094ae662c9e7eeb9bf98346b7f639900263ee2a2"
readonly COTURN_IMAGE="docker.io/coturn/coturn:4.9.0-alpine@sha256:229f87ef2428336ca2f4b4967a961cc6ad7aceb79277bc51f5a179606228d45f"
readonly ELEMENT_IMAGE="docker.io/vectorim/element-web:v1.11.96@sha256:13d0ea68d7ffd7d4800b4a243cade0ec535b4ed3d8d00478ae95950b14fa634c"
readonly CINNY_IMAGE="ghcr.io/cinnyapp/cinny:v4.12.2@sha256:985daecc69998b329f013efcf00f30087708a4ee1f18f053821b07bda04f526a"
readonly SCHILDICHAT_IMAGE="ghcr.io/etkecc/schildichat-web:1.11.36-sc.3@sha256:859e14d18d77cac83492c3ca2147ab9ac617c5b355928963f34afbc4ccc9f528"
readonly SYNAPSE_ADMIN_IMAGE="ghcr.io/etkecc/synapse-admin:v0.11.4-etke54@sha256:668552a2b59df4dc99f9d7a798372b67733173158e50b3784611d1dbd0d5a905"
readonly PROMETHEUS_IMAGE="docker.io/prom/prometheus:v3.2.1@sha256:6927e0919a144aa7616fd0137d4816816d42f6b816de3af269ab065250859a62"
readonly GRAFANA_IMAGE="docker.io/grafana/grafana:11.5.2@sha256:8b37a2f028f164ce7b9889e1765b9d6ee23fec80f871d156fbf436d6198d32b7"

# Bridge images
readonly BRIDGE_TELEGRAM_IMAGE="dock.mau.dev/mautrix/telegram:v0.15.2@sha256:ac6dc40851cdf32a7bd9ce485a184c76796491a81d2fa01fe34702958efdc3df"
readonly BRIDGE_DISCORD_IMAGE="dock.mau.dev/mautrix/discord:v0.7.2@sha256:6d44d267ed0d19637a665aad3fe06cec87ba464490f2f18fca368e8b7a2ae303"
readonly BRIDGE_WHATSAPP_IMAGE="dock.mau.dev/mautrix/whatsapp:v0.11.3@sha256:ef4b91c10e13fec5154ebbfc40f5fde556e1015510f04d96316c4bb7ade85921"
readonly BRIDGE_SIGNAL_IMAGE="dock.mau.dev/mautrix/signal:v0.7.4@sha256:0185c6e4168237671338a7a808ecf8c213579d0bb33e6662f2d9cf42dc9ea06c"
readonly BRIDGE_SLACK_IMAGE="dock.mau.dev/mautrix/slack:v0.1.3@sha256:5afa699618e21eb02a1c1756cea69c0908c21b61007111384543bb0e40be4e43"
readonly BRIDGE_IRC_IMAGE="docker.io/hif1/heisenbridge:1.9.0@sha256:eed68de5eea04d23898cba75a70cfd4d43378342b56c03b2a4face479c256b26"

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
