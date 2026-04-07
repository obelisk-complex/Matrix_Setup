# Spec: Matrix Stack Setup Script

**Date:** 2026-04-06
**Status:** Draft
**Participants:** interview, user

## Summary

A modular Bash setup script that deploys a complete Matrix communication stack (Synapse or Dendrite homeserver, web client, bridges, TURN server, reverse proxy) on any Linux server using Podman Compose. The script provides an interactive wizard with adaptive verbosity for self-hosters and sysadmins, plus a headless TOML config mode for automation. It auto-generates all secrets, provisions Let's Encrypt TLS via Caddy, and applies full server hardening.

## Context

- **Greenfield project** in an empty repository
- **Language:** Bash (modular: `setup.sh` + `lib/` directory)
- **Container runtime:** Podman (rootless where possible, rootful for Coturn)
- **Reverse proxy:** Caddy (automatic HTTPS)
- **Database:** PostgreSQL (containerized or detected on host)
- **Target OS:** Any Linux with Podman >= 4.4.0 (distro detection and adaptation)
- **Key architectural constraint:** Podman rootless cannot bind privileged ports or relay UDP media; resolved via sysctl for ports 80/443 and host-network mode for Coturn

## User Roles

| Role | Goals | Skill Level | Access Level | Notes |
|------|-------|-------------|--------------|-------|
| Self-hoster | Deploy a working Matrix server with minimal friction | Basic Linux (can SSH, follow prompts) | Server root/sudo | Primary audience; wizard explains choices |
| Sysadmin / DevOps | Efficient, scriptable deployment with full control | Advanced Linux, networking, containers | Server root/sudo | Uses headless mode, terse output, CLI flags |
| End user (Matrix) | Use the deployed server for messaging | Non-technical | Matrix client only | Not a script user; experiences the deployed stack |

## Constraints

- **Technology:** Podman Compose (not Docker), Caddy (not nginx/Traefik), Bash
- **Podman version:** Minimum 4.4.0 (Quadlet support), recommended 5.0.0+ (pasta networking)
- **Rootless limitation:** Caddy requires `net.ipv4.ip_unprivileged_port_start=80` sysctl; Coturn requires `--network=host` (rootful)
- **Domain immutability:** Matrix server name is permanent once set; cannot be changed without full redeployment and data loss
- **Synapse registration:** Since v1.56.0, open registration requires verification (email or captcha); script must enforce this
- **Dependencies:** Podman, podman-compose, curl, openssl (offered for auto-install if missing)
- **Priorities:** Reliability first, ease of use second

## Requirements

### Functional Requirements

| ID | Requirement | Priority | Acceptance Criteria |
|----|-------------|----------|---------------------|
| FR-01 | **Homeserver selection**: Prompt user to choose Synapse or Dendrite at runtime | Must | GIVEN the wizard is running WHEN the homeserver prompt appears THEN the user can select Synapse or Dendrite, and the choice gates all downstream feature availability |
| FR-02 | **Synapse deployment**: Deploy Synapse homeserver via Podman Compose with PostgreSQL backend | Must | GIVEN Synapse is selected WHEN setup completes THEN Synapse responds to `/_matrix/client/versions` over HTTPS and `/_matrix/federation/v1/version` if federation is enabled |
| FR-03 | **Dendrite deployment**: Deploy Dendrite homeserver via Podman Compose with PostgreSQL backend | Must | GIVEN Dendrite is selected WHEN setup completes THEN Dendrite responds to `/_matrix/client/versions` over HTTPS; bridges and Synapse Admin are not offered |
| FR-04 | **Database auto-detection**: Detect existing PostgreSQL on host; containerize if not found | Must | GIVEN Postgres is running on the host on port 5432 WHEN setup runs THEN the script offers to use the existing instance (prompting for credentials) OR containerize a new one; GIVEN no Postgres detected THEN a containerized Postgres is deployed automatically |
| FR-05 | **Caddy reverse proxy**: Deploy Caddy with automatic Let's Encrypt TLS | Must | GIVEN a valid domain pointing to the server WHEN Caddy starts THEN it obtains a TLS certificate and serves HTTPS on port 443; HTTP on port 80 redirects to HTTPS |
| FR-06 | **Existing proxy detection**: Detect if ports 80/443 are already bound; offer integration snippets | Must | GIVEN port 80 or 443 is in use WHEN setup runs THEN the script identifies the existing proxy software (nginx, Apache, Traefik, other), offers to generate config snippets for it (including .well-known, WebSocket upgrade, federation), and optionally skips Caddy deployment |
| FR-07 | **.well-known files**: Serve `/.well-known/matrix/server` and `/.well-known/matrix/client` | Must | GIVEN setup completes WHEN a client or federated server requests `.well-known/matrix/server` THEN it returns `{"m.server": "<domain>:443"}` with correct Content-Type |
| FR-08 | **SMTP configuration**: Prompt for SMTP details if user opts in; reuse domain for sender address default | Should | GIVEN user opts into SMTP WHEN prompted THEN collect host, port, user, password, from-address (defaulting to `noreply@<domain>`); configure homeserver email settings |
| FR-09 | **Secret generation**: Auto-generate all secrets (registration_shared_secret, macaroon_secret_key, form_secret, Postgres password, Coturn secret) | Must | GIVEN setup runs WHEN secrets are needed THEN each is generated via `openssl rand -base64 48`, stored in `.env` (chmod 600), and never displayed in terminal output |
| FR-10 | **Secrets storage modes**: Default to `.env` file; support Podman native secrets via `--podman-secrets` flag | Must | GIVEN `--podman-secrets` flag WHEN secrets are stored THEN they are created via `podman secret create` instead of `.env`; GIVEN no flag THEN `.env` is used with chmod 600 |
| FR-11 | **Web client deployment**: Offer Element Web (default), Cinny, or SchildiChat Web at runtime | Should | GIVEN the web client prompt WHEN user selects a client THEN the chosen client is deployed on a subdomain (e.g., `chat.<domain>`) with Caddy routing |
| FR-12 | **Coturn TURN/STUN**: Deploy Coturn with host networking for reliable VoIP/video, hardened against relay abuse | Must | GIVEN setup completes WHEN a STUN binding request is sent to the server THEN Coturn responds correctly; homeserver config references the TURN server with generated credentials; Coturn config includes `denied-peer-ip` for all RFC 1918, loopback, and IPv4-mapped IPv6 ranges (mitigating CVE-2026-27624); `no-multicast-peers`, `no-rfc5780`, `lt-cred-mech` enforced; `max-bps`, `user-quota`, `total-quota` set; image pinned to >= 4.9.0 |
| FR-13 | **Bridge plugin system** (Synapse only): Ship Telegram, Discord, WhatsApp, Signal, Slack, IRC bridges; allow user-dropped configs | Should | GIVEN Synapse is selected WHEN bridges prompt appears THEN user can select from available bridges; each selected bridge generates appservice registration YAML and a Compose service; GIVEN Dendrite is selected THEN bridges are not offered |
| FR-14 | **Bridge extensibility**: Users can drop additional bridge configs into a `bridges/` directory | Could | GIVEN a valid bridge config exists in `bridges/` WHEN the script runs THEN it discovers and offers the bridge alongside built-in options |
| FR-15 | **Federation control**: Prompt at runtime whether to enable federation | Must | GIVEN user enables federation WHEN setup completes THEN port 8448 is open, .well-known files are served, and the homeserver is reachable via the Matrix Federation Tester |
| FR-16 | **Synapse Admin UI** (Synapse only): Offer admin web panel at runtime | Should | GIVEN Synapse is selected and user opts in WHEN setup completes THEN synapse-admin is accessible at `admin.<domain>` or `<domain>/admin` behind authentication |
| FR-17 | **Initial admin account**: Prompt for admin username and password during setup | Must | GIVEN wizard runs WHEN admin credentials prompt appears THEN the script registers the first user as server admin via the registration shared secret API after the homeserver starts |
| FR-18 | **Registration policy**: Default to invite-only; prompt for alternatives (closed, open+email, open+captcha) | Must | GIVEN setup runs WHEN registration prompt appears THEN default is invite-only; open registration options require SMTP (email) or reCAPTCHA keys (captcha); the script refuses open registration without verification |
| FR-19 | **Domain validation and immutability warning**: Validate domain format, warn about permanence, require double entry | Must | GIVEN the domain prompt WHEN user enters a domain THEN it is validated against RFC 1035, a prominent warning about permanence is shown, and the user must type it twice to confirm; in headless mode, `domain_confirmed = true` is required in TOML |
| FR-20 | **DNS detection and Cloudflare API**: Check DNS records; offer Cloudflare API auto-creation or print manual instructions | Should | GIVEN DNS records don't resolve WHEN check runs THEN if user provides Cloudflare API token, create A/AAAA records automatically; otherwise print exact records needed |
| FR-21 | **IPv6 auto-detection**: Detect IPv6 availability; configure dual-stack if present | Should | GIVEN server has IPv6 WHEN setup runs THEN Caddy, firewall, and DNS instructions include IPv6; GIVEN no IPv6 THEN IPv4-only configuration |
| FR-22 | **Backup and restore scripts**: Generate `backup.sh` and `restore.sh` | Must | GIVEN setup completes THEN `backup.sh` exists and performs: `pg_dump --format=custom` for Postgres, media directory copy, **explicit signing key backup** as a labeled artifact, configurable retention (default: 7 daily + 4 weekly), optional S3/B2/rclone upload, exit code + `pg_restore --list` integrity verification; `restore.sh` verifies signing key matches server name before proceeding; `restore.sh --dry-run` validates without restoring; timestamps logged for pg_dump start and media copy completion (consistency window documentation) |
| FR-23 | **Backup encryption**: Optionally encrypt backups with user-provided GPG key or age public key | Could | GIVEN user provides an encryption key WHEN backup runs THEN output is encrypted before storage/upload |
| FR-24 | **Idempotent re-runs**: Detect existing installation; offer upgrade/reconfigure | Must | GIVEN the script detects an existing Matrix installation WHEN run again THEN offer: upgrade containers (pull latest images), reconfigure settings, or abort; NEVER allow changing the server name; protect existing data |
| FR-25 | **Media retention**: Configure 90-day remote media cache retention; deploy cleanup cron job | Must | GIVEN setup completes THEN homeserver config has remote media retention set to 90 days; a cron job (or systemd timer) calls the admin API to purge expired media; disk usage monitoring warns at 80% and alerts at 90% |
| FR-26 | **Monitoring stack** (optional): Offer Prometheus + Grafana at runtime | Could | GIVEN user opts into monitoring WHEN setup completes THEN Prometheus scrapes all services, Synapse metrics endpoint is enabled, and a pre-built Grafana dashboard is provisioned |
| FR-27 | **Post-install report**: Generate and save comprehensive summary | Must | GIVEN setup completes THEN a report file contains: all service URLs, ports opened, credentials file location, federation test command, backup schedule, TURN connectivity test result, next steps, and troubleshooting tips |
| FR-28 | **Error diagnosis and rollback**: On failure, diagnose the issue and offer rollback | Must | GIVEN a step fails WHEN error handler runs THEN: check logs/ports/DNS, print clear explanation, offer rollback (restore pre-change SSH config, firewall rules, sysctl values; remove created containers/pods/networks; optionally remove volumes with confirmation) or retry |
| FR-29 | **Rollback manifest**: Log pre-change state for each phase to enable safe rollback | Must | GIVEN hardening/deployment begins THEN current SSH config, firewall rules, and sysctl values are snapshotted to a manifest file; rollback restores from this manifest |

### Data Requirements

| Entity | Fields/Structure | Volume | Lifecycle | Sensitivity |
|--------|-----------------|--------|-----------|-------------|
| Secrets (.env) | registration_shared_secret, macaroon_secret_key, form_secret, postgres_password, coturn_secret, redis_password, bridge_secrets | ~10 key-value pairs | Create at setup, read at runtime, rotate manually | HIGH - chmod 600, never logged |
| Postgres database | Synapse/Dendrite schema | Grows with usage (1GB baseline, scales with rooms/users) | Create at setup, continuous R/W, backup daily, archive per retention policy | HIGH - contains all message content |
| Media store | Uploaded/cached files | Grows indefinitely without retention (10GB+ for active federated servers) | Create on upload, purge remote cache at 90 days, backup | MEDIUM - user-uploaded content |
| Homeserver config | YAML (Synapse) / YAML (Dendrite) | Single file ~2KB | Create at setup, modify on reconfigure | HIGH - contains server identity |
| Signing key | Ed25519 PEM | Single file | Create once, NEVER regenerate (invalidates all events) | CRITICAL - loss = server identity compromise |
| TOML config (headless) | All setup parameters | Single file | Created by `--generate-config`, read by headless mode | MEDIUM - contains domain, SMTP credentials |
| Rollback manifest | Pre-change system state snapshots | ~5KB per run | Created at setup start, deleted after successful completion | LOW |
| Post-install report | URLs, ports, instructions | Single file ~5KB | Created at setup completion | LOW - no secrets |

### Non-Functional Requirements

| ID | Requirement | Target | Measurement |
|----|-------------|--------|-------------|
| NFR-01 | **Cross-distro compatibility** | Ubuntu 22.04/24.04, Debian 12, Fedora 39+, CentOS Stream 9, RHEL 9, Arch, openSUSE Tumbleweed | Script completes successfully on each distro in a clean VM |
| NFR-02 | **Podman version** | Minimum 4.4.0, recommended 5.0.0+ | Script checks version, refuses < 4.4.0, warns < 5.0.0 |
| NFR-03 | **Setup completion time** | < 15 minutes on a 2-core VPS with decent network | Timed end-to-end from script start to post-install report |
| NFR-04 | **TLS security** | TLS 1.2+ only, HSTS enabled, strong ciphers | SSL Labs / testssl.sh scan grade A or higher |
| NFR-05 | **Service auto-start** | All services start after reboot without manual intervention | Reboot server, verify all services are running via health checks within 60 seconds |
| NFR-06 | **Hardening baseline** | SSH key-only, no root login, firewall active, fail2ban, auto-updates, sysctl tuning | Lynis security audit score > 80 |
| NFR-07 | **Adaptive verbosity** | Verbose by default, terse via `--quiet` flag | Verbose mode explains each step; quiet mode shows only prompts and errors |
| NFR-08 | **DNS resolution in containers** | All containers can resolve external domains | GIVEN systemd-resolved is active THEN script configures Podman DNS to use upstream resolvers; verified by test container DNS lookup |
| NFR-09 | **Bash strict mode** | All scripts use `set -euo pipefail`; entry point also sets `set -E` (errtrace) for ERR trap propagation into functions | Every `.sh` file begins with strict mode; commands where non-zero exit is expected use `|| true` or conditionals; temp files use `mktemp` with trap cleanup |
| NFR-10 | **Container image pinning** | All images pinned to specific version tags (not `latest`); digests recorded in post-install report | Compose file uses explicit tags (e.g., `matrixdotorg/synapse:v1.148.0`); FR-24 upgrade checks current vs. available version before pulling |
| NFR-11 | **PostgreSQL version pinning and locale** | Postgres container pinned to major version (e.g., `postgres:16-alpine`); DB created with `LC_COLLATE='C' LC_CTYPE='C'` | FR-24 upgrade refuses Postgres major version bump without explicit `pg_dump`/`pg_restore` migration; Synapse minimum PG 13+ enforced |
| NFR-12 | **Podman rootless prerequisites** | Verify `/etc/subuid` and `/etc/subgid` exist with >= 65536 entries for matrix user; verify `user.max_user_namespaces > 0`; verify `newuidmap`/`newgidmap` binaries exist | Script allocates subuid/subgid if missing, runs `podman system migrate`, installs `uidmap`/`shadow-utils` package if needed |
| NFR-13 | **Security headers** | Caddy config includes `Strict-Transport-Security`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy`, `Permissions-Policy`; Element Web has tailored CSP; `Server` header removed | Verified via `curl -I` in post-install checks |

### Integration Points

| System | Direction | Protocol | Notes |
|--------|-----------|----------|-------|
| Let's Encrypt (ACME) | Out | HTTPS | Caddy auto-obtains/renews certificates |
| Cloudflare API | Out | HTTPS | Optional DNS record creation; requires API token |
| SMTP server | Out | SMTP/TLS (587) | Password reset, email notifications, email verification |
| Matrix federation | Both | HTTPS (443/8448) | Server-to-server communication; requires valid TLS and .well-known |
| Telegram API | Out | HTTPS | mautrix-telegram bridge; requires api_id + api_hash |
| Discord API | Out | HTTPS/WSS | mautrix-discord bridge; requires bot token |
| WhatsApp (multidevice) | Out | HTTPS | mautrix-whatsapp bridge; QR code login |
| Signal daemon | Out | Unix socket | mautrix-signal bridge; phone number + verification |
| Slack API | Out | HTTPS | mautrix-slack bridge; OAuth or user session token |
| IRC networks | Out | TCP/TLS | Heisenbridge or appservice-irc; network-specific config |
| PostgreSQL | Internal | TCP 5432 | Homeserver database; containerized or host-detected |
| S3/B2/rclone target | Out | HTTPS | Optional backup destination |
| Prometheus | Internal | HTTP (9090) | Optional; scrapes metrics from all services |
| Grafana | Internal | HTTP (3000) | Optional; displays dashboards; proxied via Caddy |

## Scope Boundaries

### In Scope

- Interactive wizard + headless TOML config mode for full Matrix stack deployment
- Synapse and Dendrite homeserver support with feature gating
- Caddy reverse proxy with automatic Let's Encrypt
- Full server hardening (SSH, firewall, fail2ban, sysctl, auto-updates, SELinux/AppArmor)
- Coturn TURN/STUN with host networking
- Bridge plugin system (Synapse only): Telegram, Discord, WhatsApp, Signal, Slack, IRC
- Element Web, Cinny, SchildiChat Web client options
- Synapse Admin UI (Synapse only)
- Secret generation and storage (.env or Podman secrets)
- Backup/restore scripts with retention and optional encryption
- Media retention policy and cleanup automation
- DNS validation, Cloudflare API integration, IPv6 auto-detection
- Existing proxy detection with config snippet generation (nginx, Apache, Traefik)
- Dedicated `matrix` system user, Quadlet systemd integration, loginctl linger
- Post-install report, idempotent re-runs (upgrade/reconfigure)
- Error diagnosis with phased rollback
- Optional Prometheus + Grafana monitoring stack
- Dependency auto-detection and offer to install (Podman, podman-compose, etc.)
- systemd-resolved DNS workaround for Podman containers

### Out of Scope

- Conduit homeserver support
- Kubernetes / Helm deployment
- High-availability / multi-server clustering
- Email-to-Matrix gateway (email2matrix)
- Custom homeserver themes or branding
- Matrix Sliding Sync proxy (MSC3575)
- Mjolnir moderation bot
- Custom Element Web config/branding
- Web application firewall (WAF)
- DDoS mitigation (Cloudflare proxy, AWS Shield)
- Automated security scanning (Trivy, Grype) of container images

### Deferred to Future Versions

- **v2:** Synapse worker mode (Redis, generic_worker, federation_sender, media_repository worker, Caddy path routing) -- architecture in v1 must not preclude this
- **v2:** Conduit homeserver support with RocksDB backend
- **v2:** Additional bridge protocols (Facebook, Google Chat, iMessage, XMPP)
- **v2:** Automated upgrade scheduler (check for new Synapse/Dendrite releases, prompt to upgrade)
- **v2:** WAL archiving for point-in-time PostgreSQL recovery
- **v2:** Centralized logging (Loki + Grafana)

## Edge Cases and Error Handling

| Scenario | Expected Behavior |
|----------|-------------------|
| DNS not propagated yet | Caddy retries ACME challenge; script warns and offers to wait or proceed with self-signed cert for testing |
| Podman version < 4.4.0 | Script displays installed vs required version, offers to install newer version from upstream repo, refuses to proceed if declined |
| Disk nearly full (< 5GB free) | Script warns before proceeding; refuses if < 1GB free |
| Existing Matrix installation detected | Offer upgrade (pull images), reconfigure, or abort; refuse to change server name |
| Port 80/443 already bound | Identify bound process/proxy, offer config snippets or skip Caddy |
| Postgres running but not accepting connections | Report connection error, offer to containerize a separate Postgres, or ask user to fix and retry |
| Postgres version too old (< 12) | Warn about EOL version, offer to containerize a current version alongside |
| systemd-resolved active (DNS 127.0.0.53) | Detect upstream DNS from `resolvectl`, configure Podman `--dns` or `containers.conf` to use real resolvers |
| SELinux enforcing | Detect and configure `:Z` volume labels on all container mounts; configure appropriate SELinux booleans |
| AppArmor active | Generate and load AppArmor profiles for Podman containers |
| IPv6 available but DNS has no AAAA record | Warn that IPv6 is available but DNS lacks AAAA record; offer Cloudflare API or print instructions |
| SMTP connection fails | Test SMTP connectivity after configuration; warn if unreachable, allow to continue (email features degraded) |
| User enters domain typo | Double-entry confirmation; RFC 1035 validation; DNS lookup as additional check |
| Bridge API credentials invalid | Test credentials during setup where possible (Telegram, Discord); warn if invalid, allow skip |
| Container fails to start | Check container logs, identify common causes (port conflict, missing config, OOM), print diagnosis, offer retry or rollback |
| Backup script finds no database | Gracefully skip Postgres dump with warning; still backup media and config |
| Server has < 1GB RAM | Warn that Synapse needs ~500MB minimum; recommend Dendrite for low-RAM systems |
| Running in VM vs bare metal vs VPS | No behavioral difference expected; detect virtualization type for informational purposes in post-install report |
| Coturn STUN test fails | Diagnose: check firewall UDP ports, check external IP detection, check host networking; report specific failure reason |
| Missing subuid/subgid for matrix user | Detect missing entries, allocate 65536 subordinate UIDs/GIDs, run `podman system migrate`, install uidmap package if needed |
| fail2ban can't read containerized Synapse logs | Configure Synapse to log to bind-mounted file (not just stdout); ship fail2ban filter with correct failregex for `/_matrix/client/*/login` 403s; also jail Caddy access logs for admin UI |
| Podman compose tool networking mismatch | Detect which compose tool is available; if `podman-compose` (pod-based), use `localhost` for inter-service communication; if `podman compose` (service-name DNS), use service names; adapt generated configs accordingly |
| Admin account registration fails (homeserver still initializing) | Poll `/_matrix/client/versions` with 60s timeout before attempting registration; retry up to 3 times with backoff; on final failure, print manual `register_new_matrix_user` command |
| Caddy HTTP-01 challenge fails (NAT/cloud load balancer blocking port 80) | Pre-flight check for external port 80 reachability; if unreachable, offer DNS-01 challenge via Cloudflare API (if token already provided) |
| Let's Encrypt rate limit hit | Detect error, suggest staging environment for testing, offer to retry later |
| User cancels mid-setup (Ctrl+C) | Trap SIGINT, offer: rollback changes made so far, or exit leaving partial state with resume instructions |
| Headless mode with missing required fields | List all missing fields with descriptions, exit with non-zero code |
| Re-run after partial failure | Detect partial state from rollback manifest, offer to resume from last successful phase or rollback and restart |

## Assumptions

| Assumption | Default | What Changes If Wrong |
|------------|---------|----------------------|
| Server has internet access during setup | Required for package install, image pulls, ACME challenges | Offline mode would need pre-downloaded images and manual cert provisioning -- out of scope |
| User has root/sudo access | Required for sysctl, firewall, user creation, package install | Script cannot harden or configure privileged services without sudo |
| Domain DNS is already configured (or user will configure during setup) | DNS must resolve before Let's Encrypt can issue certs | Cloudflare API can auto-create records; otherwise user must create manually and re-run |
| Single-server deployment | All services on one machine | Multi-server / HA is out of scope for v1 |
| TOML parser: Python 3.11+ `tomllib` or bundled pure-Bash parser | Script checks for Python 3.11+; if unavailable, uses bundled `lib/toml_parser.sh` | Pure-Bash parser supports only the TOML subset needed by the config schema (strings, ints, bools, arrays, tables) |
| Podman Compose compatibility | `podman-compose` is used (Python-based) | If user has `docker-compose` with Podman socket, offer to use it instead |
| Bridge credentials are valid at setup time | Script tests where possible (Telegram, Discord API) | Invalid credentials = bridge won't connect; user notified in post-install report |
| Server has >= 2GB RAM | Synapse + Postgres + Caddy + Coturn baseline | Script warns if < 2GB, recommends Dendrite, refuses if < 512MB |

## Open Questions

| Question | Why It Matters | Who Might Know |
|----------|----------------|----------------|
| Should the script support Podman v5 `podman compose` (built-in) vs standalone `podman-compose` (Python)? | Podman 5+ ships its own compose subcommand which may behave differently | Podman upstream, distro maintainers |
| Should proxy config snippets support HAProxy in addition to nginx/Apache/Traefik? | HAProxy is used in some enterprise deployments | User feedback after v1 |
| What is the optimal Coturn UDP port range for typical self-hosted deployments? | Full range (49152-65535) opens many ports; narrower range may suffice for small servers | Coturn documentation, VoIP operational experience |
| Should the backup script support incremental Postgres backups (WAL archiving) in v1? | Full `pg_dump` on large databases is slow; WAL archiving enables point-in-time recovery | Deferred to v2 per scope decision |

## Domain Research Notes

### Matrix Protocol
- Matrix is an open standard for decentralized communication (matrix.org)
- Federation enables servers to communicate; requires valid TLS, .well-known endpoints, and ports 443 or 8448
- Server name (domain) is permanently bound to identity -- changing it requires full redeployment
- Since Synapse 1.56.0, open registration without verification is refused at startup

### Podman Rootless Constraints
- Rootless containers cannot bind ports < 1024 without `net.ipv4.ip_unprivileged_port_start` sysctl
- Rootless networking (slirp4netns/pasta) creates userspace network stacks inadequate for UDP media relay
- `loginctl enable-linger` required for rootless services to persist after user logout
- Quadlet (Podman 4.4+) replaces deprecated `podman generate systemd` for service management
- systemd-resolved causes DNS failures in rootless containers; requires explicit upstream DNS configuration

### Bridge Compatibility
- mautrix bridges officially support Synapse only; Dendrite is explicitly unsupported (docs.mau.fi)
- Double puppeting (MSC2409) requires Synapse; unavailable on Dendrite
- Each bridge needs appservice registration YAML added to homeserver config

### Server Hardening
- SSH: Key-only authentication, disable root login, disable password auth
- Firewall: UFW (Debian/Ubuntu), firewalld (Fedora/RHEL), nftables fallback
- fail2ban: Protect SSH and Matrix login endpoints
- sysctl: Network hardening (rp_filter, tcp_syncookies, icmp limits, IPv6 privacy)
- Automatic security updates: unattended-upgrades (Debian/Ubuntu), dnf-automatic (Fedora/RHEL)
- SELinux/AppArmor: Configure rather than disable; use `:Z` volume labels with Podman

### Backup Strategy
- `pg_dump --format=custom` for hot, consistent PostgreSQL backups
- Media directory requires filesystem-level copy
- Retention: 7 daily + 4 weekly is standard for communication servers
- Signing keys must be backed up separately -- loss = server identity loss
