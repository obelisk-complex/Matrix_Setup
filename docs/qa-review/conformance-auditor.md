# conformance-auditor report

**Target:** /media/owner/Workspace/Matrix_Setup (branch qa/fleet-loop-20260910) — implementation vs specs/README/CHANGELOG/example TOML/docs/SUPPLY_CHAIN.md
**Started:** 2026-09-10T00:00:00Z
**Status:** COMPLETE
**Findings:** CRITICAL: 4 | HIGH: 9 | MEDIUM: 8 | LOW: 3

## What conforms well

The documentation set is unusually good for a Bash project: a real spec with numbered,
testable acceptance criteria, a README whose flag list matches the parser exactly, an
annotated example config, and a supply-chain document precise enough to audit against.
Most of what those documents claim is genuinely implemented, and several areas are
implemented carefully:

- **Security headers (NFR-13) conform completely.** Every header the spec names is in
  `templates/configs/Caddyfile.tpl:14-24`, including `-Server`, plus tailored CSP for the
  web client (line 90) and the admin UI (line 104).
- **Coturn hardening (FR-12) conforms completely.** 15 `denied-peer-ip` rules,
  `no-multicast-peers`, `no-rfc5780`, `lt-cred-mech`, `max-bps`, `user-quota`,
  `total-quota` all present in `templates/configs/turnserver.conf.tpl`, and `no-udp-relay`
  correctly absent.
- **Image pinning (NFR-10) conforms.** All 17 images carry `tag@sha256:digest`
  (`lib/00_constants.sh:31-49`), matching `docs/SUPPLY_CHAIN.md:7`, with a CI drift gate
  (`release.yml:24`). The README bridge image table (`README.md:118-125`) matches the
  constants exactly, tag for tag.
- **The release pipeline matches its documentation line by line.** Every step
  `docs/SUPPLY_CHAIN.md:35-47` describes is in `.github/workflows/release.yml`, with all
  four actions SHA-pinned as the doc claims (lines 18, 27, 33, 50).
- **Strict mode (NFR-09) conforms.** Every `.sh` in the tree sets `set -euo pipefail`,
  and `setup.sh:17` adds `-E` for ERR-trap propagation exactly as specified.
- **The bridge plugin interface (FR-13/FR-14) conforms exactly.** All eight functions
  `README.md:131-140` lists are documented identically in `bridges/_bridge_template.sh:4-25`
  and implemented in all six shipped bridges; `_`-prefixed files are skipped
  (`lib/16_bridges.sh:62`) as documented.
- **Config validation is thorough and accumulates all errors before returning**
  (`lib/04_config.sh:30-216`), satisfying the headless edge case at
  `specs/...script.md:202`.
- **The post-install report (FR-27) contains every element the requirement lists** and
  leaks no secrets (`lib/24_report.sh:13-125`).
- **The claimed test count is accurate.** `bash tests/test_runner.sh` reports
  `300 passed, 0 failed, 0 skipped`, and the filtered form `test_runner.sh toml` from
  `README.md:221` works.

The findings below are concentrated in a specific place: values that cross a module
boundary. Almost every serious one is a name that module A writes and module B does not
read, or vice versa. That is the pattern worth acting on, more than any individual fix.

## Sources of truth used

- Spec: `specs/2026-04-06-matrix-stack-setup-script.md` — FR-01..FR-29, NFR-01..NFR-13, edge-case table.
- User docs: `README.md` — flags, bridge image table, distro list, security claims.
- Contract: `config/matrix-setup.example.toml` — the headless config schema (also the output of `--generate-config`).
- Claims doc: `docs/SUPPLY_CHAIN.md` — provenance/signing.
- Changelog: `CHANGELOG.md`.
- Tests: `tests/*.sh`.
- Implementation: `setup.sh`, `lib/00_*.sh`..`lib/27_*.sh`, `bridges/*.sh`, `templates/`, `.github/workflows/`.

## Claim inventory

Enumerated before checking anything, from README, spec and the example TOML.

**CLI flags (8)** — `--headless`, `--config FILE`, `--quiet`, `--podman-secrets`,
`--generate-config`, `--upgrade`, `--rollback`, `-h/--help` (`README.md:84-91`).

**Phases (21 `run_phase` calls)** — System detection, Prerequisites, Matrix user setup,
Network validation, Secret generation, Proxy detection, Server hardening, PostgreSQL,
Homeserver, Caddy, Coturn, Web client, Bridges, Admin UI, Monitoring, Compose assembly,
Quadlet, Deploy, Backup setup, Media retention, Post-install report (`setup.sh:132-185`).
Plus 17 wizard steps (`README.md:59`) and the `--upgrade`/`--rollback` entry points.

**Distros (7 named)** — Ubuntu 22.04+, Debian 12+, Fedora 39+, CentOS Stream 9+, Arch,
openSUSE (`README.md:42`); NFR-01 (`specs/...script.md:92`) adds RHEL 9 and names
openSUSE Tumbleweed specifically.

**Config keys (~48)** — the 15 tables of `config/matrix-setup.example.toml`, active and
commented alike.

**Guarantees** — FR-01..FR-29 and NFR-01..NFR-13 from the spec; the 10 Security bullets at
`README.md:229-238`; the "Current posture" and release-pipeline claims of
`docs/SUPPLY_CHAIN.md`; the 32-row edge-case table at `specs/...script.md:174-203`.

Coverage of this pass: all 8 flags, all 21 phases and the 17 wizard steps, all 7 distros
at the package-manager level, all ~48 config keys in both directions, all 10 README
security bullets, all of `docs/SUPPLY_CHAIN.md`, and roughly 30 of the 42 FR/NFR clauses.
See `## Completion` for what was not reached.

## Findings
<!-- appended one at a time, as found -->

### F-01 [HIGH] `advanced.install_dir` and `advanced.matrix_user` are read under the wrong key

- **Category:** divergent (config key round-trip failure)
- **Confidence:** 5
- **Situation.** `config/matrix-setup.example.toml:107-111` documents, under the `[advanced]` table:
  `# install_dir = "/opt/matrix"` and `# matrix_user = "matrix"`. Both the Python
  backend (`lib/03_toml_parser.sh:66-78`) and the Bash fallback
  (`lib/03_toml_parser.sh:142-158`) flatten table keys as `<table>.<key>`, so these
  emit `advanced.install_dir` and `advanced.matrix_user`. `config_load` copies
  `TOML_VALUES` verbatim into `CONFIG` (`lib/04_config.sh:19-21`) with no renaming.
- **Behaviour.** Every consumer reads the *unprefixed* keys: `CONFIG[install_dir]`
  and `CONFIG[matrix_user]` (defaults at `lib/04_config.sh:285-286`, validation at
  `lib/04_config.sh:129,136`, state file at `lib/04_config.sh:236`, plus ~40 further
  reads across `lib/`). `grep -rn 'advanced\.' --include='*.sh' .` returns exactly one
  line — `lib/04_config.sh:287`, for `advanced.podman_compose_command` — so nothing
  maps `advanced.install_dir` onto `install_dir`. The TOML value lands in `CONFIG` under
  a key no code path ever reads, and `_config_apply_defaults` then silently fills
  `install_dir` with `/opt/matrix` and `matrix_user` with `matrix`.
- **Impact.** A user who uncomments `install_dir = "/srv/matrix"` in the documented
  config gets a deployment in `/opt/matrix` with no warning, no error, and no mention in
  the post-install report. Same for a non-default `matrix_user`. On a box where `/opt`
  is small or read-only, that is a failed install with a misleading cause. It also makes
  the identifier validation at `lib/04_config.sh:129-145` dead code for user-supplied
  values: it only ever inspects the hard-coded defaults.
- **Recommendation.** Fix the code, in `config_load` after the copy loop: alias
  `advanced.install_dir` → `install_dir` and `advanced.matrix_user` → `matrix_user`
  before `_config_apply_defaults` runs (order matters — defaults must not pre-empt the
  aliased value). Alternatively fix the example TOML to declare them at top level, but
  that conflicts with `[advanced] podman_compose_command`, which *is* read under its
  prefixed name, so aliasing is the consistent fix.

### F-02 [HIGH] `--podman-secrets` is silently overridden by any `--config` file

- **Category:** divergent
- **Confidence:** 5
- **Situation.** FR-10 (`specs/...script.md:54`): "GIVEN `--podman-secrets` flag WHEN
  secrets are stored THEN they are created via `podman secret create` instead of `.env`".
  `README.md:87` lists the flag with no stated interaction with `--config`.
- **Behaviour.** Argument parsing sets `CONFIG[secrets.mode]="podman"` at
  `setup.sh:52`, but `config_load "$CONFIG_FILE"` runs later, at `setup.sh:118`, and
  copies every TOML key over the top of `CONFIG` unconditionally
  (`lib/04_config.sh:19-21`). The shipped example config sets `mode = "env"`
  (`config/matrix-setup.example.toml:104-105`), so
  `setup.sh --headless --config my-config.toml --podman-secrets`, where `my-config.toml`
  derives from `--generate-config`, stores secrets in `.env` and not in Podman secrets.
- **Impact.** The documented CLI flag is a no-op for exactly the audience the flag
  exists for (headless/sysadmin, per the spec's User Roles table). The user believes
  secrets are held by Podman; they are in a `.env` on disk. No message says otherwise —
  `lib/24_report.sh` reports the *effective* mode, so the report agrees with the file,
  not with the flag, and the discrepancy is invisible.
- **Recommendation.** Fix the code. Record CLI overrides in a separate array during
  argument parsing and re-apply them in `config_load` *after* the TOML copy loop
  (`lib/04_config.sh:21`) and before `_config_apply_defaults`. CLI beating file is the
  conventional precedence and is what both documents imply.

### F-000 [CRITICAL] The assembled compose file repeats the top-level `services:` key, so only the last fragment is deployed

- **Category:** divergent
- **Confidence:** 5 (reproduced — see the command below)
- **Situation.** FR-02 (`specs/...script.md:46`) requires Synapse deployed via Podman
  Compose and responding to `/_matrix/client/versions`. `README.md:24-36` lists the
  homeserver, database, reverse proxy, web client, admin UI and monitoring as what a run
  produces.
- **Behaviour.** `compose_assemble` (`lib/19_compose.sh:12-107`) builds a fragment list
  (lines 25-54) and concatenates the rendered fragments verbatim —
  `merged+=$'\n'"$rendered"` (`lib/19_compose.sh:70`). Every fragment carries its own
  top-level `services:` key (`templates/compose/postgres.yml`, `synapse.yml:4`,
  `caddy.yml:4`, `webclient.yml`, `admin.yml`, `monitoring.yml:4`), and both `base.yml`
  and `monitoring.yml` declare a top-level `volumes:`. Nothing merges the mappings. The
  written file therefore has `services:` as a repeated top-level key.
  Reproduced against this tree by sourcing `lib/` and calling `compose_assemble` with
  `install_dir` pointed at a scratch directory:
  - Default config (Synapse + Caddy + Element + admin UI, monitoring off): six `services:`
    blocks; `yaml.safe_load` yields `services: ['synapse-admin']` — the homeserver,
    Postgres, Caddy and the web client are all discarded.
  - With monitoring on: `services: ['grafana', 'prometheus']`, and the `postgres-data`,
    `caddy-data`, `caddy-config` volumes are dropped by the second `volumes:` key too.
  - A duplicate-key-strict loader (the behaviour of `gopkg.in/yaml.v3`, which
    `compose-go` and therefore `podman compose`/`docker compose` use) raises
    `duplicate key 'services'` at line 39 and refuses the file outright.
  So: a PyYAML-based tool (`podman-compose`) silently deploys the last fragment only;
  a Go-based tool refuses to parse. `detect_compose_command` (`lib/02_detect.sh:172-179`)
  can select either.
- **Impact.** No run of this installer as it currently stands produces a working Matrix
  stack. Under `podman-compose` the user gets a single container — `synapse-admin`, or
  Prometheus + Grafana — and no homeserver; under `podman compose` the deploy phase
  fails at `up -d`. The one guard that would catch it,
  `$COMPOSE_CMD -f "$compose_file" config --quiet` at `lib/19_compose.sh:100`, sends
  stderr to `/dev/null` and downgrades failure to
  `log_warn "Compose file validation returned warnings (may still work)"` (line 103), so
  the run continues. `tests/test_compose_assembly.sh` never assembles a file — it greps
  the individual templates (lines 12-63), including a test that each template *has* a
  `services:` key (line 63), which is the very thing that breaks the merge.
- **Recommendation.** Fix the code. Strip the leading `services:` line from every
  fragment except the first that contributes services, and emit one `services:` header;
  same for `volumes:`. A more robust fix, given `python3` is already a hard dependency
  (`lib/03_toml_parser.sh:90`, `lib/21_deploy.sh:137`): merge the fragments with a small
  Python step that `yaml.safe_load`s each and deep-merges the top-level mappings. Then
  make `lib/19_compose.sh:100-104` fatal — a compose file that does not validate must
  stop the run, not warn. Add a test that assembles a full default config and asserts
  the expected service names are all present.

### F-00 [CRITICAL] `log.config` is mounted and referenced but never generated

- **Category:** missing
- **Confidence:** 4 (both sides traced; the exact failure mode depends on which
  compose tool is present, and I cannot run a container to pin it down)
- **Situation.** Spec FR-02 (`specs/...script.md:46`) requires Synapse to respond to
  `/_matrix/client/versions` after setup. The spec's fail2ban edge case
  (`specs/...script.md:196`) requires "Configure Synapse to log to bind-mounted file
  (not just stdout)". `templates/configs/homeserver.synapse.yaml.tpl:42` sets
  `log_config: "/data/log.config"`, and `templates/compose/synapse.yml:16` bind-mounts
  `{{INSTALL_DIR}}/config/log.config:/data/log.config:ro` to satisfy it.
- **Behaviour.** Nothing ever writes `$install_dir/config/log.config`.
  `templates/configs/log.config.tpl` exists and is well-formed, but
  `grep -rn 'log\.config' lib/` returns no render call — `_homeserver_synapse` renders
  exactly one template, `homeserver.synapse.yaml.tpl`
  (`lib/12_homeserver.sh:104-107`). `hs_vars[LOG_FILE_PATH]` is assigned at
  `lib/12_homeserver.sh:97` and is consumed only by
  `templates/configs/log.config.tpl:11`, so that assignment is dead. The only test
  touching it, `tests/test_templates.sh:96-98`, asserts the `.tpl` file exists on disk
  and nothing about it being rendered.
- **Impact.** The Synapse bind mount has a source path that does not exist.
  `podman-run(1)`, `--volume`: "If the source does not exist, Podman returns an error.
  Users must pre-create the source files or directories." — so under plain Podman the
  container refuses to start. Under a compose tool that pre-creates missing sources
  (Docker-compatible behaviour) the path is created as a *directory* and Synapse then
  fails to parse `/data/log.config`. In neither case does the documented outcome occur:
  the homeserver does not come up, or comes up without the file logging that
  `specs/...script.md:196` and `README.md:233` both depend on. This is the failure a
  first-time user hits at the "Deploy" phase.
- **Recommendation.** Fix the code. In `_homeserver_synapse`, before the
  `homeserver.yaml` render at `lib/12_homeserver.sh:104`, add a second
  `template_render "${SCRIPT_DIR}/templates/configs/log.config.tpl"
  "$config_dir/log.config" hs_vars` and a matching
  `rollback_snapshot "homeserver" "FILE_CREATED" "$config_dir/log.config"`. Note the
  path this then produces is `/data/logs/homeserver.log` inside the container, i.e.
  `$install_dir/data/logs/homeserver.log` on the host — which is *not* the path the
  fail2ban jail watches; see F-04.

### F-0A [CRITICAL] Grafana ships with `admin`/`admin` on a public subdomain

- **Category:** missing
- **Confidence:** 5
- **Situation.** FR-09 (`specs/...script.md:53`) requires the script to "Auto-generate
  all secrets". `README.md:230`: "Secrets are generated with `openssl rand -base64 48`
  and stored chmod 600". FR-26 (`specs/...script.md:70`) offers the Prometheus + Grafana
  stack, and `README.md:33` lists it as a feature.
- **Behaviour.** `templates/compose/monitoring.yml:38-39` sets
  `GF_SECURITY_ADMIN_USER: admin` and
  `GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD:-admin}`.
  `grep -rn 'GRAFANA_ADMIN_PASSWORD' lib/ templates/ tests/` matches that one line —
  nothing generates the variable. `secrets_generate_all` (`lib/08_secrets.sh:22-27`)
  generates six secrets and Grafana's is not among them; the `.env` heredoc
  (`lib/08_secrets.sh:61-84`) does not contain it, and neither does the Podman-secrets
  list (`lib/08_secrets.sh:94-101`). The compose interpolation therefore resolves to the
  literal default, `admin`. Meanwhile `templates/configs/Caddyfile.tpl:113-122` publishes
  Grafana at `{{GRAFANA_SUBDOMAIN}}.{{DOMAIN}}` over public TLS with no auth in front of
  it, and `lib/18_monitoring.sh:28` tells the user that URL.
- **Impact.** Any user who opts into monitoring gets a Grafana admin panel on a public
  hostname with credentials `admin`/`admin`. That is a full read of every metric the
  Prometheus datasource can reach and, as Grafana admin, the ability to add datasources
  pointing at internal services. It is reachable by anyone who guesses or enumerates the
  subdomain — TLS certificates for it are published to Certificate Transparency logs, so
  the hostname is not secret. This contradicts the README's stated secrets guarantee
  directly, on a path the README advertises.
- **Recommendation.** Fix the code. Add
  `CONFIG[secrets.grafana_admin_password]=$(_gen_secret)` to `secrets_generate_all`
  (`lib/08_secrets.sh:22-27`), emit `GRAFANA_ADMIN_PASSWORD=...` in the `.env` heredoc
  (`lib/08_secrets.sh:61-84`) and as `matrix-grafana-password` in the Podman-secrets list
  (lines 94-101), add an `env_file: - {{INSTALL_DIR}}/.env` block to the `grafana`
  service in `templates/compose/monitoring.yml`, and remove the `:-admin` fallback so a
  missing value fails loudly rather than defaulting. Report the credential location in
  the post-install report. Consider generating it even when `monitoring.enabled` is
  false, so enabling monitoring on a later re-run does not need a secrets regeneration.

### F-04 [HIGH] fail2ban jail watches a Synapse log path that is never written

- **Category:** divergent
- **Confidence:** 5
- **Situation.** `README.md:233`: "fail2ban monitors Synapse and Caddy logs".
  `specs/...script.md:196` requires a fail2ban filter with correct failregex against a
  bind-mounted Synapse log.
- **Behaviour.** The jail written by `harden_fail2ban` sets
  `logpath = $install_dir/data/synapse/homeserver.log` (`lib/10_hardening.sh:221`).
  The log path Synapse is configured to write is `/data/logs/homeserver.log`
  (`lib/12_homeserver.sh:97`), and `templates/compose/synapse.yml:19` maps
  `{{INSTALL_DIR}}/data/logs` to `/data/logs`, so the host path is
  `$install_dir/data/logs/homeserver.log`. `data/synapse/` is not created anywhere;
  `lib/12_homeserver.sh:14` creates `$data_dir/media` and `$data_dir/signing-keys`,
  and line 98 creates `$data_dir/logs`. The unused template
  `templates/hardening/fail2ban-matrix.conf.tpl:8` has the *correct* path
  (`{{INSTALL_DIR}}/data/logs/homeserver.log`), which is where the two copies diverged.
- **Impact.** fail2ban starts, reports the `matrix-synapse` jail as enabled, and bans
  nobody, because the file it tails does not exist. A user who checks
  `fail2ban-client status matrix-synapse` sees a live jail with zero failures and
  concludes brute-force protection is working. This is independent of F-00: fixing the
  log.config render alone does not fix this path.
- **Recommendation.** Fix the code: change `lib/10_hardening.sh:221` to
  `logpath = $install_dir/data/logs/homeserver.log`, matching
  `lib/12_homeserver.sh:97` and the template. Add a test asserting the jail's `logpath`
  equals the rendered `LOG_FILE_PATH` mapped through the compose volume, since the two
  live in different modules and have already drifted once.

### F-05 [HIGH] No Caddy fail2ban jail exists

- **Category:** missing
- **Confidence:** 5
- **Situation.** `README.md:233`: "fail2ban monitors Synapse and Caddy logs".
  `specs/...script.md:196`: "also jail Caddy access logs for admin UI".
- **Behaviour.** `harden_fail2ban` (`lib/10_hardening.sh:197-245`) writes exactly two
  jails, `[matrix-synapse]` and `[sshd]` (`lib/10_hardening.sh:216-232`), and one filter,
  `matrix-synapse` (lines 235-241). `grep -rn caddy lib/10_hardening.sh
  templates/hardening/` returns nothing — there is no Caddy jail, no Caddy filter, and
  no configuration enabling Caddy access logging in `templates/configs/Caddyfile.tpl`
  for a jail to read.
- **Impact.** The admin UI (`admin.<domain>`, deployed by default —
  `CONFIG[admin_ui.enabled]` defaults to `true` at `lib/04_config.sh:271`) has no
  brute-force protection at the proxy layer, contrary to what the README's Security
  section states. A user relying on that line does not add their own protection.
- **Recommendation.** Fix both. Either implement the Caddy jail (which also requires
  enabling an access log in the Caddyfile template) or narrow `README.md:233` to
  "fail2ban monitors SSH and Synapse login endpoints" and record the Caddy jail as
  deferred in the spec. The spec asks for it, so implementing is the conformant option.

### F-06 [MEDIUM] `templates/hardening/` is documented but never read

- **Category:** divergent (dead contract surface)
- **Confidence:** 5
- **Situation.** `README.md:155` documents the project layout as including
  `templates/hardening/  // SSH, sysctl, fail2ban templates`, listed alongside
  `templates/configs/` and `templates/compose/`, which *are* rendered
  (`lib/12_homeserver.sh:105`, `lib/13_caddy.sh:93`, `lib/14_coturn.sh:53`,
  `lib/19_compose.sh:17`).
- **Behaviour.** `grep -rn 'templates/hardening' lib/ setup.sh tests/ scripts/` returns
  nothing. All four files in that directory
  (`99-matrix-hardening.conf.tpl`, `fail2ban-matrix.conf.tpl`,
  `fail2ban-matrix-filter.conf.tpl`, `sysctl-matrix.conf.tpl`) are inert.
  `lib/10_hardening.sh` instead inlines every one of them as a heredoc
  (jail at lines 216-232, filter at 235-241, sysctl at 257-277). The copies have already
  drifted: the template uses `port = http,https` and
  `logpath = {{INSTALL_DIR}}/data/logs/homeserver.log`
  (`templates/hardening/fail2ban-matrix.conf.tpl:6,8`), the live heredoc uses
  `port = 443,$PORT_FEDERATION` and `data/synapse/homeserver.log`
  (`lib/10_hardening.sh:219,221`).
- **Impact.** No runtime difference — this is documentation drift, not a defect a user
  observes. The cost is to maintainers: the drift in F-04 is precisely what happens when
  two copies exist and only one is live. A contributor who fixes the jail in the
  template directory the README points at changes nothing.
- **Recommendation.** Fix the code: render the hardening templates like every other
  template directory, and delete the heredocs. Failing that, delete
  `templates/hardening/` and the README line.

### F-07 [MEDIUM] Automatic security updates are a no-op on Arch and ineffective on openSUSE

- **Category:** partial
- **Confidence:** 4 (code path is unambiguous; the openSUSE half rests on what the
  named package does, which I could not verify from a man page on this host)
- **Situation.** `README.md:35` lists "automatic security updates" as part of Hardening,
  and `README.md:42` lists Arch and openSUSE as supported. Spec NFR-06
  (`specs/...script.md:97`) makes auto-updates part of the hardening baseline for all of
  NFR-01's distro list. `CONFIG[hardening.auto_updates]` defaults to `true`
  (`lib/04_config.sh:283`) and the example TOML sets `auto_updates = true`
  (`config/matrix-setup.example.toml:101`).
- **Behaviour.** `harden_auto_updates` (`lib/10_hardening.sh:296-326`) configures a real
  mechanism only for `debian` (unattended-upgrades, lines 300-311) and `rhel`
  (dnf-automatic timer, lines 312-318). For `arch` it logs a warning and does nothing
  (lines 319-321). For `suse` it installs `yast2-online-update-configuration` and
  enables no timer or service (lines 322-324) — `UNVERIFIED:` that package is a YaST
  configuration front-end rather than an updater, so installing it without further
  configuration is unlikely to schedule anything, but I could not confirm this against
  openSUSE documentation offline.
- **Impact.** An Arch or openSUSE user who leaves `hardening.auto_updates = true` gets
  a run that reports hardening applied and receives no automatic security updates. The
  Arch case is a deliberate and defensible choice (rolling release, partial upgrades are
  unsupported) — the gap is that the choice is stated only in a runtime `log_warn` and
  in neither README nor spec.
- **Recommendation.** Fix both. Document the per-distro auto-update matrix in the README
  Requirements section, and for openSUSE either enable a real timer or emit the same
  explicit "not configured" warning Arch gets, so the two unsupported cases behave the
  same way.

### F-08 [LOW] Spec requires generating AppArmor profiles; code deliberately does not

- **Category:** divergent
- **Confidence:** 5
- **Situation.** The spec's edge-case table (`specs/...script.md:185`) states, for
  "AppArmor active": "Generate and load AppArmor profiles for Podman containers".
  `specs/...script.md:253` repeats "SELinux/AppArmor: Configure rather than disable".
- **Behaviour.** `harden_mac` (`lib/10_hardening.sh:291-293`) detects AppArmor and logs
  "AppArmor detected, no custom profiles needed for Podman", generating and loading
  nothing. The SELinux half of the same requirement *is* implemented — the boolean at
  `lib/10_hardening.sh:288` and `:Z` labels via `VOLUME_LABEL` at
  `lib/19_compose.sh:20-21`.
- **Impact.** No user-observable difference; Podman ships a default AppArmor profile, so
  containers are confined either way. This is a spec-vs-code disagreement where the code
  looks right and the spec looks over-specified. `README.md:35` does not repeat the
  "generate profiles" claim, so no user-facing document is wrong.
- **Recommendation.** Fix the spec: change the edge-case row to "rely on Podman's default
  AppArmor profile; do not disable", and keep the code. The reasoning is already in the
  comment at `lib/10_hardening.sh:283-285`; it belongs in the spec so the next audit does
  not re-raise this.

### F-03 [MEDIUM] `--help` prints two lines of source code

- **Category:** partial
- **Confidence:** 5
- **Situation.** `README.md:91` documents `-h, --help  Show this help message`, and
  `README.md:80-92` shows the intended usage block.
- **Behaviour.** `setup.sh:56` implements help as `head -17 "$0" | tail -14`, i.e. a
  raw slice of lines 4-17 of the script. Running that slice today emits the option list
  with its `#` comment markers intact, then two lines that are not documentation:
  `# shellcheck disable=SC2154` and `set -Eeuo pipefail`. It also omits `setup.sh:3`,
  the `Usage:` line, which the README's block leads with.
- **Impact.** A user running `--help` sees shell source in the help text. The option
  list itself is complete and matches `README.md:84-91` exactly, so nothing is
  mis-documented; the defect is presentation. The line-slice is also fragile: inserting
  a line anywhere in the first 17 lines shifts the window silently.
- **Recommendation.** Fix the code. Replace with a heredoc `usage()` function, or at
  minimum `sed -n '3,14p' "$0" | sed 's/^# \?//'`. A line-offset slice of the file being
  documented has no failure signal when it drifts.

### F-09 [HIGH] The media purge the timer runs can never authenticate, and targets an unpublished port

- **Category:** partial
- **Confidence:** 4 (both halves read directly from the generated script; I cannot run
  a pod to observe the 401 and the connection refusal)
- **Situation.** FR-25 (`specs/...script.md:69`): "a cron job (or systemd timer) calls
  the admin API to purge expired media". `README.md:34` and the post-install report
  present media retention as configured.
- **Behaviour.** Two independent blockers in the generated
  `$install_dir/scripts/media-cleanup.sh`:
  1. `ADMIN_TOKEN="$(cat ${install_dir}/.admin-token 2>/dev/null || true)"`
     (`lib/23_media_retention.sh:24`). `grep -rn 'admin-token' lib/ templates/` matches
     that one line — nothing in the codebase ever writes `.admin-token`. The variable is
     always empty, so the request carries `Authorization: Bearer ` and Synapse rejects it.
  2. The request targets `http://localhost:${PORT_SYNAPSE}` i.e. host port 8008
     (`lib/23_media_retention.sh:33`), but the Synapse service publishes nothing —
     `templates/compose/synapse.yml:33` is `ports: []`, and only Caddy publishes
     (`templates/compose/caddy.yml:18`). The script runs on the host under
     `systemd --user`, outside the pod's network namespace.
  Both failures are swallowed: `curl -sf ... || log "WARNING: Media purge failed"`
  (lines 33-34), and the script then exits 0, so the timer reports success.
- **Impact.** Remote media accumulates indefinitely on a server the user believes is
  pruning it weekly. `systemctl --user list-timers` shows the timer firing and
  succeeding; only the journal line reveals the failure, and it is a WARNING inside a
  unit that exited 0. The disk-usage warning at 80/90% (lines 40-44) does still work,
  so the user gets a disk alert eventually — which is the symptom, not the cause.
  The *config* half of FR-25 conforms: `media_retention.remote_media_lifetime` is set to
  90d via `templates/configs/homeserver.synapse.yaml.tpl:67-68` and
  `lib/12_homeserver.sh:200`, so Synapse's own internal retention still applies.
- **Recommendation.** Fix the code. Write an admin access token to
  `$install_dir/.admin-token` (chmod 600) when the admin account is created in
  `_deploy_create_admin` (`lib/21_deploy.sh`), and reach Synapse through the container
  rather than host localhost — e.g. `podman --remote exec matrix-synapse curl ...`, or
  route via Caddy at `https://<domain>/_synapse/admin/v1/purge_media_cache`. Also drop
  the `|| log WARNING` swallow so a failing purge is visible to `systemctl --user status`.
  `RETENTION_MS` at `lib/23_media_retention.sh:26` is computed and never used; remove it.

### F-10 [HIGH] `advanced.podman_compose_command` is documented, defaulted, and never read

- **Category:** divergent (config key round-trip failure)
- **Confidence:** 5
- **Situation.** `config/matrix-setup.example.toml:108-109` documents
  `podman_compose_command = "auto"  # "auto", "podman compose", "podman-compose", "docker-compose"`.
  `README.md:76` states "See `config/matrix-setup.example.toml` for all available
  options", making the example TOML the config contract. The spec's compose-mismatch
  edge case (`specs/...script.md:197`) requires the script to adapt to whichever tool is
  present.
- **Behaviour.** `grep -rn 'podman_compose_command' lib/ setup.sh` matches exactly one
  line: the default assignment `: "${CONFIG[advanced.podman_compose_command]:=auto}"`
  at `lib/04_config.sh:287`. No consumer reads it. `COMPOSE_CMD` is set solely by
  autodetection in `detect_compose_command` (`lib/02_detect.sh:170-185`), which hard-codes
  the preference order `podman compose` > `podman-compose` > `docker-compose` and cannot
  be overridden.
- **Impact.** A user on a box with both `podman compose` and `podman-compose` installed
  who sets `podman_compose_command = "podman-compose"` in the TOML — the documented way
  to pin the tool — silently gets `podman compose` instead. This matters because the two
  differ in networking model: `detect_compose_command` sets `COMPOSE_NETWORKING` to `dns`
  vs `pod` accordingly (`lib/02_detect.sh:174,177`), so the choice changes how services
  address each other. The config file says one thing and the deployment does another,
  with no warning.
- **Recommendation.** Fix the code: in `detect_compose_command`, honour a non-`auto`
  value of `CONFIG[advanced.podman_compose_command]` (validating it against the three
  accepted strings and that the binary exists) before falling through to autodetection.
  Deleting the key from the example TOML would also close the gap but loses a capability
  the spec's edge case implies.

### F-11 [HIGH] Backup retention has no weekly tier — the recovery window is 11 days, not 5 weeks

- **Category:** partial
- **Confidence:** 5
- **Situation.** FR-22 (`specs/...script.md:66`) requires "configurable retention
  (default: 7 daily + 4 weekly)". `specs/...script.md:258` repeats "Retention: 7 daily +
  4 weekly is standard for communication servers". `README.md:34` says "retention
  policy". `config/matrix-setup.example.toml:88-89` exposes `retention_daily = 7` and
  `retention_weekly = 4` as separate knobs, which only makes sense as two tiers.
- **Behaviour.** The generated `backup.sh` has one retention rule
  (`lib/22_backup.sh:143-149`):
  `find "$BACKUP_DIR" -name 'matrix-backup-*.tar.gz*' -type f | sort -r | tail -n +$((RETENTION_DAILY + RETENTION_WEEKLY + 1)) | ... rm -f`.
  It sorts all archives by name (i.e. timestamp) descending and deletes everything past
  position `7 + 4 = 11`. No archive is ever promoted to or retained as "weekly"; the two
  config values are simply summed. The timer runs daily
  (`OnCalendar=*-*-* 03:00:00`, `lib/22_backup.sh:333`).
- **Impact.** The oldest recoverable backup is 11 days old, not the ~5 weeks a "7 daily +
  4 weekly" policy provides. A user restoring from corruption or a bad migration
  discovered three weeks later finds no backup from before it. Raising `retention_weekly`
  does extend the window, but linearly in days, not weeks — so the documented knob does
  not mean what its name says.
- **Recommendation.** Fix the code: keep the newest `RETENTION_DAILY` archives
  unconditionally, then retain one archive per ISO week for the newest `RETENTION_WEEKLY`
  distinct weeks (e.g. group by `date -d` week number parsed from the
  `matrix-backup-YYYYMMDD_HHMMSS` name), deleting the rest. If tiering is not wanted,
  fix the spec and rename the keys to something like `retention_count`.

### F-12 [MEDIUM] `restore.sh` hard-codes `podman compose`, ignoring the detected tool

- **Category:** divergent
- **Confidence:** 5
- **Situation.** The spec's compose-mismatch edge case (`specs/...script.md:197`)
  requires the script to detect which compose tool is available and adapt. Every other
  generated or executed compose invocation honours the detected value: `lib/21_deploy.sh:39,52`,
  `lib/26_upgrade.sh:97,103`, `lib/19_compose.sh:100`, the Quadlet unit
  (`lib/20_quadlet.sh:86-87`), and the post-install report (`lib/24_report.sh:81,104`).
- **Behaviour.** The generated `restore.sh` calls `podman compose` literally, three times
  (`lib/22_backup.sh:268,273,299`), rather than interpolating `$COMPOSE_CMD` the way the
  sibling generator interpolates `$backup_dir` and friends via `printf %q`.
- **Impact.** On a host where `podman compose` is unavailable and `podman-compose` was
  selected (`lib/02_detect.sh:175-177`), `restore.sh` fails at the first step — stopping
  the stack — with `unrecognized command`. It fails during disaster recovery, which is
  the only time the script is run, and the failure is at the "stop services" line so the
  user is left with a running stack and a half-executed restore. Note `podman compose`
  falls back to whatever compose provider it finds on some builds, so this may degrade
  rather than fail outright on those; the divergence stands either way.
- **Recommendation.** Fix the code: emit `COMPOSE_CMD=%q` in the `printf` header block at
  `lib/22_backup.sh:245-252` alongside `INSTALL_DIR` and `DOMAIN`, and use `$COMPOSE_CMD`
  in the three call sites.

### F-13 [MEDIUM] `restore.sh` verifies the signing key against the current install, not against the server name

- **Category:** partial
- **Confidence:** 5
- **Situation.** FR-22 (`specs/...script.md:66`): "`restore.sh` verifies signing key
  matches server name before proceeding".
- **Behaviour.** The check (`lib/22_backup.sh:216-238`) `diff`s the backup's
  `*.signing.key` against `$INSTALL_DIR/data/signing-keys/*.signing.key`. It is guarded
  by `if [[ -d "$INSTALL_DIR/data/signing-keys" ]]` (line 218) with no `else`, so when
  that directory is absent the verification is skipped in silence and the restore
  proceeds. `DOMAIN` is baked into the script (`lib/22_backup.sh:250`) but is never
  compared against anything.
- **Impact.** The skip path is exactly the disaster-recovery case the requirement was
  written for: restoring onto a fresh server, where no current key exists. Restoring a
  backup taken from `matrix.a.example` onto a host set up as `matrix.b.example` proceeds
  with no warning, producing a homeserver whose database and signing key disagree with
  its configured `server_name` — federation breaks in ways that are hard to diagnose
  afterwards. In the same-host case the check works and is useful.
- **Recommendation.** Fix the code: Synapse names the key file `<server_name>.signing.key`,
  so add a check that the backup's key filename basename equals `${DOMAIN}.signing.key`,
  run unconditionally and before the existing `diff`. Keep the `diff` as the second,
  same-host check.

### F-14 [MEDIUM] `SUPPLY_CHAIN.md`'s "only network-fetched package" claim no longer holds

- **Category:** divergent
- **Confidence:** 5
- **Situation.** `docs/SUPPLY_CHAIN.md:10-12`: "No `curl | bash` / `wget | sh` patterns
  anywhere. The only network-fetched package is `podman-compose` (pip fallback), which is
  version-pinned and guarded by pip3/Python presence checks." `README.md:234` points users
  at this document as the basis for its supply-chain claims.
- **Behaviour.** The no-`curl | bash` half is true — `grep -rn "curl.*|.*bash"` over the
  tree returns nothing. The rest has drifted:
  - The Arch path clones and builds an AUR helper from
    `https://aur.archlinux.org/${helper}.git` at `--depth 1` of whatever HEAD is
    (`lib/05_prerequisites.sh:172`), then runs `makepkg` on the fetched PKGBUILD
    (line 190) and `pacman -U` on the result (line 200). No commit, tag or checksum is
    pinned. It then installs `podman-compose` through that helper
    (`lib/05_prerequisites.sh:139`). This is a second network-fetched package, fetched
    less reproducibly than the pip one, and it executes build scripts as a side effect.
    It is consent-gated (`_aur_consent`, lines 100-114, defaulting to "no" and printing
    the PKGBUILD first), which is good practice — but it is not what the document says.
  - Two of the three pip call sites bypass the pinned helper: `pip3 install
    podman-compose 2>/dev/null || true` at `lib/05_prerequisites.sh:243` and `:294`,
    unpinned and with no pip3/Python guard, versus `pip3 install "podman-compose==1.3.0"`
    inside `_pip_install_compose` (`lib/05_prerequisites.sh:318`), whose comment at lines
    305-308 states the pinning intent the other two do not follow.
- **Impact.** Documentation drift with a real security-posture component: a reader
  auditing this project's supply chain from `docs/SUPPLY_CHAIN.md` concludes that nothing
  unpinned is fetched at install time. On Arch, an unpinned AUR clone is built and
  executed, and an unpinned PyPI package may be installed. No user observes a behavioural
  difference; the harm is to anyone making a trust decision from the document.
- **Recommendation.** Fix both. Point `lib/05_prerequisites.sh:243` and `:294` at
  `_pip_install_compose` so all three sites are pinned and guarded, and amend
  `docs/SUPPLY_CHAIN.md:10-12` to describe the AUR path honestly — that it exists, is
  Arch-only, is consent-gated with the PKGBUILD shown, and is not digest-pinned.

### F-15 [CRITICAL] The whole deploy phase probes `localhost:8008`, which nothing publishes

- **Category:** divergent
- **Confidence:** 4 (both sides read directly; I cannot run a pod to observe the
  connection refusal)
- **Situation.** FR-02 (`specs/...script.md:46`) — Synapse must answer
  `/_matrix/client/versions`. FR-17 (`specs/...script.md:61`) — the script registers the
  first user as admin via the shared-secret API after the homeserver starts. The
  edge-case table (`specs/...script.md:198`) requires polling
  `/_matrix/client/versions` before attempting registration.
- **Behaviour.** All three probes address the host loopback:
  `_deploy_wait_for_homeserver` uses `http://localhost:${PORT_SYNAPSE}/_matrix/client/versions`
  (`lib/21_deploy.sh:61`), `_deploy_create_admin` uses
  `http://localhost:${PORT_SYNAPSE}/_synapse/admin/v1/register` (`lib/21_deploy.sh:93`),
  and `_deploy_health_checks` uses the same host URL twice
  (`lib/21_deploy.sh:203,213`). But the Synapse service publishes nothing —
  `templates/compose/synapse.yml:33` is `ports: []`, and `dendrite.yml:28` likewise.
  Only Caddy publishes, and only 80/443/8448 (`templates/compose/caddy.yml:18-23`).
  `compose_assemble` injects no additional port mappings (`lib/19_compose.sh:12-107`;
  `_compose_build_vars` at lines 119-133 defines `PORT_HTTP`, `PORT_HTTPS`,
  `FEDERATION_PORT`, `STUN_PORT` and no homeserver port). The deploy code runs on the
  host, outside the pod's network namespace.
- **Impact.** `_deploy_wait_for_homeserver` exhausts its 180s timeout and returns 1
  (`lib/21_deploy.sh:82-84`), so `deploy_run` fails, `run_phase "Deploy"` fails
  (`setup.sh:180,202-205`), the ERR trap fires and the user is offered a rollback of a
  stack that may in fact be running fine. The admin account is never created, and the
  post-install health checks would report Client API and Federation API as FAILED.
  A user following the Quick Start sees the run abort at Deploy after three minutes of
  "still waiting". Note this is downstream of F-000 — with the compose file broken, the
  homeserver is not running either — but it is an independent defect that survives fixing
  F-000.
- **Recommendation.** Fix the code. Either publish the homeserver port on loopback only
  by adding `ports: ["127.0.0.1:8008:8008"]` to `templates/compose/synapse.yml` and
  `dendrite.yml` (and keep the firewall closed to it), or run the probes inside the
  container: `run_as_user podman exec matrix-synapse curl -sf http://localhost:8008/...`.
  The second avoids exposing the unauthenticated `/_synapse/admin` endpoint on the host
  at all and is the safer default. The same fix applies to
  `lib/23_media_retention.sh:33` (F-09).

### F-16 [MEDIUM] Caddy's healthcheck probes the admin endpoint the Caddyfile turns off

- **Category:** divergent
- **Confidence:** 5
- **Situation.** NFR-05 (`specs/...script.md:96`) requires services to be verifiable
  "via health checks within 60 seconds" of a reboot.
- **Behaviour.** `templates/compose/caddy.yml:29` sets the healthcheck to
  `wget --spider http://localhost:2019/metrics`. Port 2019 is Caddy's admin endpoint,
  and `templates/configs/Caddyfile.tpl:7` sets `admin off` in the global options block.
  Per the Caddy documentation for the `admin` global option: "If set to `off`, then the
  admin endpoint will be disabled" — nothing listens on 2019, so the probe can never
  succeed.
- **Impact.** The Caddy container is permanently reported `unhealthy` by
  `podman ps`/`podman healthcheck run`, on an otherwise working reverse proxy. Nothing
  currently gates on it — no service declares `depends_on: caddy: condition:
  service_healthy` — so no deployment step breaks, but any user or monitoring check that
  trusts container health sees a false alarm, and any future `depends_on` on Caddy would
  deadlock. The two claims are also mutually exclusive by design: keeping `admin off` is
  the right call for a public server.
- **Recommendation.** Fix the code: keep `admin off` and change the healthcheck to
  something the public listener serves, e.g.
  `wget --spider --no-check-certificate https://localhost/.well-known/matrix/server`, or
  a plain TCP check on 443. Do not re-enable the admin endpoint to satisfy a healthcheck.

### F-17 [HIGH] A Cloudflare token makes Caddy load a DNS module the pinned image does not contain

- **Category:** divergent
- **Confidence:** 4 (the module-absence claim is verified against upstream docs; I have
  not run the image)
- **Situation.** FR-20 (`specs/...script.md:64`) offers Cloudflare API DNS record
  creation when DNS does not resolve. The edge case at `specs/...script.md:199` offers a
  DNS-01 ACME challenge via Cloudflare "if token already provided", and only in the
  narrower case that a pre-flight port 80 check fails.
  `config/matrix-setup.example.toml:114-115` documents
  `cloudflare_api_token` as being "For automatic DNS record creation + DNS-01 ACME
  challenge".
- **Behaviour.** `lib/13_caddy.sh:85-90` sets `DNS_CHALLENGE=true` whenever
  `CONFIG[dns.cloudflare_api_token]` is non-empty — with no port-80 pre-flight and no
  prompt — which emits `acme_dns cloudflare {env.CF_API_TOKEN}` into the global options
  block (`templates/configs/Caddyfile.tpl:8-10`). The image is
  `docker.io/library/caddy:2.11.4-alpine` (`lib/00_constants.sh:34`). The official Caddy
  Docker image ships only Caddy's standard modules; DNS provider plugins such as
  `caddy-dns/cloudflare` are not included and must be compiled in with `xcaddy` via the
  `:builder` variant. `acme_dns cloudflare` therefore names a module that is not
  registered in this binary, and Caddy rejects the config at load.
- **Impact.** A user who supplies a Cloudflare token — the documented way to get
  automatic DNS record creation, which has nothing to do with ACME challenges — ends up
  with a Caddyfile the pinned image cannot load. Caddy exits on start, so TLS, the web
  client, the admin UI and all `/_matrix` routing are down. The two features share one
  config key, so opting into the first silently opts you into the second.
- **Recommendation.** Fix the code, in two parts. (1) Gate `DNS_CHALLENGE` on an explicit
  condition, not on token presence — the spec asks for it only when the port-80
  pre-flight fails — so DNS record creation and DNS-01 stop being the same switch.
  (2) DNS-01 needs a Caddy build containing `caddy-dns/cloudflare`: either pin an image
  that has it and record the digest in `lib/00_constants.sh` per
  `docs/SUPPLY_CHAIN.md:29-33`, or drop DNS-01 and mark the spec edge case as deferred.
  Shipping the directive against the stock image is the one option that cannot work.

### F-18 [HIGH] "Skip Caddy and use my existing proxy" cannot take effect

- **Category:** divergent
- **Confidence:** 5
- **Situation.** FR-06 (`specs/...script.md:50`) requires that when port 80 or 443 is in
  use, the script "offers to generate config snippets for it ... and optionally skips
  Caddy deployment". `README.md:160-167` promises the same two options by name.
- **Behaviour.** Three variables that should be one:
  - `proxy_detect` records its outcome in the shell variable `SKIP_CADDY`
    (`lib/09_proxy_detect.sh:33` for headless, `:45` for the "generate snippets and skip
    Caddy" menu choice). `grep -rn SKIP_CADDY lib/ setup.sh tests/` returns only its
    declaration at `lib/09_proxy_detect.sh:7` and those two assignments — **nothing reads
    it**.
  - `compose_assemble` decides whether to include Caddy from a different key:
    `if [[ "${CONFIG[proxy.external]:-false}" != "true" ]]` (`lib/19_compose.sh:37`).
  - `CONFIG[proxy.external]` is written only by `wizard_step_proxy`
    (`lib/27_wizard.sh:386,392`), and the branch that sets it to `true` is guarded by
    `if [[ "${CONFIG[proxy.detected]:-}" != "" ]]` (`lib/27_wizard.sh:383`).
    `CONFIG[proxy.detected]` is never assigned anywhere — `proxy_detect` sets the shell
    variable `DETECTED_PROXY` instead (`lib/09_proxy_detect.sh:20-27`). So that guard is
    always false and line 392 always runs: `CONFIG[proxy.external]="false"`.
- **Impact.** On a host that already runs nginx/Apache/Traefik on 80/443 — the exact
  scenario the feature exists for — the user is offered the choice, picks "generate
  snippets and skip Caddy", and Caddy is deployed anyway and fights the existing proxy
  for the ports. In headless mode the same thing happens with no prompt at all
  (`lib/09_proxy_detect.sh:32-34`). Related: `proxy_detect` is invoked twice per
  interactive run — once from `wizard_step_proxy` (`lib/27_wizard.sh:380`) and again as
  its own phase (`setup.sh:160`) — so the user answers the same menu twice.
- **Recommendation.** Fix the code. Have `proxy_detect` write `CONFIG[proxy.detected]`
  (from `DETECTED_PROXY`) and `CONFIG[proxy.external]` (in place of `SKIP_CADDY`), delete
  `SKIP_CADDY`, and drop one of the two `proxy_detect` invocations — `setup.sh:160` is
  the phase-ordered one and `lib/27_wizard.sh:378-381` is the duplicate. Add a test that
  sets `CONFIG[proxy.external]=true` and asserts `caddy.yml` is absent from the assembled
  fragment list.

### F-19 [MEDIUM] Coturn's IPv6 branch reads a config key nothing ever sets

- **Category:** partial
- **Confidence:** 5
- **Situation.** FR-21 (`specs/...script.md:65`): "GIVEN server has IPv6 WHEN setup runs
  THEN Caddy, firewall, and DNS instructions include IPv6".
- **Behaviour.** `coturn_setup` decides IPv6 from
  `if [[ "${CONFIG[network.ipv6]:-false}" == "true" ]]` (`lib/14_coturn.sh:37-41`).
  `grep -rn 'network\.ipv6' lib/` matches only that read. Detection stores its result in
  the shell variable `HAS_IPV6` (`lib/02_detect.sh:17,127`), which `lib/07_network.sh:199`
  uses correctly for the DNS-instructions half of FR-21. Nothing bridges the two, so
  `turn_vars[IPV6]` is always `false`.
- **Impact.** On a dual-stack server, Coturn is configured IPv4-only while the DNS
  instructions tell the user to create an AAAA record. Clients that reach the server over
  IPv6 get no TURN relay, so calls fail to connect for the subset of users on
  IPv6-only or IPv6-preferred networks — an intermittent, hard-to-attribute symptom. The
  DNS and firewall halves of FR-21 do conform.
- **Recommendation.** Fix the code: set `CONFIG[network.ipv6]="$HAS_IPV6"` in
  `detect_all` (`lib/02_detect.sh:202-208`) alongside the other detection results, or read
  `HAS_IPV6` directly at `lib/14_coturn.sh:37`. Setting it in `detect_all` is preferable —
  it also makes the value available to headless overrides and to the state file.

### F-20 [LOW] Comment markers in the README project tree were corrupted since v0.1.1

- **Category:** regressed
- **Confidence:** 5
- **Situation.** `README.md:144-158` renders a project layout inside a ```` ``` ````
  fence, using `#` for the trailing comments, as ASCII trees conventionally do.
- **Behaviour.** `git diff v0.1.1..HEAD -- README.md` shows two lines changed from `#` to
  `//` — `templates/hardening/` (now `README.md:155`) and `tests/` (now `README.md:157`) —
  while the four sibling lines around them still use `#`. The same diff also drops the
  trailing newline at end of file. Verified at the blob:
  `git show v0.1.1:README.md` has `└── tests/                # Unit and integration tests`.
  These landed in `44d0544` ("rescue: uncommitted prerequisites and hardening work from
  the parent clone") alongside unrelated changes, so they read as accidental.
- **Impact.** Cosmetic only — an inconsistent comment marker in a rendered code block, and
  a missing final newline that some tools flag. No behaviour changes. Documentation drift,
  not a defect.
- **Recommendation.** Fix the doc: restore `#` on `README.md:155,157` and the trailing
  newline.

### F-21 [LOW] Unreleased Arch/AUR work has no CHANGELOG entry

- **Category:** missing
- **Confidence:** 5
- **Situation.** `CHANGELOG.md:3-5` states the file follows Keep a Changelog, whose
  convention is that unreleased changes accumulate under an `## [Unreleased]` heading.
- **Behaviour.** `git diff --stat v0.1.1..HEAD` shows 178 added lines in
  `lib/05_prerequisites.sh` (AUR helper bootstrap, `podman.socket` enablement, the
  `MATRIX_ALLOW_AUR` opt-in) and 3 in `lib/10_hardening.sh`, with `CHANGELOG.md`
  unchanged and no `## [Unreleased]` section present. The newest entry is
  `## [0.1.1] - 2026-06-13` at line 7.
- **Impact.** No user-visible difference today, since none of it is released. It becomes a
  problem at the next tag: `release.yml:64` passes `--notes-file CHANGELOG.md`, so the
  release notes for the version that ships the Arch work would not mention it.
- **Recommendation.** Fix the doc: add an `## [Unreleased]` section covering Arch/AUR
  `podman-compose` installation (consent-gated, `MATRIX_ALLOW_AUR` for headless) and
  `podman.socket` auto-enablement.

## Undocumented surface (reverse pass)

Config keys the code reads that `config/matrix-setup.example.toml` never mentions. All are
settable in a TOML file today, because `config_load` copies every parsed key into `CONFIG`
verbatim (`lib/04_config.sh:19-21`) — so each is real, reachable, unsupported surface.

| Key | Read at | Default | Reachable how | Verdict |
| --- | ------- | ------- | ------------- | ------- |
| `media_retention.days` | `lib/12_homeserver.sh:200`, `lib/23_media_retention.sh:14` | `90` (`lib/00_constants.sh:64`) | `[media_retention] days = 30` in TOML | Document it. It has dedicated validation (`lib/04_config.sh:178-182`) and a CHANGELOG mention (`CHANGELOG.md:33`) but no entry in the example config, and FR-25 makes 90 days a stated default worth exposing. |
| `backup.dir` | `lib/22_backup.sh:25`, `lib/24_report.sh:89` | `/opt/matrix/backups` | `[backup] dir = "/mnt/backups"` | Document it. Putting backups on a separate volume is the single most common reason to change a backup config. |
| `deploy.homeserver_timeout` | `lib/21_deploy.sh:64` | `180` | `[deploy] homeserver_timeout = 300` | Document it. The comment at `lib/21_deploy.sh:62-63` says first boot can take 90-150s on small VMs; users on slower hardware need this knob and cannot find it. |
| `coturn.tls` | `lib/19_compose.sh:147` | `false` | `[coturn] tls = true` | Ambiguous — `coturn_setup` computes TLS independently from whether a Caddy cert directory exists (`lib/14_coturn.sh:44-50`) and ignores this key, so the two disagree. Reconcile before documenting. |
| `proxy.external` | `lib/19_compose.sh:37` | `false` | `[proxy] external = true` | Internal, but see F-18 — it is currently the *only* working way to skip Caddy. Should become internal-only once F-18 is fixed. |
| `caddy.http_port`, `caddy.https_port` | set at `lib/09_proxy_detect.sh:47-48` | unset | written by the alternate-ports menu choice | Internal. Note they are written but never read — `templates/compose/caddy.yml:19-20` uses `{{PORT_HTTP}}`/`{{PORT_HTTPS}}` from constants, so choosing "Deploy Caddy on alternate ports (8080/8443)" has no effect on the deployed ports. Same class of defect as F-18; folded in there. |
| `database.init_args` | set at `lib/11_postgres.sh:81` | n/a | internal | Internal, correctly so. |
| `bridges.has_appservices`, `deploy.turn_result`, `network.ipv6`, `proxy.detected`, `*.image` | various | n/a | internal | Internal. `network.ipv6` and `proxy.detected` are read but never written — F-19 and F-18. |

Environment variables read at runtime and documented nowhere:

| Variable | Read at | Effect | Verdict |
| -------- | ------- | ------ | ------- |
| `MATRIX_ALLOW_AUR` | `lib/05_prerequisites.sh:104` | In headless mode, permits building an AUR helper and package from source; without it the Arch path refuses. | Document in README. It is required to complete a headless install on Arch when `podman-compose` is not in the official repos, and there is no way to discover it except from the error message. |
| `DEBUG` | `lib/01_utils.sh:31` | `DEBUG=true` enables `log_debug` output to stderr. | Document in README Troubleshooting — it is the first thing a user reporting a bug should be told to set. |
| `NO_COLOR` | `lib/00_constants.sh:82` | Disables ANSI colour, per no-color.org. | Correct behaviour, conventional; documenting is optional. |

CLI flags: `setup.sh` accepts exactly the eight options `README.md:84-91` documents, with
no hidden extras (`setup.sh:47-59`). No undocumented flag surface.

Phases: the 21 `run_phase` calls in `setup.sh:132-185` all correspond to a `lib/NN_*.sh`
module, and every numbered module is invoked. `lib/25_rollback.sh` and `lib/26_upgrade.sh`
are reached via `--rollback`/`--upgrade` rather than the main sequence, which
`README.md:94-112` describes. No orphan phases.

## Verified OK

| Claim | Source | Code | Status |
| ----- | ------ | ---- | ------ |
| 8 CLI flags parsed as documented | `README.md:84-91` | `setup.sh:47-59` | OK |
| 17 wizard steps | `README.md:59` | `lib/27_wizard.sh:15-31` | OK |
| `--generate-config` prints the example TOML | `README.md:67` | `lib/04_config.sh:230-232` (run, verified) | OK |
| `--rollback` / `--upgrade` entry points | `README.md:99,109` | `setup.sh:111-128` | OK |
| SIGINT offers rollback | `README.md:106`, spec:201 | `setup.sh:91-104` | OK |
| Four distro families dispatched (debian/rhel/arch/suse) | `README.md:42`, NFR-01 | `lib/02_detect.sh:44-55`, `lib/05_prerequisites.sh:225-256` | OK |
| Podman >= 4.4.0 enforced, 5.0.0 recommended | NFR-02 | `lib/00_constants.sh:22-23` | OK |
| FR-07 `.well-known/matrix/{server,client}` with Content-Type | spec:51 | `templates/configs/Caddyfile.tpl:30-41` | OK |
| NFR-13 all security headers + `-Server` + tailored CSP | spec:104 | `templates/configs/Caddyfile.tpl:14-24,90,104` | OK |
| FR-12 Coturn hardening, all directives | spec:56 | `templates/configs/turnserver.conf.tpl` | OK |
| FR-09 secrets via `openssl rand -base64 48`, chmod 600, umask 077, never logged | spec:53, `README.md:230` | `lib/08_secrets.sh:47-89` | OK (except Grafana — F-0A) |
| FR-10 `--podman-secrets` uses `podman secret create` | spec:54 | `lib/08_secrets.sh:92-122` | OK (but see F-02) |
| FR-13/FR-14 bridge plugin interface, 8 functions, `_` skip, Dendrite gating | spec:57-58, `README.md:127-142` | `bridges/*.sh`, `lib/16_bridges.sh:17-20,62` | OK |
| FR-17 admin registration: 3 retries, backoff, manual fallback, no secrets in argv | spec:61, spec:198 | `lib/21_deploy.sh:86-165` | OK (but unreachable — F-15) |
| FR-25 media retention 90d in homeserver config; 80%/90% disk alerts | spec:69 | `templates/configs/homeserver.synapse.yaml.tpl:67-68`, `lib/23_media_retention.sh:40-44` | OK (purge half — F-09) |
| FR-22 `pg_dump --format=custom`, `pg_restore --list` verify, signing-key artifact, timestamps, `--dry-run` | spec:66 | `lib/22_backup.sh:64-113,242-259` | OK (retention — F-11; key check — F-13) |
| FR-23 GPG and age backup encryption | spec:67 | `lib/22_backup.sh:120-135` | OK |
| FR-27 report contents, no secrets | spec:71 | `lib/24_report.sh:13-125` | OK |
| NFR-09 strict mode in every `.sh`, `-E` on entry point | spec:100 | all 40 `.sh` files, `setup.sh:17` | OK |
| NFR-10 all 17 images digest-pinned | spec:101, `docs/SUPPLY_CHAIN.md:7` | `lib/00_constants.sh:31-49` | OK |
| NFR-11 Postgres pinned to 16, `LC_COLLATE='C' LC_CTYPE='C'`, PG 13 minimum | spec:102 | `lib/00_constants.sh:24,33`, `lib/11_postgres.sh:81` | OK |
| SELinux `:Z` volume labels when enforcing | spec:184, `README.md:236` | `lib/19_compose.sh:20-21` | OK |
| Release pipeline: digest gate, SBOMs, keyless cosign bundles, SLSA provenance | `docs/SUPPLY_CHAIN.md:35-47` | `.github/workflows/release.yml:22-64` | OK |
| GitHub Actions SHA-pinned | `docs/SUPPLY_CHAIN.md:83` | `release.yml:18,27,33,50`, `ci.yml:15` | OK |
| README bridge image table matches constants | `README.md:118-125` | `lib/00_constants.sh:44-49` | OK |
| Version consistency (0.1.1) | `README.md:3`, `CHANGELOG.md:7`, `docs/SUPPLY_CHAIN.md:57` | `lib/00_constants.sh:7` | OK |
| Test commands work as documented | `README.md:216-224` | run: 300 passed / 0 failed | OK |

## Test-vs-prose conflicts

No case where a test and the prose assert *contradictory* behaviour. The recurring pattern
is weaker and worth naming: tests that assert a file exists rather than that it is used.

1. **`tests/test_templates.sh:96-98`** asserts `templates/configs/log.config.tpl` exists.
   No test asserts it is ever rendered, and it never is (F-00). The prose contract —
   `templates/configs/homeserver.synapse.yaml.tpl:42` plus the mount at
   `templates/compose/synapse.yml:16` — is the authority here; the test is satisfied by a
   state that breaks the deployment.
2. **`tests/test_compose_assembly.sh:60-63`** asserts every compose template contains a
   `services:` key — the precise property that makes the merge produce duplicate top-level
   keys (F-000). The test is not wrong about the templates; it just never assembles them,
   so it certifies the input to a step whose output is broken. The spec (FR-02) is
   authoritative and the assembled file does not satisfy it.
3. **`templates/hardening/fail2ban-matrix.conf.tpl:8`** carries the *correct* Synapse log
   path while the live heredoc at `lib/10_hardening.sh:221` carries a wrong one (F-04).
   The template is not a test, but it is the closest thing to a second opinion in the repo,
   and it disagrees with the code. The template is right.

Resolution in all three: prose/spec is authoritative; the tests are not wrong, they are
scoped to artefacts rather than to behaviour. Adding one assembly-level test and one
"rendered output" test would have caught F-000 and F-00 before this audit.

## Assumptions to challenge

- **Which side owns the "skip Caddy" decision.** FR-06 says the script "optionally skips
  Caddy deployment" without saying where that decision lives. The implementation splits it
  across `SKIP_CADDY` and `CONFIG[proxy.external]` and neither path works (F-18). Worth
  pinning in the spec: the decision is a config key, set by detection or by the user, read
  by compose assembly.
- **Whether `dns.cloudflare_api_token` means "create DNS records" or "use DNS-01".** The
  example TOML says both (`config/matrix-setup.example.toml:115`); FR-20 and the port-80
  edge case describe them as separate features with separate triggers. The code treats one
  token as consent to both (F-17). Two keys, or one key plus an explicit `acme_challenge`
  setting, would remove the ambiguity.
- **What `retention_daily` / `retention_weekly` mean.** The spec's "7 daily + 4 weekly"
  admits a tiered reading and a "keep 11" reading; the code took the second (F-11). The
  spec should state the retention algorithm, not just the numbers.
- **Whether the deploy-phase probes are meant to run on the host or in the container.**
  The spec's acceptance criteria are written from an external observer's view
  ("responds to `/_matrix/client/versions` over HTTPS", FR-02), while the code probes
  plain HTTP on host loopback (F-15). If the intent is host-side probing, the spec should
  say the homeserver port is published on loopback; if not, the code should probe through
  Caddy or `podman exec`.
- **Whether Arch is "supported" for the hardening baseline.** `README.md:42` lists Arch
  without qualification and NFR-06 makes auto-updates part of the baseline, but the code
  deliberately declines to configure them there (F-07). That is a defensible per-distro
  decision the documents do not record.

## Completion

**Status:** COMPLETE

**Findings:** CRITICAL: 4 | HIGH: 9 | MEDIUM: 8 | LOW: 3 — 24 total.

- CRITICAL: F-000 (compose merge discards all but one fragment), F-00 (`log.config` never
  rendered), F-0A (Grafana `admin`/`admin` on a public subdomain), F-15 (deploy probes an
  unpublished port)
- HIGH: F-01, F-02, F-04, F-05, F-09, F-10, F-11, F-17, F-18
- MEDIUM: F-03, F-06, F-07, F-12, F-13, F-14, F-16, F-19
- LOW: F-08, F-20, F-21

Four are documentation-side only, with no runtime difference: F-06 and F-20 are drift,
F-14 and F-21 are completeness. The other 20 have a user-observable difference, stated
in each finding's Impact.

**Confidence:** 19 findings at 5, five at 4 (F-00, F-07, F-09, F-15, F-17 — each limited
by not being able to run containers). None below 4, so no `UNCERTAIN:` labels were needed.
F-000 is at 5 because it was reproduced by running `compose_assemble` against a scratch
directory.

**Checked and clean** — see `## Verified OK` for the 28 claim areas confirmed conformant.

**Not checked, and why:**
- `lib/25_rollback.sh` and `lib/26_upgrade.sh` beyond their entry points. FR-24, FR-28,
  FR-29 and the upgrade claims at `README.md:94-112` (domain-change refusal, PG major
  version check) were not traced. Highest-value remaining area.
- `lib/06_user.sh`, `lib/20_quadlet.sh` in detail — NFR-05 (auto-start after reboot),
  NFR-12 (subuid/subgid) and `README.md:171-176` were not verified beyond confirming the
  modules run. A prior pass recorded subuid/linger as sound, but that was a different
  tree.
- `templates/snippets/` contents versus FR-06's requirement that they include
  `.well-known`, WebSocket upgrade and federation.
- `lib/15_webclient.sh`, `lib/17_admin_ui.sh` internals.
- NFR-01 in the sense the spec measures it ("script completes successfully on each distro
  in a clean VM") — no VM was available and the brief forbids running against the live
  system. Only package-manager dispatch was checked statically.
- NFR-03 (< 15 min), NFR-04 (SSL Labs grade A), NFR-06 (Lynis > 80), NFR-08 (container
  DNS): all require a running deployment.
- The three claims about external systems that this pass *did* verify are cited inline:
  `podman-run(1)` `--volume` on missing bind sources (F-00), the Caddy `admin` global
  option (F-16), and the official Caddy image's lack of DNS provider modules (F-17).
