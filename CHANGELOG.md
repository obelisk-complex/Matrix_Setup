# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-06-13

### Fixed

- Release workflow now publishes a self-contained Sigstore bundle
  (`<artifact>.cosign.bundle`) for the installer **and all 17 SBOMs**. v0.1.0
  signed the SBOMs but never uploaded their signatures, leaving them
  unverifiable; verification now uses a single `--bundle` file per artifact
  (no separate `.sig`/`.pem`).

### Changed

- CI/release: `actions/checkout` bumped to v6.0.3 (Node 24 runtime), clearing
  the Node.js 20 deprecation warning on GitHub Actions runners.

## [0.1.0] - 2026-06-13

Security, portability and supply-chain hardening release. Builds on the initial
0.0.1 installer with a full QA pass: injection-proof input validation, fixes to
fail-open security controls, broad portability work, every image pinned by
digest, and CI/release automation.

### Security

- Config validation now rejects injection-prone values at the source:
  `matrix_user`, `install_dir`, `coturn`/`smtp` ports, `database.user`/`name`,
  `media_retention.days`, `admin.username` and `bridges.enabled` are all
  format-checked, neutralising SQL, shell, JSON and bash-arithmetic injection.
- Known placeholder admin passwords (e.g. `changeme…`) are now rejected.
- Secret `.env` files are created with a restrictive umask (no world-readable
  window); the assembled compose file (which can hold the Cloudflare API token)
  and generated scripts are locked down.
- The PostgreSQL role/database creation no longer passes the password on the
  process command line and is no longer vulnerable to identifier injection.
- Home-directory resolution uses `getent` instead of `eval`.
- Backup/restore scripts are generated with `printf %q` quoting instead of `sed`
  substitution, removing a root-run code-injection vector.
- Bridge plugins are validated against a strict name pattern and the discovered
  plugin set before being sourced (prevents path traversal / arbitrary `source`).
- The nftables firewall path now actually applies its ruleset (previously it
  wrote a file and reported success, leaving hosts without ufw/firewalld
  unfirewalled); ufw/firewalld enable and reload failures are surfaced instead
  of being swallowed.
- SSH hardening refuses to disable password/root login unless an authorised key
  is present, preventing operator lockout on fresh hosts.
- The admin-account HMAC no longer requires `xxd` and keeps the registration
  shared secret and admin password out of process argv.

### Fixed

- Coturn no longer sets `no-udp-relay`, which had disabled UDP media relay and
  broken voice/video; the SSRF concern remains covered by `denied-peer-ip`.
- Admin account creation now retries (3×, with backoff) and prints the exact
  manual `register_new_matrix_user` fallback on failure.
- Health checks no longer count a skipped TURN test as a pass.
- Portability: replaced GNU-only `grep -oP`, `date -Iseconds` and `df -BG` usage
  with POSIX equivalents; added a bash ≥ 4.3 guard; guarded `systemctl`;
  the Quadlet compose wrapper is now a valid systemd `.service` (not `.kube`).
- The `pip3` podman-compose fallback checks for `pip3`/Python ≥ 3.8 and pins the
  package version.
- On mid-run failure the installer offers rollback (interactive) or prints the
  manual recovery command (headless) instead of leaving a half-configured host.

### Changed

- Pinned `postgres` to `16.14-alpine` and `caddy` to `2.11.4-alpine` (security
  patch releases) and `synapse-admin` to a concrete `v0.11.4-etke54` tag
  (removing the floating `latest-etke`).
- **All 17 container images are now pinned by immutable `@sha256` digest** in
  addition to their tag, via the new `scripts/pin-digests.sh` resolver.

### Fixed (image references that did not exist upstream)

- IRC bridge: `halfshot/heisenbridge:1.15.0` → `hif1/heisenbridge:1.9.0` (the
  original namespace and version did not exist).
- Dendrite: `ghcr.io/matrix-org/dendrite-monolith` → `ghcr.io/element-hq/…`
  (the project moved org; the pinned `v0.14.1` only exists under element-hq).
- Cinny: `v4.3.1` → `v4.12.2` (the pinned tag had been pruned upstream).
- SchildiChat: dead `nicoding-group` namespace → `ghcr.io/etkecc/schildichat-web`
  on a concrete release tag.

### Added (supply chain & CI)

- `scripts/pin-digests.sh` — resolves/verifies image digests via the registry
  API (no container runtime). `--check` mode is a CI drift gate.
- `scripts/gen-sbom.sh` — CycloneDX SBOM per image (syft, registry scan).
- `.github/workflows/ci.yml` — shellcheck + test suite on every push/PR.
- `.github/workflows/release.yml` — on `v*` tags: digest verification, SBOM
  generation, keyless cosign signing, and SLSA build-provenance attestation.

See [docs/SUPPLY_CHAIN.md](docs/SUPPLY_CHAIN.md) for the full procedure.

## [0.0.1] - 2026-04-07

Initial release: a modular Bash installer that deploys a complete Matrix stack
(Synapse/Dendrite, PostgreSQL, Caddy, Coturn, web clients, bridges, monitoring)
via Podman Compose, with an interactive wizard, headless TOML mode, and
backup/restore, rollback and upgrade flows.
