# Matrix Setup

**Current release: v0.1.0** · see [CHANGELOG.md](CHANGELOG.md)

A modular Bash script that deploys a complete [Matrix](https://matrix.org) communication stack on any Linux server using Podman Compose.

One command gets you a fully configured, hardened Matrix homeserver with TLS, TURN/STUN, backups, and optional bridges to Telegram, Discord, WhatsApp, Signal, Slack, and IRC.

## Why This Exists

Running your own Matrix server normally means hand-wiring a homeserver, a database, a reverse proxy, TURN/STUN, TLS certificates, federation, backups and server hardening, then keeping all of it patched. That is a lot of moving parts and a lot of documentation to wade through before you send your first message.

The goal of this project is to collapse all of that into a single command, with safe, hardened defaults, so that **anyone with a Linux box and a domain name can run their own Matrix server** without being a Matrix expert. You own the server, you own your conversations, and you are not renting your communications from anyone.

It is built to be approachable without being fragile:

- **Sensible, safe defaults.** Invite-only registration, a locked-down firewall, key-only SSH, optional encrypted backups and pinned, digest-verified container images, all on by default.
- **Reversible.** Every change is recorded in a rollback manifest, so a failed or unwanted run can be undone, and your data volumes are never auto-deleted.
- **Reproducible.** A single TOML file can describe the whole deployment for headless, repeatable installs.
- **Yours to extend.** Bridges are drop-in plugins, and the reverse proxy, web client and homeserver are all your choice.

If you can copy and paste one command, you can host Matrix for yourself, your family, or your community.

## What You Get

- **Homeserver**: Synapse or Dendrite (your choice)
- **Reverse proxy**: Caddy with automatic Let's Encrypt TLS, security headers, `.well-known` delegation
- **TURN/STUN**: Coturn for voice/video calls, hardened against relay abuse (CVE-2026-27624 mitigations)
- **Database**: PostgreSQL 16 (containerized or existing host instance)
- **Web client**: Element Web, Cinny, or SchildiChat
- **Admin UI**: Synapse Admin panel
- **Bridges**: Telegram, Discord, WhatsApp, Signal, Slack, IRC (Synapse only)
- **Monitoring**: Prometheus + Grafana with pre-built dashboards
- **Backups**: Automated daily backups with signing key handling, retention policy, optional encryption
- **Hardening**: SSH lockdown, firewall, fail2ban, sysctl tuning, SELinux/AppArmor, automatic security updates
- **Systemd integration**: Quadlet units with auto-start on reboot

Everything runs rootless under a dedicated `matrix` system user (except Coturn, which requires host networking).

## Requirements

- Linux server (Ubuntu 22.04+, Debian 12+, Fedora 39+, CentOS Stream 9+, Arch, openSUSE)
- Root access
- 512 MB RAM minimum (2 GB+ recommended for Synapse)
- 1 GB free disk (5 GB+ recommended)
- A domain name with DNS A record pointing to the server
- Ports 80 and 443 available (or an existing reverse proxy)

Podman 4.4.0+ is required and will be installed automatically if missing.

## Quick Start

```bash
git clone https://github.com/obelisk-complex/Matrix_Setup.git
cd Matrix_Setup
sudo bash setup.sh
```

The interactive wizard walks you through 17 configuration steps: domain, homeserver type, federation, registration policy, admin account, web client, bridges, SMTP, monitoring, backups, and hardening options.

## Headless Mode

For automated or repeatable deployments, use a TOML config file:

```bash
# Generate an annotated example config
sudo bash setup.sh --generate-config > my-config.toml

# Edit the config
vim my-config.toml

# Deploy
sudo bash setup.sh --headless --config my-config.toml
```

See `config/matrix-setup.example.toml` for all available options.

## Usage

```
sudo bash setup.sh [OPTIONS]

Options:
  --headless          Non-interactive mode (requires --config)
  --config FILE       Path to TOML configuration file
  --quiet             Suppress verbose output
  --podman-secrets    Use Podman native secrets instead of .env
  --generate-config   Print example TOML config and exit
  --upgrade           Skip wizard, go straight to upgrade menu
  --rollback          Roll back the last setup run
  -h, --help          Show this help message
```

## Upgrade and Reconfigure

Re-run on an existing installation to pull updated images, add/remove bridges, or reconfigure services:

```bash
sudo bash setup.sh --upgrade
```

The upgrade flow detects your existing state, refuses domain changes, and checks for PostgreSQL major version compatibility before pulling images.

## Rollback

If something goes wrong mid-setup, Ctrl+C offers an immediate rollback. You can also roll back later:

```bash
sudo bash setup.sh --rollback
```

The rollback system tracks every change in a timestamped manifest and reverses them phase by phase. Volume data is never auto-deleted.

## Bridge Plugins

Bridges connect Matrix to other chat platforms. They are only available with Synapse.

| Bridge    | Platform  | Image                                    |
|-----------|-----------|------------------------------------------|
| Telegram  | Telegram  | `dock.mau.dev/mautrix/telegram:v0.15.2`  |
| Discord   | Discord   | `dock.mau.dev/mautrix/discord:v0.7.2`    |
| WhatsApp  | WhatsApp  | `dock.mau.dev/mautrix/whatsapp:v0.11.3`  |
| Signal    | Signal    | `dock.mau.dev/mautrix/signal:v0.7.4`     |
| Slack     | Slack     | `dock.mau.dev/mautrix/slack:v0.1.3`      |
| IRC       | IRC       | `docker.io/hif1/heisenbridge:1.9.0`      |

### Writing a Custom Bridge Plugin

Create a new file in `bridges/` implementing the plugin interface. See `bridges/_bridge_template.sh` for the required functions:

```bash
bridge_name                  # Human-readable name
bridge_description           # One-line description
bridge_image                 # Container image reference
bridge_requires_synapse      # "true" or "false"
bridge_prompt_credentials    # Interactive credential prompts
bridge_validate_credentials  # Validate stored credentials
bridge_generate_registration # Write appservice registration YAML
bridge_compose_fragment      # Echo compose service YAML
```

Plugins are auto-discovered by scanning `bridges/*.sh` (files prefixed with `_` are skipped).

## Project Structure

```
Matrix_Setup/
├── setup.sh              # Entry point
├── lib/                  # Modular library scripts (00-27)
├── bridges/              # Bridge plugin scripts
├── templates/
│   ├── compose/          # Podman Compose fragments
│   ├── configs/          # Homeserver, Caddy, Coturn templates
│   ├── snippets/         # Nginx/Apache/Traefik proxy snippets
│   └── hardening/        # SSH, sysctl, fail2ban templates
├── config/               # Example TOML config
└── tests/                # Unit and integration tests
```

## Existing Reverse Proxy

If you already run nginx, Apache, or Traefik on ports 80/443, the setup script detects it and offers two options:

1. **Generate a config snippet** for your existing proxy and skip Caddy
2. **Move your proxy** to alternate ports and let Caddy handle TLS

Pre-generated snippets are available in `templates/snippets/` for nginx, Apache, and Traefik.

## Troubleshooting

**Services not starting after reboot:**
```bash
# Check Quadlet-generated systemd units
systemctl --user -M matrix@ list-units 'matrix-*'
loginctl show-user matrix | grep Linger  # Should be "yes"
```

**Caddy can't bind port 80/443:**
```bash
# Verify sysctl allows unprivileged binding
sysctl net.ipv4.ip_unprivileged_port_start  # Should be 80
```

**Federation not working:**
```bash
# Test federation from another server
curl https://matrix.example.com/.well-known/matrix/server
# Check firewall allows port 8448
```

**TURN/STUN not working:**
```bash
# Verify Coturn is running (rootful container)
sudo systemctl status matrix-coturn
# Test STUN binding
stunclient matrix.example.com
```

**Bridge not connecting:**
```bash
# Check bridge container logs
podman --remote logs matrix-bridge-telegram
# Verify appservice registration is loaded by Synapse
```

**View logs:**
```bash
# Homeserver
podman --remote logs -f matrix-synapse
# All services
podman --remote logs -f --names matrix-pod
```

## Testing

```bash
# Run all unit tests
bash tests/test_runner.sh

# Run a specific test
bash tests/test_runner.sh toml

# Multi-distro integration tests (requires Vagrant)
cd tests/distro && vagrant up
```

## Security

- All containers run rootless under a dedicated `matrix` system user (except Coturn)
- Secrets are generated with `openssl rand -base64 48` and stored chmod 600
- Coturn blocks RFC 1918 relay attacks with explicit `denied-peer-ip` rules
- SSH hardened to key-only authentication with no root login
- fail2ban monitors Synapse and Caddy logs
- Container images pinned by immutable `@sha256` digest (not just a tag); see [docs/SUPPLY_CHAIN.md](docs/SUPPLY_CHAIN.md)
- Tagged releases are built in CI with CycloneDX SBOMs, keyless cosign signatures and SLSA build provenance
- SELinux `:Z` volume labels applied when SELinux is enforcing

User input that flows into shell, SQL, JSON or generated scripts is validated and quoted; see [CHANGELOG.md](CHANGELOG.md) for the hardening history.

## License

[MIT](LICENSE)
