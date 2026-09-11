# code-auditor report

**Target:** Matrix_Setup shell suite (52 `.sh` files, ~7.6k lines) on branch `qa/fleet-loop-20260910` — correctness and quality defects beyond the mechanical stage.
**Started:** 2026-09-10 (UTC)
**Status:** COMPLETE

## What works well

- **Input validation is deliberate and centralised.** `lib/04_config.sh:121-214` validates
  every config value that reaches a shell, SQL, JSON or arithmetic sink, with the sink named
  in a comment. Ports are regex-checked *before* `(( ))` so `x[$(cmd)]` can never reach
  arithmetic evaluation. Bridge names are constrained to `^[a-z][a-z0-9_]*$` specifically to
  stop `source`-based path traversal in `lib/16_bridges.sh`.
- **Secret handling in the admin-registration path is genuinely careful.**
  `lib/21_deploy.sh:132-165` passes the shared secret and admin password to `python3` via the
  environment, not argv, builds the JSON body with `json.dumps` rather than string
  interpolation, and posts via `--data @-`. Nothing sensitive lands in `/proc/<pid>/cmdline`
  or in a log line.
- **`get_user_home` (`lib/01_utils.sh:282-291`) resolves homes via `getent` rather than
  `eval ~$user`,** which is the correct fix for the class of bug that pattern usually has.
- **Images are pinned by digest, not tag** (`lib/00_constants.sh:31-49`), with a
  regeneration path and a CI `--check` mode.
- **`set -Eeuo pipefail` is applied consistently** across all 52 files, and `set -E` is used
  deliberately so the `ERR` trap survives function calls.
- **Bash version is checked before any 4.3+ syntax executes** (`setup.sh:23-27`) — the check
  itself uses only 3.x-compatible constructs, so it actually runs on the shell it rejects.
- **A real regression test suite exists** (`tests/test_security_regression.sh` in particular)
  and encodes past security fixes as assertions rather than comments.

## Findings

<!-- appended one at a time, as found -->

### [HIGH] The automatic rollback offer can never fire: the trap looks for a filename that is never created

- **Situation:** `setup.sh` installs an `ERR` trap (line 88) and a `SIGINT` trap (line 104)
  whose whole purpose is to offer the user a rollback when a phase fails partway through.
- **Behaviour:** `setup.sh:72` computes the manifest path as
  `"${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}/$MATRIX_SETUP_MANIFEST_FILE"`, i.e.
  `/opt/matrix/.rollback-manifest`. `setup.sh:95` does the same. But
  `lib/25_rollback.sh:13-14` creates the manifest with `mktemp`:
  `mktemp "${install_dir}/${MATRIX_SETUP_MANIFEST_FILE}.XXXXXXXXXX"` — the real file is
  `/opt/matrix/.rollback-manifest.a1B2c3D4e5`. Nothing in the repo ever creates
  `/opt/matrix/.rollback-manifest` (verified by grep: `MATRIX_SETUP_MANIFEST_FILE` appears
  only at `lib/00_constants.sh:9`, `lib/25_rollback.sh:13-14`, `setup.sh:72`, `setup.sh:95`).
  So `[[ -f "$manifest" ]]` is always false.
- **Trigger:** any phase failure after `rollback_init_manifest` — e.g. `postgres_setup`
  failing because the Postgres container will not start. The user sees
  "Setup failed at line N" and nothing else; the rollback branch is skipped entirely.
- **Impact:** the headline safety feature of the tool is inert. A failed run leaves modified
  `sshd_config`, firewall rules, sysctls, `/etc/subuid`, a created user and a partial
  container stack, and the user is never offered the undo and never even told a manifest
  exists.
- **Fix:** have `setup.sh` consult the live variable rather than re-deriving the path:
  `if [[ -n "${MANIFEST_FILE:-}" && -s "$MANIFEST_FILE" ]]; then`. Same at line 95. The
  `-s` test also avoids offering a rollback for an empty manifest.
- **Severity:** HIGH — **Confidence:** 5

### [HIGH] `setup.sh --rollback` is non-functional: it always reports "No rollback manifest found"

- **Situation:** `--rollback` is documented (`setup.sh:13`) as "Roll back the last setup run"
  and is the recovery path printed to the user at `setup.sh:81`.
- **Behaviour:** `main()` handles `--rollback` at `setup.sh:111-115`, calling
  `rollback_execute_all` directly. `MANIFEST_FILE` is still `""` (initialised at
  `lib/25_rollback.sh:7`) because `rollback_init_manifest` is only reached at `setup.sh:153`,
  forty lines later in a branch this mode never enters. No code anywhere discovers an
  existing manifest from disk. `rollback_execute_all` therefore takes the guard at
  `lib/25_rollback.sh:79-82`, logs "No rollback manifest found" and returns 1; `set -e` then
  aborts with the `ERR` trap firing on top.
- **Trigger:** `sudo bash setup.sh --rollback` in any state whatsoever.
- **Impact:** the documented manual recovery command does nothing. Combined with the finding
  above, there is no working path to a rollback at all — automatic or manual.
- **Fix:** add manifest discovery before executing, e.g. in `rollback_execute_all` (or a new
  `rollback_find_manifest`) select the newest match:
  `MANIFEST_FILE=$(ls -t "${install_dir}/${MATRIX_SETUP_MANIFEST_FILE}".* 2>/dev/null | head -1)`,
  and call it from the `--rollback` branch after `config_load` so `install_dir` is known.
  Note `--rollback` currently runs *before* `config_load` (line 111 vs 118), so a custom
  `install_dir` from the TOML is not in scope either; that ordering needs fixing too.
- **Severity:** HIGH — **Confidence:** 5

### [HIGH] Three rollback action types are emitted by production code but silently ignored by the executor

- **Situation:** `_rollback_action` (`lib/25_rollback.sh:93-159`) is a `case` over action
  types, with an `*)` arm that calls `log_debug` (invisible unless `DEBUG=true`).
- **Behaviour:** grep of every `rollback_snapshot` call site shows these types emitted by
  library code but absent from the `case`:
  - `FILE_MODIFIED` — `lib/06_user.sh:45` (`/etc/subuid`) and `lib/06_user.sh:51`
    (`/etc/subgid`)
  - `TIMER_INSTALLED` — `lib/22_backup.sh:345` and `lib/23_media_retention.sh:80`
    (systemd timer units)
  - `QUADLET_INSTALLED` — `lib/20_quadlet.sh:36` (the whole quadlet directory)
- **Trigger:** any successful rollback after the user-setup, backup, media-retention or
  quadlet phase has run. The entries are read, matched against `*)`, and dropped.
- **Impact:** rollback leaves behind subuid/subgid range allocations, enabled systemd
  timers that will fire backups and media purges against a stack that no longer exists, and
  quadlet unit files. The user is told "Rollback completed." (`setup.sh:78`). The silent
  `log_debug` means there is no diagnostic trail either.
- **Fix:** implement the three arms. At minimum, change the `*)` arm from `log_debug` to
  `log_warn "Unhandled rollback action '$action_type' — manual cleanup may be needed:
  $action_data"` so an unimplemented type is never silent. Note `FILE_MODIFIED` carries only
  the path, no backup — `lib/06_user.sh:45` needs to snapshot the file first (there is
  already `rollback_snapshot_file` for exactly this).
- **Severity:** HIGH — **Confidence:** 5

### [MEDIUM] The deploy phase records nothing in the rollback manifest

- **Situation:** every other stateful phase snapshots its changes; `lib/21_deploy.sh` does not
  (grep for `rollback_snapshot` in that file returns nothing).
- **Behaviour:** `deploy_run` pulls images (`:39`), starts the full compose stack as the
  matrix user (`:52`), and starts a rootful Coturn container or systemd unit (`:167-192`).
  None of it is recorded.
- **Trigger:** `_deploy_wait_for_homeserver` returning 1 (`lib/21_deploy.sh:84`) after the
  180s timeout — the stack is up but unhealthy. `deploy_run` propagates the failure, and a
  subsequent rollback removes config files out from under running containers.
- **Impact:** rollback deletes the compose file, Caddyfile and homeserver config while the
  containers they configure are still running, and leaves a running `matrix-coturn`
  container bound to host networking on ports 3478/5349 and the whole 49152-65535 range.
  Re-running `setup.sh` then hits port conflicts.
- **Fix:** record `SERVICE_STARTED`/a new `COMPOSE_UP` action before `_deploy_start_services`
  and before `_deploy_start_coturn`, and add a `COMPOSE_UP` arm to `_rollback_action` that
  runs `$COMPOSE_CMD -f "$compose_file" down` (plus `podman rm -f matrix-coturn`).
- **Severity:** MEDIUM — **Confidence:** 5

### [MEDIUM] `rollback_cleanup` is never called; manifests accumulate in the install directory

- **Situation:** `lib/25_rollback.sh:162-167` defines `rollback_cleanup` to remove the
  manifest after a successful run.
- **Behaviour:** grep shows no call site anywhere in `setup.sh`, `lib/` or `scripts/`.
  `main()` ends at `setup.sh:188-192` with `config_save_state` and a success message.
- **Trigger:** every successful run.
- **Impact:** because each run mktemps a *new* manifest, `/opt/matrix` accumulates one
  `.rollback-manifest.XXXXXXXXXX` per run. Each is a plaintext inventory of every system
  file the tool touched (sshd config, firewall rules, sysctl paths) with no explicit `chmod`
  — it inherits the `mktemp` default of 0600, so this is a clutter and
  operator-confusion problem rather than a disclosure one. It also makes the
  "newest manifest" discovery needed to fix `--rollback` ambiguous.
- **Fix:** call `rollback_cleanup` at the end of `main()` after `config_save_state`.
- **Severity:** MEDIUM — **Confidence:** 5

### [MEDIUM] A second, more correct error/interrupt handler exists and is dead

- **Situation:** `lib/25_rollback.sh:170-227` defines `rollback_offer`, `setup_error_trap`,
  `_on_error` and `_on_interrupt`.
- **Behaviour:** `setup_error_trap` has no call site (grep: definition only). `setup.sh`
  installs its own `trap_handler`/`trap_sigint` instead. So the four-option rollback menu the
  user never sees, and `CURRENT_PHASE` — set only in `lib/10_hardening.sh:6` — is read only
  by the dead `_on_error`.
- **Impact:** this is not merely dead code; the dead version is the better one.
  `_on_interrupt` (`:216-217`) checks `-s "$MANIFEST_FILE"` against the live variable, which
  is exactly the check `setup.sh:95` gets wrong. `rollback_offer` gives per-phase rollback
  and an explicit "leave state as-is" option that the live handler lacks. Whoever removed the
  call to `setup_error_trap` regressed the behaviour.
- **Fix:** decide which handler is canonical. Recommend deleting `trap_handler`/`trap_sigint`
  from `setup.sh` and calling `setup_error_trap` after `rollback_init_manifest`, then setting
  `CURRENT_PHASE` in `run_phase` (`setup.sh:196`) so `rollback_offer` gets a real phase name
  instead of `unknown`. Whichever way it goes, delete the loser.
- **Severity:** MEDIUM — **Confidence:** 5

### [CRITICAL] Re-running `setup.sh` on an existing install rewrites the homeserver config with the literal secrets `GENERATE_ME` and an empty DB password

- **Situation:** `secrets_generate_all` (`lib/08_secrets.sh:6-36`) is idempotent by design: if
  `$install_dir/.env` already exists it preserves the existing secrets and returns early.
- **Behaviour:** the early-return path (`lib/08_secrets.sh:13-19`) does
  `set -a; source "$env_file"; set +a`, which populates *environment variables*
  (`REGISTRATION_SHARED_SECRET`, `MACAROON_SECRET_KEY`, `FORM_SECRET`,
  `POSTGRES_PASSWORD`, `COTURN_SECRET`) — and nothing else. Every consumer reads the
  **`CONFIG` associative array**, not those names, and `CONFIG[secrets.*]` is only ever
  written by lines 22-27, which this path skips. The keys stay unset. Consequences,
  in the order the phases run:
  - `lib/11_postgres.sh:89` → `pg_pass=""`, so a host-mode `CREATE ROLE` gets
    `PASSWORD ''`.
  - `lib/12_homeserver.sh:166` → `registration_shared_secret: "GENERATE_ME"` in the
    rendered `homeserver.yaml` (template placeholder confirmed at
    `templates/configs/homeserver.synapse.yaml.tpl:79`).
  - `lib/12_homeserver.sh:41-42` → `macaroon_secret_key: "GENERATE_ME"` and
    `form_secret: "GENERATE_ME"` (template lines 123-124).
  - `lib/12_homeserver.sh:173` → `password: ""` in the database block (template line 34).
  - `lib/14_coturn.sh:29` → empty TURN shared secret.
  - `lib/21_deploy.sh:52` restarts the whole stack against this config.
  - `lib/21_deploy.sh:91` then reads `"${CONFIG[secrets.registration_shared_secret]}"`
    with **no `:-` default**; under `set -u` this is a hard
    `CONFIG[secrets.registration_shared_secret]: unbound variable` and the run dies.
    (Verified: bash aborts on an absent associative-array key under `set -u`.)
- **Trigger:** `sudo bash setup.sh --config prod.toml --headless` a second time against an
  existing `/opt/matrix` — the documented way to reconfigure or resume after a partial run.
- **Impact:** this is the worst outcome in the codebase. A working homeserver is
  reconfigured with a *publicly known* registration shared secret: `GENERATE_ME` is a string
  literal in this repository, so anyone who can reach
  `/_synapse/admin/v1/register` can mint admin accounts. The macaroon secret changing
  invalidates every existing access token; the empty DB password breaks the Postgres
  connection. The script then aborts before the deploy phase completes, and — per the two
  HIGH findings above — offers no rollback.
- **Fix:** in the preserve branch, map the sourced values back into `CONFIG` rather than
  relying on the environment:
  ```bash
  CONFIG[secrets.registration_shared_secret]="${REGISTRATION_SHARED_SECRET:-}"
  CONFIG[secrets.macaroon_secret_key]="${MACAROON_SECRET_KEY:-}"
  CONFIG[secrets.form_secret]="${FORM_SECRET:-}"
  CONFIG[secrets.postgres_password]="${POSTGRES_PASSWORD:-}"
  CONFIG[secrets.coturn_secret]="${COTURN_SECRET:-}"
  CONFIG[secrets.redis_password]="${REDIS_PASSWORD:-}"
  ```
  Then fail loudly if any came back empty. Separately, the `GENERATE_ME` fallbacks at
  `lib/12_homeserver.sh:41,42,166` should be removed: rendering a config with a known
  placeholder as a live secret must be a fatal error, not a default. And
  `lib/08_secrets.sh:29-33` has the same hole in `podman` secrets mode — an existing podman
  secret is preserved (`:110-113`) but never read back into `CONFIG` either.
- **Severity:** CRITICAL — **Confidence:** 5

### [HIGH] `--podman-secrets` mode produces a stack that cannot start; nothing ever reads the Podman secrets

- **Location:** `lib/08_secrets.sh:29-33`, `templates/compose/synapse.yml:25-26`,
  `templates/compose/dendrite.yml:20-21`, `templates/compose/postgres.yml:15`
- **Situation:** `secrets.mode = "podman"` (via `--podman-secrets` or the wizard at
  `lib/27_wizard.sh:407`) routes to `_store_podman_secrets` instead of `_store_env_file`.
- **Behaviour:** in that branch `$install_dir/.env` is **never created**. But the compose
  templates unconditionally declare `env_file: - {{INSTALL_DIR}}/.env`
  (`synapse.yml:26`, `dendrite.yml:21`) and `postgres.yml:15` reads
  `POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}`, which the compose tool interpolates from that
  file. No compose template contains a `secrets:` section or a `*_FILE` variable — grep for
  `secrets:` across `templates/compose/` returns nothing. `secrets.mode` is read in exactly
  two places: `lib/08_secrets.sh:29` (which store to write) and `lib/24_report.sh:58`
  (prose in the post-install report). Nothing wires the created secrets into a container.
- **Trigger:** `sudo bash setup.sh --podman-secrets ...`, or selecting "Podman secrets" in
  the wizard.
- **Impact:** the deploy fails when compose cannot open the declared `env_file`; if a compose
  implementation tolerates the missing file, Postgres starts with an empty password instead.
  Six Podman secrets are created, consume names in the user's secret store, are recorded in
  the rollback manifest — and are read by nothing. The feature is advertised on the
  command line (`setup.sh:10`), in the wizard, and in the post-install report.
- **Fix:** either wire it up — add `secrets:` blocks to the compose templates and switch the
  homeserver config to the `*_FILE` form Synapse supports — or remove the option from
  `setup.sh:52`, `lib/27_wizard.sh:406-407` and the report until it is implemented. A flag
  that silently breaks the install is worse than an absent one.
- **Severity:** HIGH — **Confidence:** 5

### [MEDIUM] `--podman-secrets` is silently overridden by the config file

- **Situation:** `setup.sh:52` handles `--podman-secrets` by setting
  `CONFIG[secrets.mode]="podman"` during argument parsing.
- **Behaviour:** argument parsing runs at `setup.sh:47-59`; `config_load` runs later at
  `setup.sh:118` and unconditionally overwrites `CONFIG` from the TOML
  (`lib/04_config.sh:19-21`: `CONFIG["$key"]="${TOML_VALUES[$key]}"`). A config file
  containing `[secrets] mode = "env"` therefore beats the command-line flag.
- **Trigger:** `sudo bash setup.sh --headless --config prod.toml --podman-secrets` where
  `prod.toml` sets `secrets.mode`.
- **Impact:** the operator believes secrets are held in Podman's secret store; they are
  instead written to `/opt/matrix/.env` in plaintext. Silent, with no warning. This inverts
  the normal precedence (CLI beats file) and the direction of the surprise is the insecure
  one.
- **Fix:** stash CLI overrides in a separate array during parsing and re-apply them after
  `config_load`, e.g. `declare -A CLI_OVERRIDES` at parse time, then
  `for k in "${!CLI_OVERRIDES[@]}"; do CONFIG["$k"]="${CLI_OVERRIDES[$k]}"; done` immediately
  after line 118.
- **Severity:** MEDIUM — **Confidence:** 5

### [MEDIUM] `config_save_state` writes `backup.encryption_key` and the reCAPTCHA private key to the state file despite the comment saying it does not

- **Location:** `lib/04_config.sh:244-250`
- **Situation:** the loop is guarded by a comment "Don't persist passwords/secrets in state"
  and a filter `case "$key" in *.password|*.secret*) continue ;; esac`.
- **Behaviour:** the glob catches `admin.password`, `smtp.password` and `secrets.*`, but not
  keys ending in `_key`. Two real config keys slip through:
  `backup.encryption_key` (validated at `lib/04_config.sh:108-112`, so it is a first-class
  supported setting) and `registration.recaptcha_private_key` (`lib/04_config.sh:82-83`).
- **Trigger:** any headless run with `backup.encryption = "gpg"` (or similar) and an
  encryption key set.
- **Impact:** the key that protects every backup archive is written in plaintext to
  `/opt/matrix/.matrix-setup.state`. The file is `chmod 600` (line 252), so this is not
  immediate disclosure, but it defeats the stated intent, and the state file is the kind of
  thing that gets copied into a support bundle or a config-management repo.
- **Also missed:** `dns.cloudflare_api_token` — a live key consumed by `lib/13_caddy.sh:87`
  and `lib/19_compose.sh:141`. It matches neither `*.password` nor `*.secret*`, so the
  Cloudflare API token, which can rewrite the operator's entire DNS zone, is written to the
  state file too.
- **Fix:** widen the filter to `*.password|*.secret*|*_key|*key|*token*` and, better, invert
  it to an allowlist of keys known to be safe to persist.
- **Severity:** MEDIUM — **Confidence:** 5

### [MEDIUM] Host-mode Postgres never resets the role password, so a regenerated secret locks the homeserver out

- **Location:** `lib/11_postgres.sh:104-114`
- **Situation:** `_postgres_host_setup` creates the role idempotently with
  `IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$pg_user')`.
- **Behaviour:** if the role already exists, the `CREATE ROLE ... PASSWORD` is skipped and
  no `ALTER ROLE ... PASSWORD` runs. But `CONFIG[secrets.postgres_password]` in that same
  run may be a *freshly generated* value — `lib/08_secrets.sh:25` regenerates it whenever
  `.env` is absent.
- **Trigger:** re-run after `/opt/matrix/.env` has been deleted or the install directory
  moved, with `database.mode = "host"` and the Postgres role already present. The new
  password goes into `homeserver.yaml`; the database still has the old one.
- **Impact:** the homeserver cannot authenticate to its database and fails to start. The
  failure surfaces as an opaque container crash-loop 180 seconds later at
  `lib/21_deploy.sh:82`, with nothing pointing at the password mismatch.
- **Fix:** add an `ELSE ALTER ROLE $pg_user WITH PASSWORD '$pg_pass_lit';` branch to the
  `DO $$` block so the role's password is always brought in line with the config.
- **Severity:** MEDIUM — **Confidence:** 4

### [MEDIUM] `deploy_run` reports success regardless of health-check results

- **Location:** `lib/21_deploy.sh:194-241`, called at `:31`
- **Situation:** `_deploy_health_checks` counts passes into `checks_passed`/`checks_total`.
- **Behaviour:** the function's last command is `log_substep "Health checks:
  $checks_passed/$checks_total passed"`, which always succeeds. The computed
  `checks_passed` is never compared against `checks_total` and never returned.
  `deploy_run` then unconditionally logs "Matrix stack deployed successfully" (`:33`) and
  `main()` goes on to print "Matrix Stack setup complete!" (`setup.sh:191`).
- **Trigger:** a homeserver that answers `/_matrix/client/versions` (so
  `_deploy_wait_for_homeserver` passes) but whose federation endpoint is broken, or a Coturn
  that is down. `0/2` is reported as success.
- **Impact:** the operator is told the install worked. This is a missing-use bug, not dead
  code — the counters exist precisely to gate the success message and nothing consumes them.
- **Fix:** `if (( checks_passed < checks_total )); then log_warn ...; return 1; fi`, or at
  minimum have `deploy_run` downgrade its final message to a warning. `CONFIG[deploy.turn_result]`
  (`:229,232,236`) *is* consumed — by `lib/24_report.sh` — so only the counters are orphaned.
- **Severity:** MEDIUM — **Confidence:** 5

### [LOW] `_deploy_start_coturn` swallows every failure and then claims success

- **Location:** `lib/21_deploy.sh:167-192`
- **Behaviour:** the compose fallback (`:180-181`) and the direct `podman run` (`:183-188`)
  both end in `|| true`, with stderr sent to `/dev/null`. Line 191 then logs
  "Coturn started" unconditionally.
- **Trigger:** port 3478 already bound by a system `coturn` package, or the image failing to
  pull.
- **Impact:** voice/video is silently broken. The `_deploy_health_checks` TURN test would
  catch it, but only when `turnutils_uclient` happens to be installed (`:224`) — otherwise it
  is skipped, and per the finding above the result is never acted on anyway.
- **Fix:** capture the exit status of the fallback chain and `log_warn` with the captured
  stderr when it fails, rather than `|| true` + an unconditional success line.
- **Severity:** LOW — **Confidence:** 5

### [LOW] Dendrite installs never get an admin account, and the manual fallback command names a Synapse container

- **Location:** `lib/21_deploy.sh:87-124`, reached unconditionally from `deploy_run:23`
- **Behaviour:** `_deploy_create_admin` posts to
  `http://localhost:8008/_synapse/admin/v1/register` (`:92`), a Synapse-only endpoint.
  Dendrite has no such route, so all three attempts fail across ~15s of `sleep`. The advice
  printed at `:121-122` is
  `podman exec -it matrix-synapse register_new_matrix_user -c /data/homeserver.yaml ...`,
  naming a container and a config file that do not exist on a Dendrite deployment (Dendrite
  uses `create-account` against `dendrite.yaml`).
- **Trigger:** `homeserver.type = "dendrite"` with an `admin.password` set.
- **Impact:** no admin account, 15s of pointless retries, and recovery instructions that
  cannot work. Note `config_validate` already forbids bridges and the admin UI on Dendrite
  (`lib/04_config.sh:61-70`), so the Dendrite path is a supported configuration, not a
  degenerate one.
- **Fix:** branch on `${CONFIG[homeserver.type]}` and either use Dendrite's
  `create-account` binary or skip with an explicit, Dendrite-correct instruction.
- **Severity:** LOW — **Confidence:** 4

### [LOW] `--help` prints two lines of source code

- **Location:** `setup.sh:56`
- **Behaviour:** `head -17 "$0" | tail -14` selects lines 4-17. Lines 4-14 are the intended
  usage block, but line 15 is a bare `#`, line 16 is `# shellcheck disable=SC2154` and line
  17 is `set -Eeuo pipefail`.
- **Impact:** `setup.sh --help` ends with a shellcheck directive and a `set` command
  presented as documentation. Cosmetic, but this is the first thing a new user sees, and the
  line arithmetic will drift again the next time the header changes.
- **Fix:** replace the line arithmetic with a `sed -n '/^# Usage:/,/^$/p' "$0"` range, or
  simply a `cat <<'USAGE'` heredoc that cannot drift.
- **Severity:** LOW — **Confidence:** 5

### [LOW] Dead local in `_deploy_start_services`

- **Location:** `lib/21_deploy.sh:50`
- **Behaviour:** `local matrix_user="${CONFIG[matrix_user]:-$DEFAULT_MATRIX_USER}"` is
  computed and never referenced. `run_as_user` (`lib/01_utils.sh:274-277`) derives the same
  value internally, so this is genuine dead code rather than a missing use — there is no
  call in the function that should have received it.
- **Fix:** delete the line.
- **Severity:** LOW — **Confidence:** 5

### [HIGH] The pure-Bash TOML fallback is unreachable, and a config file that fails the Python path kills `setup.sh` with no output at all

- **Location:** `lib/03_toml_parser.sh:25` and `:89-96`
- **Situation:** the file header promises "Tries Python 3.11+ tomllib first, falls back to
  pure-Bash subset parser", and `toml_parse_file:25-32` is written to do exactly that.
- **Behaviour:** `_toml_parse_python:90` does `output=$(python3 -c "$py_script" "$file")`.
  When `python3` is absent, is older than 3.11 (no `tomllib`), or the file fails to parse,
  the assignment fails. Because the function is invoked inside an `if` condition, `set -e` is
  suspended, so execution continues into the `while` loop at `:92` with `output=""`.
  A here-string of an empty value still yields **one empty line**, so `read` succeeds once,
  `key=""`, and line 95 executes `TOML_VALUES[""]=""`. An empty associative-array subscript
  is a bash *assignment error*: `bad array subscript`, which is **fatal in a
  non-interactive shell regardless of `set -e` and regardless of being inside an `if`
  condition**. The shell exits immediately. The `2>/dev/null` on line 25 swallows both the
  Python traceback and the bash error, so nothing whatsoever is printed.
- **Trigger (verified two ways, both reproduced):**
  1. `setup.sh --headless --config prod.toml` where `prod.toml` has a syntax error — e.g.
     a missing `]` on a table header. Observed: script prints nothing, exits 1, `ERR` trap
     does not fire.
  2. A **valid** config file on any host without Python 3.11+ (Debian 11, RHEL 8, Ubuntu
     20.04, or a minimal container). Same silent exit 1. Reproduced by stubbing `python3` to
     return 127.
- **Impact:** two separate failures. The advertised Bash fallback has never run — 
  `_toml_parse_bash` (`:123-168`) is effectively dead code, which also means it is
  untested against real configs in production use. And the failure mode is the worst
  possible for an installer: silent exit with no diagnostic, so the operator has nothing to
  search for. Note the fallback is only *accidentally* prevented from being wrong here —
  the thing that stops `_toml_parse_python` returning success on an empty parse is the
  fatal subscript error, not any deliberate check.
- **Fix:** check the Python invocation's status explicitly and skip empty lines:
  ```bash
  local output
  if ! output=$(python3 -c "$py_script" "$file" 2>&1); then
      log_debug "tomllib backend unavailable or file rejected: $output"
      return 1
  fi
  while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      TOML_VALUES["${line%%=*}"]="${line#*=}"
  done <<< "$output"
  ```
  and drop the `2>/dev/null` at `:25` so a genuine parse error is reportable. `toml_parse_file`
  should also distinguish "python missing" (fall back) from "file is malformed" (fail loudly)
  — falling back to the lenient Bash parser on a syntactically invalid file will produce a
  half-parsed config, which is how `domain.name` ends up mysteriously missing.
- **Severity:** HIGH — **Confidence:** 5

### [LOW] The Python TOML backend corrupts any value containing a newline

- **Location:** `lib/03_toml_parser.sh:85` (`print(f"{k}={v}")`) consumed by `:92-96`
- **Behaviour:** the bridge between Python and bash is a line-oriented `KEY=VALUE` stream
  with no escaping. A TOML multi-line string (`"""..."""`) — legal TOML, and the natural way
  to write a `backup.encryption_key` or an SSH key — emits its embedded newlines verbatim.
  Each continuation line is then parsed by `:93-94` as its own key/value pair, with
  `key="${line%%=*}"` set to the entire line when it contains no `=`.
- **Impact:** silent config corruption: the real key gets a truncated value and junk keys
  appear in `CONFIG`. No error is raised. Low because no current documented setting is
  multi-line, but nothing prevents one.
- **Fix:** emit `json.dumps` of the flat dict from Python and read it back with a
  null-delimited stream, or at minimum `print(f"{k}={v}")` → base64-encode the value and
  decode in bash.
- **Severity:** LOW — **Confidence:** 4

### [INFO] `_toml_strip_comment` forks a subshell per quote character

- **Location:** `lib/03_toml_parser.sh:109` and `:111`
- **Behaviour:** `in_dquote=$( [[ "$in_dquote" == true ]] && echo false || echo true )`
  spawns a subshell for every `"` or `'` in the input, inside a per-character loop that is
  itself inside a per-line loop.
- **Impact:** correctness is fine; this is pure overhead — a 100-line config with two quotes
  per line forks ~200 processes. Only reached via the (currently unreachable) Bash fallback,
  which is why it has never been noticed.
- **Fix:** `if [[ "$in_dquote" == true ]]; then in_dquote=false; else in_dquote=true; fi` — no fork.
- **Severity:** INFO — **Confidence:** 5

### [CRITICAL] Compose assembly concatenates fragments that each declare a top-level `services:` key, so the generated stack is either rejected or silently reduced to one container

- **Location:** `lib/19_compose.sh:61-71` (the merge) and `:93` (the write)
- **Situation:** `compose_assemble` builds `podman-compose.yml` by rendering each fragment
  and appending it to a string: `merged+=$'\n'"$rendered"`. There is no YAML-aware merge.
- **Behaviour:** every service fragment in `templates/compose/` begins with its own top-level
  `services:` key (verified: `admin.yml:4`, `caddy.yml:4`, `coturn.yml:6`, `dendrite.yml:4`,
  `monitoring.yml:4`, `postgres.yml:4`, `synapse.yml:4`, `webclient.yml:4`).
  `monitoring.yml:48` adds a second top-level `volumes:` on top of `base.yml:8`. Plain
  concatenation therefore emits a single YAML document with the `services` mapping key
  repeated once per enabled service.
- **Trigger:** a default install — Postgres in a container, Synapse, Caddy, a web client and
  the admin UI. I reproduced the exact merge (same fragment order as `:25-49`) and parsed the
  result:
  - `top-level 'services:' count: 5`
  - PyYAML (`podman-compose`'s parser, last-key-wins): the parsed `services` mapping
    contains **only `synapse-admin`**. Postgres, Synapse, Caddy and the web client are
    silently discarded.
  - `compose-go` (what `podman compose` and `docker compose` use, and `COMPOSE_CMD`'s
    default per `lib/02_detect.sh:173`) rejects duplicate mapping keys outright.
- **Impact:** the deployment either fails to start with a YAML error, or — worse, on
  `podman-compose` — starts a single admin-UI container and nothing else. The next phase
  waits 180s for a homeserver that was never in the file
  (`lib/21_deploy.sh:68-84`). This is the core artefact the entire tool exists to produce.
- **Aggravating factor:** `lib/19_compose.sh:100-104` runs `$COMPOSE_CMD -f "$compose_file"
  config --quiet 2>/dev/null` and, on failure, logs
  "Compose file validation returned warnings (may still work)". The one check that would
  catch this is downgraded to a warning with its stderr discarded.
- **Why this was not caught:** `tests/test_compose_assembly.sh` never calls
  `compose_assemble`. All 79 lines grep the individual template files; the merge itself has
  no test.
- **Fix:** strip the leading `services:` line from every fragment except the first that
  contributes one (or, better, remove `services:` from the fragments entirely and have
  `compose_assemble` emit it once before the loop, indenting fragment bodies accordingly).
  Same for the duplicate `volumes:` in `monitoring.yml`. Then make `:100` fatal:
  `if ! $COMPOSE_CMD -f "$compose_file" config --quiet; then log_error ...; return 1; fi` —
  a compose file that does not parse is never "may still work". And add a test that runs
  `compose_assemble` and asserts exactly one top-level `services:` key.
- **Severity:** CRITICAL — **Confidence:** 5

### [HIGH] The `matrix-stack.container` Quadlet unit has no `Image=` and cannot generate a service

- **Location:** `lib/20_quadlet.sh:45-65`
- **Situation:** `_quadlet_generate_compose` writes two units. The second
  (`matrix-compose.service`, `:72-93`) is a well-formed plain systemd unit and carries a
  comment explaining why it is not a Quadlet. The first is a `.container` Quadlet source with
  a `[Container]` section containing only `ContainerName=matrix-stack` and
  `PodmanArgs=--userns=keep-id`.
- **Behaviour:** Podman's Quadlet documentation states of `[Container]`: "There is only one
  required key, `Image`, which defines the container image the service runs" (checked against
  `podman-systemd.unit(5)`, latest). With neither `Image=` nor `Rootfs=`, the generator
  cannot produce a `.service` and errors.
- **Trigger:** every install. `run_as_user systemctl --user daemon-reload` at `:30` runs the
  generator, and its output is discarded by `2>/dev/null || true`.
- **Impact:** a permanently broken generator entry that logs an error on every user
  `daemon-reload` for the life of the machine, and a `matrix-stack.service` the operator will
  look for and never find. The real auto-start path is `matrix-compose.service`, so the stack
  does still come up on boot — this is a stale, non-functional unit rather than a total
  failure, which is why it has gone unnoticed.
- **Fix:** delete the `matrix-stack.container` heredoc. Nothing references it (grep:
  `matrix-stack` appears only here and in `lib/24_report.sh` prose). If a Quadlet source was
  genuinely intended, it needs `Image=` and per-service units, which duplicates what the
  compose wrapper already does.
- **Severity:** HIGH — **Confidence:** 4 (verified against upstream documentation; not
  executed, as that needs a live systemd user session)

### [LOW] `~/.config`, `~/.local` and `~/.local/share` are left owned by root in the matrix user's home

- **Location:** `lib/06_user.sh:92-97` (primary), `lib/20_quadlet.sh:18` and `:95`
  (same pattern)
- **Behaviour:** `_setup_xdg_dirs` runs `mkdir -p "$dir"` as root for
  `$home/.config/containers`, `$home/.config/containers/systemd`,
  `$home/.config/systemd/user` and `$home/.local/share/containers`, then chowns **only the
  leaf**. The intermediate `$home/.config`, `$home/.config/systemd`, `$home/.local` and
  `$home/.local/share` are created `root:root` and never chowned — none of them appears in
  the `dirs` array. `lib/20_quadlet.sh:18` repeats the pattern.
- **Trigger:** any install where the matrix user was freshly created by `_create_user`
  (`lib/06_user.sh:29`), so `--create-home` gave it a home with no `.config`. That is the
  default path.
- **Impact:** the specific directories rootless Podman and `systemctl --user` need *are*
  chowned, so the install is not immediately broken — this is why it has gone unnoticed.
  It bites when anything tries to create a **new** top-level entry under `~/.config` or
  `~/.local/share` as the matrix user: a Podman version that adds a new state directory, a
  `systemctl --user enable` writing outside `systemd/user`, or an operator debugging by hand.
  The failure is a bare `Permission denied` in a home directory the user nominally owns.
- **Fix:** run the `mkdir -p` through `run_as_user` in both places so the whole chain gets
  the right owner, and drop the follow-up `chown`. Do not `chown -R` the home directory —
  that would clobber ownership if the user pre-existed.
- **Severity:** LOW — **Confidence:** 4

### [LOW] `_compose_render_fragment` and `template_render` are near-identical copies that have diverged in their sed escaping

- **Location:** `lib/19_compose.sh:182` vs `lib/01_utils.sh:235`
- **Behaviour:** both build a `sed "s|{{KEY}}|${escaped_val}|g"` replacement, so a `|` in a
  value must be escaped. `lib/01_utils.sh:235` escapes `[&/\|]`; `lib/19_compose.sh:182`
  escapes only `[&/\]`, omitting the delimiter itself.
- **Trigger:** any compose template variable whose value contains `|`. The reachable one is
  `CONFIG[webclient.image]` (`lib/19_compose.sh:151`), which is operator-supplied and — unlike
  `install_dir`, `domain.name` and the identifiers — is **not** validated by
  `config_validate`.
- **Impact:** `sed: -e expression #1, char N: unterminated 's' command`, aborting the
  phase with a message that does not name the config key responsible. Not an injection
  (sed's `s` replacement text cannot execute commands) but a confusing hard failure.
- **Fix:** add `|` to the character class at `lib/19_compose.sh:182` so it matches
  `lib/01_utils.sh:235`. Better: these two functions are a copy-paste pair differing only in
  that character class — collapse `_compose_render_fragment` into a call to
  `template_render` writing to stdout.
- **Severity:** LOW — **Confidence:** 4

### [LOW] `template_render` cannot handle a value containing a newline

- **Location:** `lib/01_utils.sh:233-237` (and its twin `lib/19_compose.sh:180-184`)
- **Behaviour:** the replacement text is interpolated into a single-line
  `sed "s|{{KEY}}|${escaped_val}|g"` script. The escaper handles `&`, `/`, `\` and `|` but
  not a literal newline, which terminates the `s` command.
- **Trigger:** any multi-line template value. None is reachable today — every value is a
  base64 secret, a validated identifier or a path — but `smtp.password`,
  `webclient.image` and `dns.cloudflare_api_token` all flow in unvalidated from the TOML, and
  the TOML parser will happily produce a multi-line value (see the LOW finding on the Python
  backend). Combined, an operator's multi-line TOML string reaches this sed.
- **Fix:** drive the substitution from a here-doc-fed `awk` using `ENVIRON[]` (the technique
  already used correctly at `lib/12_homeserver.sh:224-227`) rather than building a sed
  script.
- **Severity:** LOW — **Confidence:** 3

### [CRITICAL] `log.config` is never rendered, so the Synapse container bind-mounts a directory over its logging config and the homeserver cannot start

- **Location:** `lib/12_homeserver.sh:97` (the orphaned value),
  `templates/configs/log.config.tpl` (the template with no caller),
  `templates/compose/synapse.yml:16` (the mount),
  `templates/configs/homeserver.synapse.yaml.tpl:42` (the consumer)
- **Situation:** `_homeserver_synapse` sets `hs_vars[LOG_FILE_PATH]="/data/logs/homeserver.log"`
  and creates `$data_dir/logs`. `homeserver.yaml` declares `log_config: "/data/log.config"`.
  The compose fragment mounts
  `{{INSTALL_DIR}}/config/log.config:/data/log.config:ro`.
- **Behaviour:** `templates/configs/log.config.tpl` exists and contains
  `filename: {{LOG_FILE_PATH}}` at line 11 — but **nothing ever renders it**. Grep for
  `log.config` across the repo returns the template, the compose mount, the `log_config:`
  line, and one test that only checks the file exists
  (`tests/test_templates.sh:96`). There is no `template_render` call for it.
  `$install_dir/config/log.config` therefore never exists.
  `hs_vars[LOG_FILE_PATH]` is passed only to `homeserver.synapse.yaml.tpl`, which contains
  no `{{LOG_FILE_PATH}}` placeholder — so the value is computed, consumed by nothing, and
  the render call it was computed *for* was never written. This is a missing use, not dead
  code.
- **Trigger:** every Synapse install.
- **Impact:** Podman bind-mounting a host path that does not exist creates it as an empty
  **directory**. Synapse then opens `/data/log.config` to load its logging config and gets a
  directory. Either way — directory-created or mount refused — Synapse fails to start,
  `_deploy_wait_for_homeserver` burns its full 180s timeout (`lib/21_deploy.sh:68-84`), and
  the install fails with "Homeserver did not become ready", which points nowhere near the
  cause. Downstream, `$install_dir/data/logs/homeserver.log` is never produced, so the
  fail2ban jail has nothing to read either.
- **Fix:** render the template in `_homeserver_synapse`, alongside the existing
  `homeserver.yaml` render:
  ```bash
  template_render "${SCRIPT_DIR}/templates/configs/log.config.tpl" \
                  "$config_dir/log.config" hs_vars
  rollback_snapshot "homeserver" "FILE_CREATED" "$config_dir/log.config"
  ```
  Add a test that asserts `config/log.config` exists after `homeserver_setup`, since the
  existing template test only checks the `.tpl` is present.
- **Severity:** CRITICAL — **Confidence:** 5

### [HIGH] The fail2ban jail watches a log path that is never written

- **Location:** `lib/10_hardening.sh:221`
- **Situation:** `harden_fail2ban` writes `/etc/fail2ban/jail.d/matrix.conf` with
  `logpath = $install_dir/data/synapse/homeserver.log`.
- **Behaviour:** the homeserver phase puts logs somewhere else. `lib/12_homeserver.sh:97-98`
  sets the in-container path to `/data/logs/homeserver.log` and creates
  `$data_dir/logs` — i.e. host path `$install_dir/data/logs/homeserver.log`.
  `templates/compose/synapse.yml:19` mounts `{{INSTALL_DIR}}/data/logs:/data/logs`
  accordingly. `$install_dir/data/synapse/` is created by nothing in this repo (grep:
  `data/synapse` appears only at `lib/10_hardening.sh:221`).
- **Trigger:** every install with `hardening.fail2ban` enabled — the default
  (`lib/04_config.sh:281`).
- **Impact:** fail2ban cannot open the logpath, so the `matrix-synapse` jail does not start.
  `systemctl enable --now fail2ban` and `systemctl restart fail2ban` at `:243-244` both end
  in `2>/dev/null || true`, so the failure is invisible and `harden_all` still logs
  "Server hardening complete". The operator believes Matrix login brute-force protection is
  active when it is not. (The `[sshd]` jail in the same file has no `logpath` and does still
  work.)
- **Fix:** change `:221` to `logpath = $install_dir/data/logs/homeserver.log`, and stop
  swallowing the fail2ban service status — `systemctl restart fail2ban` failing should be a
  `log_error`, not `|| true`.
- **Severity:** HIGH — **Confidence:** 5

### [HIGH] The nftables firewall fallback applies a default-drop policy that only permits port 22, locking out operators on a non-standard SSH port

- **Location:** `lib/10_hardening.sh:160-187`
- **Situation:** `harden_ssh` goes to considerable trouble not to lock the operator out
  (`:44-52`: it refuses to disable password auth unless a key is installed). The firewall
  path has no equivalent care.
- **Behaviour:** `_harden_nftables` writes a ruleset with
  `type filter hook input priority 0; policy drop;` and hardcodes
  `tcp dport { 22, 80, 443, ... } accept` (`:165`, `:169`). It then applies it immediately
  with `nft -f "$nft_file"` (`:184`). Because nftables evaluates every table, a drop in
  `matrix_filter` drops the packet regardless of what other tables allow.
- **Trigger:** a host with neither `ufw` nor `firewall-cmd` (so the `nft` fallback is
  selected at `:85-86`) and `sshd` listening on a port other than 22 — a common
  hardening choice, and exactly the kind of host this tool targets.
- **Impact:** the operator's SSH session is cut mid-install with no recovery short of
  console access. Nothing in the repo reads the configured SSH port (grep: no `sshd_config`
  `Port` parsing anywhere), so the value is assumed rather than detected.
- **Fix:** parse the active port(s) before generating the ruleset —
  `ss -tlnp | awk '/sshd/ {…}'` or `sshd -T | awk '/^port /{print $2}'` — and emit an
  `accept` for each; fall back to 22 only if detection yields nothing. Apply the same
  detection to the `ufw`/`firewalld` port lists at `:101` and `:130`, which hardcode 22 too.
  Consider `nft -f` with a commit-confirm pattern (apply, wait for the operator to confirm
  connectivity, roll back on timeout).
- **Severity:** HIGH — **Confidence:** 5

### [MEDIUM] The fail2ban filter would ban successful logins, and its patterns do not match Synapse's log format

- **Location:** `lib/10_hardening.sh:235-241`
- **Behaviour:** the first `failregex` is
  `^.* Received request: POST /_matrix/client/.*/login.*from <HOST>.*$`. "Received request"
  is Synapse's *access log* line, emitted for every request — success or failure. Paired
  with `maxretry = 5` / `findtime = 300` (`:222-223`), five **successful** logins from one
  address in five minutes earns a one-hour ban. A NAT'd office or a client re-authenticating
  after a token refresh trips it.
- **UNVERIFIED:** I could not confirm against a running Synapse whether any of the three
  patterns matches at all. Synapse's default access-log line places the client address
  *before* the "Received request" text rather than after it as `from <HOST>`, and uses
  ` - synapse.rest.client.login - ` rather than the `[synapse.rest.client.login]` bracket
  form the third pattern expects. If that reading is right, the filter never matches
  anything and the jail is inert rather than harmful. Confirming needs a real Synapse log
  sample, which I did not have.
- **Impact:** either a self-inflicted denial of service against legitimate users, or a
  security control that silently does nothing. Both are bad, and which one it is has never
  been established.
- **Fix:** validate the filter with `fail2ban-regex <sample.log> /etc/fail2ban/filter.d/matrix-synapse.conf`
  against a real Synapse log before shipping, and key the patterns on failure-only lines
  (`Attempted to login as ... but they do not exist`, HTTP 403 responses on the login
  endpoint). Add a `fail2ban-regex` check to CI with a checked-in log fixture.
- **Severity:** MEDIUM — **Confidence:** 3

### [MEDIUM] `harden_ssh` reverts by deleting the config file, discarding an existing one it had just backed up

- **Location:** `lib/10_hardening.sh:70-75`
- **Behaviour:** `rollback_snapshot_file "$CURRENT_PHASE" "$ssh_conf"` at `:55` copies any
  existing `99-matrix-hardening.conf` to `<file>.pre-matrix.<epoch>` before overwriting it.
  If `sshd -t` then fails, the revert at `:74` is a bare `rm -f "$ssh_conf"` — the backup is
  never restored.
- **Trigger:** a re-run on a host that already has the file (from a previous successful run)
  where `sshd -t` now fails for an unrelated reason — a bad directive added by hand, or a
  distro sshd that rejects `AuthenticationMethods` in a drop-in.
- **Impact:** the previously working hardening config is deleted, silently downgrading the
  host's SSH posture. The `.pre-matrix.<epoch>` copy survives on disk, so nothing is
  unrecoverable, but the operator is not told and the running config has changed.
- **Fix:** restore rather than remove — track the backup path returned by the snapshot and
  `mv` it back, or `rm -f` only when there was no pre-existing file.
- **Severity:** MEDIUM — **Confidence:** 4

### [MEDIUM] `harden_ssh`'s lockout guard can be satisfied by a key belonging to an unrelated user

- **Location:** `lib/10_hardening.sh:22-37`, gating `:47-52`
- **Behaviour:** `_ssh_has_authorized_key` returns 0 if *any* non-comment line exists in
  `/root/.ssh/authorized_keys{,2}` or `/home/*/.ssh/authorized_keys{,2}`. It does not check
  that the key belongs to an account that can actually log in, nor does it consult
  `sshd -T` for the effective `AuthorizedKeysFile` (which may point elsewhere, e.g.
  `/etc/ssh/authorized_keys/%u`).
- **Trigger:** a host where a service account under `/home` has a stale
  `authorized_keys` (a deploy key, a decommissioned CI user) but the operator logs in as
  root with a password. The guard passes, `PasswordAuthentication no` and
  `PermitRootLogin no` are applied, and `sshd -t` succeeds because the syntax is valid.
- **Impact:** the operator is locked out of the box — the exact outcome the guard exists to
  prevent. The comment at `:44-46` asserts the check is sufficient; it is not.
- **Fix:** resolve the effective `AuthorizedKeysFile` via `sshd -T`, and require a key for an
  account with a login shell and a non-locked password entry. Failing that, verify the key
  belongs to the invoking user: `SUDO_USER` is available and is the account the operator is
  actually using.
- **Severity:** MEDIUM — **Confidence:** 4

### [MEDIUM] SSH hardening is a silent no-op on distros whose `sshd_config` has no `Include`

- **Location:** `lib/10_hardening.sh:41-75`
- **Behaviour:** the config is written to `/etc/ssh/sshd_config.d/99-matrix-hardening.conf`.
  That directory is only read if the main `/etc/ssh/sshd_config` contains
  `Include /etc/ssh/sshd_config.d/*.conf`. OpenSSH added `Include` in 8.2 and distros
  adopted it at different times; RHEL/CentOS 7, Debian 10 and Amazon Linux 2 ship configs
  without it. The code never checks.
- **Consequence:** `sshd -t` at `:70` passes (it validates the main config, which the
  drop-in is not part of), `systemctl reload sshd` succeeds, and the phase reports success —
  while `PasswordAuthentication` is still `yes`.
- **Impact:** requested hardening silently not applied, with a success message. Note this is
  the *safe* direction with respect to lockout, so it will not be noticed operationally; it
  will be noticed by whoever audits the box.
- **Fix:** `grep -q '^[[:space:]]*Include[[:space:]]\+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config`
  before writing; if absent, either append the `Include` line (with a backup and an
  `sshd -t`) or `log_warn` that the drop-in will not take effect. Better: verify the outcome
  with `sshd -T | grep -i passwordauthentication` after the reload rather than assuming.
- **Severity:** MEDIUM — **Confidence:** 4 (the `Include` mechanism and its version history
  are documented OpenSSH behaviour; I did not test on each distro)

### [LOW] Rolling back sysctl hardening removes the file but leaves the kernel values applied

- **Location:** `lib/10_hardening.sh:247-280`, with `_rollback_action`'s `FILE_CREATED` arm
  at `lib/25_rollback.sh:98-103`
- **Behaviour:** `harden_sysctl` writes eleven settings to `/etc/sysctl.d/99-matrix.conf`
  and applies them with `sysctl --system`. It snapshots the *previous values* of exactly two
  of them (`:254-255`). On rollback, `FILE_CREATED` deletes the file but never re-runs
  `sysctl --system`, and `SYSCTL_SET` restores only those two keys.
- **Impact:** after a "completed" rollback, the live kernel still has the other nine
  settings applied — including `net.ipv4.ip_unprivileged_port_start=80`, which is a
  *relaxation* (any unprivileged user on the host may bind ports 80-1023) sitting in a file
  called "sysctl hardening". It persists until the next reboot with no record that
  matrix-setup put it there.
- **Fix:** snapshot all eleven keys with `rollback_snapshot_sysctl`, and have the
  `FILE_CREATED` arm re-run `sysctl --system` when the removed path is under
  `/etc/sysctl.d/`.
- **Severity:** LOW — **Confidence:** 4

### [LOW] `_setup_subuid` checks only for the presence of a subuid entry, not the range the comment requires

- **Location:** `lib/06_user.sh:41-52`
- **Behaviour:** the comment reads "Check if user has subuid/subgid entries **with at least
  65536 range**", but the test is `grep -q "^${user}:" /etc/subuid` — presence only. The
  range is never parsed.
- **Trigger:** a pre-existing user with a narrow allocation, e.g. `matrix:100000:1000` from
  an earlier tool or a hand-edited `/etc/subuid`.
- **Impact:** `usermod --add-subuids` is skipped, and rootless Podman later fails to map the
  container's UID range with `there might not be enough IDs available in the namespace`.
  Nothing connects that error back to this check.
- **Fix:** parse the third field and compare: `awk -F: -v u="$user" '$1==u && $3>=65536'`.
  The comment already specifies the intended behaviour, so this is a missing implementation
  rather than a design question.
- **Severity:** LOW — **Confidence:** 5

### [LOW] `harden_fail2ban` writes jail files for a fail2ban it may not have installed

- **Location:** `lib/10_hardening.sh:201-208`
- **Behaviour:** the install `case "$OS_FAMILY"` has arms for `debian`, `rhel`, `arch` and
  `suse` and **no `*)` default**. On any other family (`OS_FAMILY` is set by
  `lib/02_detect.sh`, and defaults to something outside that set on an unrecognised distro)
  the install is skipped silently, then `:216` and `:235` write jail and filter files into
  `/etc/fail2ban/` regardless, and `:243-244` swallow the `systemctl` failures.
- **Impact:** the phase reports success having installed nothing and configured nothing.
  Stray files are left in `/etc/fail2ban/` on a host with no fail2ban.
- **Fix:** add `*) log_warn "No fail2ban package known for OS family '$OS_FAMILY'"; return 0 ;;`
  and re-check `check_command fail2ban-server` after the install attempt before writing
  any config.
- **Severity:** LOW — **Confidence:** 4

### [CRITICAL] The install directory is entirely root-owned but every container runs rootless as the matrix user

- **Location:** `lib/12_homeserver.sh:14`, `lib/08_secrets.sh:87`, `lib/22_backup.sh:48,154`,
  and the mounts in `templates/compose/synapse.yml:17-19,26`
- **Situation:** the whole point of the design is rootless Podman — `lib/21_deploy.sh:52`
  brings the stack up with `run_as_user`, i.e. as `matrix_user`.
- **Behaviour:** grep for `chown` across `lib/`, `setup.sh`, `bridges/` and `scripts/`
  returns seven call sites, and only one touches anything under `$install_dir`:
  `lib/19_compose.sh:95` chowns `podman-compose.yml` alone. Everything else the phases
  create as root stays `root:root`:
  - `$install_dir/data/media`, `$install_dir/data/signing-keys`, `$install_dir/data/logs`
    (`lib/12_homeserver.sh:14`, `:98`) are bind-mounted **read-write** into the Synapse
    container (`templates/compose/synapse.yml:17-19`). Synapse writes its signing key there
    on first boot, plus the media store and the log file.
  - `$install_dir/.env` is `chmod 600` root-owned (`lib/08_secrets.sh:87`) and referenced as
    `env_file:` (`templates/compose/synapse.yml:26`, `dendrite.yml:21`). The compose tool
    reading it *is* the matrix user.
  - `$install_dir/scripts/backup.sh` is `chmod 750` root-owned (`lib/22_backup.sh:48,154`).
- **Trigger:** every install. Postgres is unaffected because it uses the named volume
  `postgres-data` (`templates/compose/base.yml:8-11`), which Podman creates with the right
  ownership — which is presumably why this was never traced.
- **Impact:** three separate failures, in order:
  1. `run_as_user $COMPOSE_CMD ... up -d` cannot read the 0600 root-owned `.env`, so the
     stack does not come up at all.
  2. Even past that, Synapse (running as a subordinate UID, not host root) cannot write its
     signing key, media store or log file into root-owned directories, so it fails on first
     boot and `_deploy_wait_for_homeserver` burns its 180s.
  3. The backup timer runs as a systemd **user** unit for `matrix_user`
     (`lib/22_backup.sh:343`) with `ExecStart=${install_dir}/scripts/backup.sh`, a file that
     user cannot execute. The timer fires nightly and fails with `Permission denied`, and
     `:343` swallows the enable result with `2>/dev/null || true`, so nothing surfaces.
     Backups never run.
- **Fix:** chown the tree to the service user once, after the directories are created and
  before deploy: `chown -R "${matrix_user}:" "$install_dir"` in a dedicated step, with
  `chmod 600` preserved on `.env` (ownership, not mode, is what is wrong there). Keep
  `scripts/backup.sh` at 750 but owned by `matrix_user`. The single existing chown at
  `lib/19_compose.sh:95` is evidence someone already hit symptom (1) and patched the one file
  in front of them.
- **Severity:** CRITICAL — **Confidence:** 5

### [MEDIUM] `backup.retention_daily` / `retention_weekly` reach bash arithmetic unvalidated, giving command execution in the generated backup script

- **Location:** `lib/22_backup.sh:42-43` (the write) and `:146` (the sink);
  gap at `lib/04_config.sh:147-159`
- **Situation:** `lib/04_config.sh:147-148` states the rule explicitly:
  "Ports: integer in 1-65535. Regex-check BEFORE any arithmetic so a value like
  `'x[$(cmd)]'` can never reach `(( ))` evaluation." `media_retention.days` gets the same
  treatment at `:178-182` with the same reasoning in its comment.
- **Behaviour:** `backup.retention_daily` and `backup.retention_weekly` are given defaults at
  `lib/04_config.sh:275-276` and **never validated** — the port loop at `:149` covers only
  `coturn.min_port`, `coturn.max_port` and `smtp.port`. `_backup_generate_backup_script`
  writes them with `printf %q`, which correctly protects the *assignment*, but the generated
  script then evaluates them arithmetically at `:146`:
  `tail -n +$((RETENTION_DAILY + RETENTION_WEEKLY + 1))`. Bash arithmetic recursively
  expands variable contents, and an array-subscript form performs command substitution.
- **Trigger:** a TOML config containing
  `[backup]` / `retention_daily = "x[$(id > /tmp/pwned)]"`. `%q` renders it as a quoted
  literal; `$(( ))` then executes it, as root when `backup.sh` is run by hand or by the
  system timer.
- **Impact:** arbitrary command execution from a config file. The config is
  operator-supplied, so this is privilege-escalation-from-config rather than remote code
  execution — but it is exactly the sink the file's own comments claim to have closed, and
  configs get shared, templated and generated by other tools.
- **Fix:** add both keys to the integer-validation loop in `config_validate`, alongside
  `media_retention.days`:
  ```bash
  for key in backup.retention_daily backup.retention_weekly media_retention.days; do
      val="${CONFIG[$key]:-}"
      [[ -z "$val" ]] && continue
      [[ "$val" =~ ^[0-9]+$ ]] || { log_error "Config: $key must be a non-negative integer, got '$val'"; errors=$((errors+1)); }
  done
  ```
- **Severity:** MEDIUM — **Confidence:** 5

### [MEDIUM] The restore script cannot restore onto a clean host

- **Location:** `lib/22_backup.sh:82-103` (what is backed up) vs `:268,273,299` (what restore
  needs)
- **Behaviour:** `backup.sh` archives the database dump, `data/signing-keys`, `data/media`
  and `config/`. It does **not** include `$INSTALL_DIR/podman-compose.yml` or
  `$INSTALL_DIR/.env`, both of which live at the install-dir root rather than in `config/`.
  `restore.sh` then does
  `podman compose -f "$INSTALL_DIR/podman-compose.yml" down` (`:268`), `up -d postgres`
  (`:273`) and `up -d` (`:299`).
- **Trigger:** the disaster-recovery case the backup exists for — a destroyed host, a fresh
  machine, `restore.sh <archive>`.
- **Impact:** `podman-compose.yml` does not exist, so every compose call fails. `:268` is
  `|| true` so it passes silently; `:273` is not, and the script dies under `set -euo
  pipefail` after having already prompted "this will overwrite current data". The restore
  path only works on a host that still has a working installation — which is the case where
  you least need it.
- **Fix:** add `$INSTALL_DIR/podman-compose.yml` and `$INSTALL_DIR/.env` to the archive
  (step 4), and have `restore.sh` place them before the first compose invocation. Add a
  documented "restore onto a clean host" test.
- **Severity:** MEDIUM — **Confidence:** 5

### [MEDIUM] A failed `pg_restore` is reported as "Database restored"

- **Location:** `lib/22_backup.sh:275-276`
- **Behaviour:**
  `podman exec -i matrix-postgres pg_restore ... < "$BACKUP_DIR/database.dump" 2>/dev/null || true`
  discards both stderr and the exit status, and `:276` logs "Database restored"
  unconditionally. `:299` then starts the stack.
- **Trigger:** the `sleep 5` at `:274` being too short for Postgres to accept connections on
  a loaded host — a routine occurrence — or a version mismatch between the dump and the
  running server.
- **Impact:** the operator is told the restore succeeded and the stack is started against a
  database that was wiped by `--clean --if-exists` but not repopulated. Data loss presented
  as success, during recovery, when there is least margin for it.
- **Fix:** drop the `|| true`, keep stderr, and gate the "restored" message on the exit
  status. Replace the `sleep 5` with a `pg_isready` poll loop.
- **Severity:** MEDIUM — **Confidence:** 5

### [MEDIUM] `backup.sh` leaves an uncompressed full copy of the installation behind when it fails

- **Location:** `lib/22_backup.sh:59` (`mkdir -p "$WORK_DIR"`) and `:118`
  (`rm -rf "$WORK_DIR"`)
- **Behaviour:** the generated script has `set -euo pipefail` (`:38`) and **no `EXIT` trap**.
  `$WORK_DIR` is only removed on the success path at `:118`. The sibling `restore.sh` does
  get a trap (`:210`), so the omission is inconsistent rather than deliberate.
- **Trigger:** any failure between `:59` and `:118` — most plausibly `cp -a "$MEDIA_DIR"`
  (`:96`) running out of space, or `tar -czf` (`:117`) failing for the same reason.
- **Impact:** `$BACKUP_DIR/matrix-backup-<ts>/` is left holding an uncompressed copy of the
  database dump, the signing keys and the entire media store. Because the timer runs nightly
  (`:334`) and the name is timestamped, a persistent failure accumulates one full copy per
  night until the disk fills — at which point the *next* backup fails too, and the retention
  sweep at `:146` only matches `matrix-backup-*.tar.gz*`, so it never cleans these up.
- **Fix:** add `trap 'rm -rf "$WORK_DIR"' EXIT` immediately after `:59`.
- **Severity:** MEDIUM — **Confidence:** 5

### [MEDIUM] Backup and restore hardcode the `synapse` database name and user, ignoring the validated config keys

- **Location:** `lib/22_backup.sh:66,68` and `:275`
- **Behaviour:** `pg_dump -U synapse --format=custom synapse` and
  `pg_restore -U synapse -d synapse`. `CONFIG[database.user]` and `CONFIG[database.name]` are
  first-class settings — validated as SQL identifiers at `lib/04_config.sh:168-174` and
  honoured by `_postgres_host_setup` (`lib/11_postgres.sh:87-88`) — but never passed into the
  generated scripts.
- **Trigger:** `database.mode = "host"` with `database.name` set to anything other than
  `synapse`. (Container mode forces both to `synapse` at `lib/11_postgres.sh:79-80`, so the
  default path is unaffected.)
- **Impact:** `pg_dump` fails against a non-existent database, the host fallback at `:68`
  fails the same way, and `:71-72` exits 1. The nightly backup fails permanently and
  silently — see the ownership finding above for why nothing surfaces it.
- **Fix:** emit `DB_USER=%q` and `DB_NAME=%q` in the config header alongside the other
  `printf %q` lines and use them in both scripts.
- **Severity:** MEDIUM — **Confidence:** 4

### [LOW] The retention policy advertises daily and weekly tiers but implements neither

- **Location:** `lib/22_backup.sh:144-149`
- **Behaviour:** the log line says
  "Applying retention policy (${RETENTION_DAILY} daily, ${RETENTION_WEEKLY} weekly)", but
  the implementation is a single flat rule: sort all archives newest-first and delete
  everything past position `RETENTION_DAILY + RETENTION_WEEKLY`. There is no weekly
  promotion, so with the defaults (7 + 4) the retention window is 11 days, not 7 days plus
  4 weeks.
- **Impact:** the operator believes they have roughly a month of recovery points and
  actually has eleven days. This only becomes visible when a backup older than 11 days is
  needed.
- **Fix:** either implement the tiers (keep the newest N daily, plus the
  first-of-week archive for M weeks) or change the message and the config key names to
  describe the flat policy that exists.
- **Severity:** LOW — **Confidence:** 5

### [LOW] Backups are unencrypted by default and contain the signing key and every secret

- **Location:** `lib/04_config.sh:277` (`backup.encryption` defaults to `none`),
  `lib/22_backup.sh:103` and `:121-135`
- **Behaviour:** the archive includes `config/`, and `config/homeserver.yaml` carries
  `registration_shared_secret`, `macaroon_secret_key`, `form_secret` and the database
  password inline (`templates/configs/homeserver.synapse.yaml.tpl:34,79,123,124`), plus
  `data/signing-keys` — the identity of the homeserver on the federation. With the default
  `encryption = none`, the resulting `.tar.gz` is plaintext, and the optional
  `rclone` upload at `:138-141` will ship it to a remote target as-is.
- **Impact:** anyone who obtains a backup file can impersonate the homeserver to the
  federation and mint admin accounts. The script's own comment at `:87` says
  "PROTECT THIS FILE", which shows the risk was understood; the default does not reflect it.
- **Fix:** if `backup.upload` is set, require `backup.encryption != none` in
  `config_validate` — uploading an unencrypted archive off-box is the case that matters. At
  minimum `log_warn` at generation time when encryption is `none`, and `chmod 600` the
  archive (currently it inherits the umask).
- **Severity:** LOW — **Confidence:** 5

### [HIGH] `--upgrade` runs compose as root against a stack that was created rootless, and its Postgres major-version guard silently never fires

- **Location:** `lib/26_upgrade.sh:83`, `:97` and `:103`
- **Situation:** the install path is explicit about running rootless —
  `lib/21_deploy.sh:52` uses `run_as_user $COMPOSE_CMD ... up -d`. The upgrade path does not.
- **Behaviour:** `upgrade_pull_images` calls `podman exec matrix-postgres ...` (`:83`),
  `$COMPOSE_CMD -f "$compose_file" pull` (`:97`) and `$COMPOSE_CMD ... up -d` (`:103`) all
  as **root** (`setup.sh:108` requires root and never drops). Rootful and rootless Podman
  have entirely separate container, image and volume stores, so root sees none of the
  matrix user's containers.
- **Trigger:** `sudo bash setup.sh --upgrade`, then choosing "Pull latest images".
- **Impact:** two failures, the second worse than the first.
  1. `podman exec matrix-postgres` at `:83` cannot see the rootless container, so it fails
     and `|| true` sets `current_pg_major=""`. The guard at `:85` is `if [[ -n
     "$current_pg_major" ]]`, so **the entire major-version check is skipped**. That check
     exists precisely to stop an automatic Postgres major upgrade running against an
     incompatible data directory — the comment at `:90-91` says "This is NOT safe to do
     automatically". It never runs.
  2. `up -d` as root creates a **second, parallel** stack rather than updating the existing
     one. The rootless containers keep running and holding ports 80/443, so the new ones
     fail to bind, and the operator is left with two half-started stacks.
- **Fix:** wrap all three in `run_as_user`, matching `lib/21_deploy.sh:52`. Then make the
  guard fail closed: if `current_pg_major` cannot be determined, refuse the upgrade rather
  than proceeding — an unknown current version is not evidence of a safe upgrade.
- **Severity:** HIGH — **Confidence:** 5

### [MEDIUM] The upgrade menu's "Reconfigure settings" option does nothing

- **Location:** `lib/26_upgrade.sh:69`, called from `setup.sh:126-127`
- **Behaviour:** `upgrade_prompt`'s case arm for choice 1 is
  `return 0 ;; # Continue to wizard/config for reconfigure`. The caller is
  `upgrade_prompt` followed immediately by `exit "$E_OK"`, so control never continues
  anywhere. The comment describes an intent the call site contradicts.
- **Trigger:** `sudo bash setup.sh --upgrade`, select option 2 ("Reconfigure settings").
- **Impact:** the script prints nothing further and exits 0. The operator reasonably
  concludes the reconfiguration was applied. Nothing changed.
- **Fix:** either implement it — fall through to `wizard_run` and the normal phase sequence
  instead of exiting — or remove the option from the menu at `:63`. Have `upgrade_prompt`
  signal to `main()` which path was chosen rather than relying on an unconditional `exit`.
- **Severity:** MEDIUM — **Confidence:** 5

### [MEDIUM] `--upgrade` bypasses `config_validate` entirely

- **Location:** `setup.sh:118-128`
- **Behaviour:** `main()` calls `config_load "$CONFIG_FILE"` at `:118`, then handles the
  upgrade branch at `:121-128` which always `exit`s. `config_validate` is not reached until
  `:147`, on the normal path only.
- **Trigger:** `sudo bash setup.sh --upgrade --config something.toml`.
- **Impact:** every check in `lib/04_config.sh:121-214` is skipped for a run that then calls
  `bridges_setup` and `compose_assemble` (`lib/26_upgrade.sh:120,123`) with the loaded
  values. `install_dir` reaches path construction without its absolute-path and
  metacharacter check; `webclient.image` reaches the sed in `_compose_render_fragment`; the
  `database.*` identifiers reach SQL unvalidated if a later phase runs. `bridges.enabled` is
  the one value still defended, by the independent check at `lib/16_bridges.sh:97`.
- **Fix:** move `config_validate` to immediately after `config_load` at `:118`, before the
  upgrade branch. The wizard already populates `CONFIG` before validation on the normal
  path, so a second call after `wizard_run` is the belt-and-braces option; validating early
  costs nothing.
- **Severity:** MEDIUM — **Confidence:** 4

### [MEDIUM] `upgrade_bridges` regenerates tokens for existing bridges and never restarts anything

- **Location:** `lib/26_upgrade.sh:110-126`
- **Behaviour:** it calls `bridges_setup`, which for every enabled bridge calls
  `secrets_generate_bridge_tokens "$bridge_name"` (`lib/16_bridges.sh:114`) unconditionally —
  there is no "preserve existing" branch, unlike `secrets_generate_all`. Fresh `as_token`
  and `hs_token` values are written into a new registration YAML. It then calls
  `compose_assemble` and returns; no `up -d`, no restart.
- **Trigger:** `--upgrade` → "Add or remove bridges" on an install with a working bridge.
- **Impact:** the appservice registration file on disk now carries different tokens from the
  ones the running homeserver and the running bridge container are using. Nothing is
  restarted, so the mismatch takes effect at the next restart and the bridge stops
  authenticating — with the failure separated from the action that caused it. The freshly
  assembled compose file is also never applied, so a newly added bridge does not start.
- **Fix:** give `secrets_generate_bridge_tokens` the same preserve-on-re-run behaviour that
  `secrets_generate_all` now has: read existing tokens from the registration YAML if it
  exists. Then have `upgrade_bridges` finish with `run_as_user $COMPOSE_CMD -f ... up -d`.
- **Severity:** MEDIUM — **Confidence:** 4

### [MEDIUM] Media retention never purges anything: it authenticates with a token file that is never created

- **Location:** `lib/23_media_retention.sh:24` and `:33-34`
- **Behaviour:** the generated `media-cleanup.sh` reads
  `ADMIN_TOKEN="$(cat ${install_dir}/.admin-token 2>/dev/null || true)"`. Grep for
  `admin-token` across the entire repository returns **this line and nothing else** — no
  phase writes the file. `_deploy_create_admin` (`lib/21_deploy.sh:87-124`) creates the admin
  account but discards the access token the registration endpoint returns.
- **Trigger:** the weekly timer firing (`:69`).
- **Impact:** `ADMIN_TOKEN` is empty, so the request goes out as `Authorization: Bearer `,
  Synapse returns 401, `curl -sf` exits non-zero and the `||` branch logs
  "WARNING: Media purge failed (admin token may be needed)" to the journal. The remote media
  cache grows without bound for the life of the server. The message is phrased as a
  possibility ("may be needed") rather than the certainty it is.
- **Fix:** capture `access_token` from the registration response in `_deploy_register_admin`
  (it is already parsed there — `:164` checks for `user_id` in the same body) and write it to
  `$install_dir/.admin-token` with mode 0600 owned by the matrix user. Make the purge failure
  a hard error in the generated script so the timer reports failure rather than logging a
  warning.
- **Severity:** MEDIUM — **Confidence:** 5

### [LOW] Two computed values in the generated media-cleanup script are unused

- **Location:** `lib/23_media_retention.sh:25` and `:26`
- **Behaviour:** the generated script sets `DOMAIN="${CONFIG[domain.name]}"` and
  `RETENTION_MS=$(( ${retention_days} * 86400 * 1000 ))`. Neither is referenced anywhere in
  the rest of the script; the purge uses `BEFORE_TS` (`:27`), a different quantity.
- **Assessment:** these are dead, not missing uses. Synapse's `purge_media_cache` admin API
  takes only `before_ts`, so there is no parameter `RETENTION_MS` could feed, and the purge
  URL is `localhost`-based so `DOMAIN` has no role either. Contrast
  `lib/12_homeserver.sh:97`, where an unused value *is* a missing use.
- **Fix:** delete both lines.
- **Severity:** LOW — **Confidence:** 4

### [LOW] `media_retention_setup` depends on a directory `backup_setup` happens to create

- **Location:** `lib/23_media_retention.sh:19`
- **Behaviour:** it writes `$install_dir/scripts/media-cleanup.sh` without a `mkdir -p
  "$install_dir/scripts"`. The directory exists only because `backup_setup` creates it
  (`lib/22_backup.sh:12`) and runs one phase earlier (`setup.sh:183` before `:184`).
- **Impact:** an undeclared ordering dependency between two phases that are otherwise
  independent. Reordering the phase list, or making backup setup conditional, breaks media
  retention with a bare redirection error.
- **Fix:** add `mkdir -p "$install_dir/scripts"` before the heredoc.
- **Severity:** LOW — **Confidence:** 5

### [MEDIUM] Coturn TLS can never be enabled: the gate tests a path that nothing creates

- **Location:** `lib/14_coturn.sh:44-50`, with `lib/19_compose.sh:147` and
  `templates/configs/turnserver.conf.tpl:8`
- **Situation:** `coturn_setup` enables TURNS by testing whether Caddy has issued
  certificates: `cert_dir="$install_dir/data/caddy/data/caddy/certificates"`.
- **Behaviour:** three things make that test permanently false.
  1. It runs at config-generation time (`setup.sh:169`), before any container starts
     (`setup.sh:180`), so Caddy has not issued anything yet even in principle.
  2. Caddy's data lives in the **named volume** `caddy-data`
     (`templates/compose/base.yml:9`), not on a bind mount, so
     `$install_dir/data/caddy/...` can never be populated at all.
  3. `caddy_setup` creates `$install_dir/data/caddy/data` and `.../config`
     (`lib/13_caddy.sh:13`) — neither of which is the tested
     `.../data/caddy/certificates` path.
  The separate `_vars[TLS]="${CONFIG[coturn.tls]:-false}"` at `lib/19_compose.sh:147` reads a
  key nothing ever sets, so it is always false too.
- **Trigger:** every install with coturn enabled (the default).
- **Impact:** `{{#TLS}}` is always stripped, so `turnserver.conf` gets **no `cert=`/`pkey=`**
  — but `tls-listening-port={{STUN_TLS_PORT}}` at template line 8 is *outside* the
  conditional and is always emitted. Coturn is told to run a TLS listener on 5349 with no
  certificate. Meanwhile the firewall opens 5349/tcp and /udp
  (`lib/10_hardening.sh:101-102`) and the homeserver config advertises
  `turns:${domain}:5349` to every client (`lib/12_homeserver.sh:186`). Clients are pointed at
  a TURNS endpoint that does not work, and behind restrictive corporate firewalls — the case
  TURNS exists for — voice and video fail.
- **Fix:** move `tls-listening-port` inside the `{{#TLS}}` block so the listener and the
  certificate appear together, and gate `TURN_URI_TLS` in `lib/12_homeserver.sh:186` on the
  same flag. Then decide how certificates actually reach coturn: bind-mount a host directory
  for Caddy's data instead of the named volume, or add a Caddy `on-demand`/`exec` hook that
  copies the cert into `$install_dir/config/`, and set `CONFIG[coturn.tls]` from the
  outcome. Today no code path can ever set it.
- **Severity:** MEDIUM — **Confidence:** 5

### [MEDIUM] The Cloudflare API token is passed on the curl command line

- **Location:** `lib/07_network.sh:151`, `:164`, `:180`
- **Situation:** `lib/21_deploy.sh:127-131` states the project's rule explicitly: secrets are
  passed "via the ENVIRONMENT to python3 ... so neither the registration shared secret nor
  the admin password ever appears in process argv (`/proc/<pid>/cmdline`)".
- **Behaviour:** the Cloudflare functions do the opposite —
  `curl -sf -H "Authorization: Bearer $token" ...` puts the token directly in argv, where any
  local user can read it from `/proc` for the lifetime of the request.
- **Impact:** a token with DNS-edit scope over the operator's zone is exposed to every local
  account. Lower reach than the deploy-path secrets because the exposure window is a few
  hundred milliseconds and the box is meant to be single-purpose — but it is the same class
  of leak the project already decided to close elsewhere.
- **Fix:** feed the header through stdin: `curl -K - <<< "header = \"Authorization: Bearer $token\""`,
  or write the header to a `mktemp` file with mode 0600 and use `curl -K "$file"`.
- **Severity:** MEDIUM — **Confidence:** 4

### [MEDIUM] Nearly half of `lib/07_network.sh` has no call sites, including the DNS instructions the operator needs

- **Location:** `lib/07_network.sh:122-135`, `:138-191`, `:194-218`
- **Behaviour:** grep across the whole repository finds definitions and no calls for
  `network_check_port_reachable`, `network_cloudflare_create_records` and
  `network_print_dns_instructions` — 96 of the file's 218 lines.
- **Assessment:** `network_print_dns_instructions` is a **missing use**, not dead code.
  `network_validate:37-41` warns "DNS does not point to this server's public IP" and lists
  what it found, but never tells the operator which records to create — which is exactly
  what the unreachable function prints, including the webclient, admin and Grafana
  subdomains. It should be called from that branch and from the "no records" branch at
  `:43-45`. `network_cloudflare_create_records` is a genuine orphan: the Cloudflare token
  config key *is* live (consumed for the DNS-01 challenge at `lib/13_caddy.sh:87`), so the
  automatic-record-creation feature was half-built and never wired to the wizard.
- **Fix:** call `network_print_dns_instructions "$domain"` in both DNS warning branches.
  For the Cloudflare function, either wire it into `network_validate` behind a confirmation
  prompt or delete it — leaving an unreachable API-writing function invites someone to call
  it without noticing the `zone_name` bug below.
- **Severity:** MEDIUM — **Confidence:** 5

### [LOW] Cloudflare zone derivation breaks on multi-part TLDs

- **Location:** `lib/07_network.sh:148`
- **Behaviour:** `zone_name=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')` takes the
  last two labels. For `matrix.example.co.uk` that yields `co.uk`, not `example.co.uk`.
- **Impact:** the zone lookup at `:151-153` returns nothing, `:155-158` logs
  "Could not find Cloudflare zone for co.uk" and returns 1. Affects every `.co.uk`,
  `.com.au`, `.co.jp` and similar operator. Currently latent because the function is never
  called (above), but it will bite the moment it is wired up.
- **Fix:** do not derive the zone from the name. List the account's zones
  (`GET /zones`) and pick the longest one that is a suffix of `$domain`; that is correct for
  every TLD shape without a public-suffix list.
- **Severity:** LOW — **Confidence:** 5

### [MEDIUM] Unmatched `{{PLACEHOLDER}}` tokens pass through rendering into the generated config

- **Location:** `lib/01_utils.sh:213-249` and `lib/19_compose.sh:163-197`
- **Behaviour:** both renderers iterate over the *keys present in the array* and substitute
  each. A placeholder in the template with no corresponding key is never touched, and there
  is no post-render check for leftover `{{`.
- **Trigger, reachable today:** `webclient.type` is defaulted at `lib/04_config.sh:263` but
  never validated, and `_compose_build_vars:153-156` has a `case` with arms for `element`,
  `schildichat` and `cinny` and **no default**. Set `webclient.type = "nheko"` in the TOML:
  `lib/15_webclient.sh:22-35` (also no default arm) writes no config file,
  `_vars[WEBCLIENT_CONFIG_FILE]` is never set, and `templates/compose/webclient.yml:12`
  emerges as the literal
  `- /opt/matrix/config/{{WEBCLIENT_CONFIG_FILE}}:/app/config.json:ro`.
- **Impact:** Podman creates a host directory literally named `{{WEBCLIENT_CONFIG_FILE}}` and
  mounts it over the web client's `config.json`. The client loads a directory as its config
  and shows a blank page. No error is raised at any point.
- **Fix:** two changes, both worth making. Validate `webclient.type` against the three
  supported values in `config_validate` and add `*)` arms to both `case` statements. And make
  the renderers fail closed: after substitution, `grep -q '{{' <<< "$content"` and
  `log_error` + `return 1` naming the leftover placeholders. The recent hardening of these
  two functions already added failure paths for sed errors; an unsubstituted placeholder
  belongs in the same category.
- **Severity:** MEDIUM — **Confidence:** 5

### [LOW] `templates/compose/coturn.yml` and the `coturn-compose.yml` fallback are both dead

- **Location:** `templates/compose/coturn.yml`, `lib/21_deploy.sh:178-181`
- **Behaviour:** `compose_assemble` never adds `coturn.yml` to its fragment list
  (`lib/19_compose.sh:25-54`) — coturn is deployed separately via the rootful Quadlet unit at
  `lib/20_quadlet.sh:104-127`. `_deploy_start_coturn` then tests
  `[[ -f "$install_dir/coturn-compose.yml" ]]`, a file nothing in the repo generates (grep:
  `coturn-compose` appears only at `lib/21_deploy.sh:178`), so that branch never runs and
  execution always falls through to the bare `podman run` at `:183`.
  `templates/compose/coturn.yml` is referenced only by `tests/test_compose_assembly.sh:13,43,67`,
  which asserts properties of a file production code never reads.
- **Impact:** two parallel definitions of the coturn container — the Quadlet unit and the
  compose fragment — that can drift. The fragment additionally mounts
  `{{INSTALL_DIR}}/data/caddy/data/caddy/certificates`, the path that can never exist (see
  the coturn TLS finding), so if anyone did wire it up it would fail.
- **Fix:** delete `templates/compose/coturn.yml`, its test assertions, and the dead
  `coturn-compose.yml` branch at `lib/21_deploy.sh:179-181`. Keep the Quadlet unit as the
  single definition.
- **Severity:** LOW — **Confidence:** 5

### [LOW] `_bridge_setup_single` can call a previous bridge's registration function

- **Location:** `lib/16_bridges.sh:118` and `:125`
- **Behaviour:** the loop sources each plugin into the **current shell** (`:118`), then tests
  `declare -f bridge_generate_registration` (`:125`). Function definitions from a previously
  sourced plugin persist. If plugin *N* does not define
  `bridge_generate_registration`, the test finds plugin *N-1*'s definition and calls it with
  plugin *N*'s tokens and output path.
- **Assessment:** latent — all six shipped plugins define it, so this cannot trigger today.
  It is a trap for the next plugin author, and `bridges/_bridge_template.sh` does not warn
  about it.
- **Fix:** `unset -f bridge_name bridge_image bridge_generate_registration bridge_compose_fragment`
  before each `source`, so a missing function is detected as missing.
- **Severity:** LOW — **Confidence:** 4

### [LOW] `bridges_setup` reports a count of requested bridges, not configured ones

- **Location:** `lib/16_bridges.sh:43-44`
- **Behaviour:** `CONFIG[bridges.has_appservices]="true"` and
  `log_success "Bridges configured (${#bridge_list[@]} enabled)"` both run unconditionally
  after the loop. `bridge_list` is the raw split of `CONFIG[bridges.enabled]`;
  `_bridge_setup_single` silently `return 0`s for names that fail validation (`:98`) or are
  not discovered plugins (`:102`). The array that holds the bridges actually configured,
  `BRIDGES_ENABLED` (`:142`), is not consulted here — though it *is* used correctly by
  `lib/19_compose.sh:74`.
- **Impact:** "Bridges configured (3 enabled)" when zero were, and
  `bridges.has_appservices=true` makes `templates/compose/synapse.yml:20-22` mount an
  appservices directory that may be empty.
- **Fix:** use `${#BRIDGES_ENABLED[@]}` for both the message and the
  `has_appservices` flag: `[[ ${#BRIDGES_ENABLED[@]} -gt 0 ]] && CONFIG[bridges.has_appservices]="true"`.
- **Severity:** LOW — **Confidence:** 5

### [HIGH] Every outcome of the proxy-detection phase is discarded; Caddy is always deployed on 80/443

- **Location:** `lib/09_proxy_detect.sh:7,33,45,47,48`, `lib/27_wizard.sh:383`,
  `lib/19_compose.sh:37`
- **Situation:** `proxy_detect` exists to handle a host that already runs nginx/Apache/
  Traefik/Caddy on ports 80 and 443. It offers four choices (`:38-42`).
- **Behaviour:** grep for each variable the choices set finds writes and **no reads**:
  - `SKIP_CADDY` — written at `:7`, `:33` and `:45`, read nowhere in the repository.
  - `CONFIG[caddy.http_port]` / `CONFIG[caddy.https_port]` — written at `:47-48`, read
    nowhere. `_compose_build_vars` hardcodes `_vars[PORT_HTTP]="$PORT_HTTP"` (80) and
    `_vars[PORT_HTTPS]="$PORT_HTTPS"` (443) at `lib/19_compose.sh:129-130`.
  - The variable `compose_assemble:37` actually consults is `CONFIG[proxy.external]`, set
    only by the wizard at `lib/27_wizard.sh:386` and `:392`.
  And the wizard's gate is broken independently: `lib/27_wizard.sh:383` tests
  `"${CONFIG[proxy.detected]:-}" != ""`, but `proxy.detected` is **never assigned anywhere**
  (grep returns only that read). `proxy_detect` sets the shell global `DETECTED_PROXY`
  instead. So the "Use existing proxy instead of Caddy?" prompt is unreachable, and
  `:392` unconditionally sets `proxy.external="false"`.
- **Trigger:** run `setup.sh` interactively on a host already serving a website on nginx.
- **Impact:** whichever of the four options the operator chooses, `caddy.yml` is included in
  the compose file and Caddy tries to bind 80/443. Choosing "Deploy Caddy on alternate
  ports" prints "Caddy will listen on :8080/:8443. You must proxy 80/443 to these ports" —
  advice that is false, since nothing changed the ports. Choosing "Generate config snippets
  and skip Caddy" generates the snippets and does not skip Caddy. In headless mode, `:32-34`
  sets `SKIP_CADDY="true"` which is likewise read by nothing.
  `proxy_detect` also runs **twice** — once from `wizard_step_proxy:380` and again from
  `setup.sh:160` — so the operator answers the four-option prompt twice per run.
- **Fix:** have `proxy_detect` set `CONFIG[proxy.external]` and `CONFIG[proxy.detected]`
  directly instead of the write-only `SKIP_CADDY`/`DETECTED_PROXY` globals; thread
  `caddy.http_port`/`caddy.https_port` into `_compose_build_vars` and
  `templates/compose/caddy.yml`; and remove the duplicate call at either
  `lib/27_wizard.sh:380` or `setup.sh:160`. Add a `*)` fallthrough to the `case` at `:44` so
  an unexpected selection is not silently a no-op.
- **Severity:** HIGH — **Confidence:** 5

### [HIGH] Rolling back after "Stop existing proxy" stops and disables it a second time instead of restoring it

- **Location:** `lib/09_proxy_detect.sh:223-233` and `lib/25_rollback.sh:130-137`
- **Situation:** choosing option 3 ("Stop existing proxy and use Caddy") runs
  `_stop_existing_proxy`, which for each of `nginx apache2 httpd traefik caddy` that is
  active does `systemctl stop` **and** `systemctl disable`, then records
  `rollback_snapshot "proxy" "SERVICE_STARTED" "$svc"`.
- **Behaviour:** the action type is `SERVICE_STARTED`, whose handler
  (`lib/25_rollback.sh:130-137`) means "we started this service, so undo it by stopping and
  disabling it". Here the recorded fact is the opposite — the service was *stopped*. Rolling
  back therefore runs `systemctl stop "$svc"` and `systemctl disable "$svc"` again.
- **Trigger:** interactive install on a host serving other sites via nginx; choose option 3;
  a later phase fails; accept the rollback.
- **Impact:** the operator's pre-existing web server stays stopped and disabled — the
  rollback cements the damage rather than undoing it — and "Rollback completed." is printed.
  Any other sites on that host stay offline across reboots. This is the single most
  destructive path I found, because the operator explicitly asked for their state to be
  restored.
- **Fix:** add a `SERVICE_STOPPED` action type whose handler runs
  `systemctl enable --now "$svc"`, and emit that here. Record the service's prior
  enabled/active state (`systemctl is-enabled`) in the action data so rollback restores what
  was actually there rather than assuming enabled.
- **Severity:** HIGH — **Confidence:** 5

### [MEDIUM] AlmaLinux and Debian derivatives are classified `unknown`, silently skipping package installation

- **Location:** `lib/02_detect.sh:44-55`
- **Behaviour:** `OS_FAMILY` is derived from `ID` alone; `ID_LIKE` — which exists precisely
  to identify derivatives — is ignored. The `rhel` arm lists `alma`, but AlmaLinux's
  `/etc/os-release` sets `ID="almalinux"`. Debian derivatives that set `ID_LIKE=debian` but a
  different `ID` (Raspberry Pi OS `raspbian`, Devuan, Kali, Zorin, elementary) also fall
  through to `unknown`.
- **Consequence:** `OS_FAMILY` gates package installation in six places —
  `lib/05_prerequisites.sh:225,281,333,348` and `lib/10_hardening.sh:202,299`. Every one is a
  `case` with no `*)` arm, so an `unknown` family means those installs are skipped in
  silence, and the phases then proceed to configure software that was never installed
  (see the fail2ban finding).
- **Trigger:** running on AlmaLinux — a first-tier RHEL rebuild — or Raspberry Pi OS.
- **Fix:** add `almalinux` to the `rhel` arm, and fall back to `ID_LIKE` when `ID` does not
  match: iterate the space-separated `ID_LIKE` values through the same `case`. Then add a
  `*)` arm to each of the six consuming `case` statements that fails loudly rather than
  skipping.
- **Severity:** MEDIUM — **Confidence:** 5

### [LOW] The step counter overruns: `TOTAL_STEPS` counts the wizard only

- **Location:** `lib/27_wizard.sh:7` (`TOTAL_STEPS=17`), `lib/01_utils.sh:42-45`
- **Behaviour:** `log_step` increments a single global `CURRENT_STEP` and prints
  `[$CURRENT_STEP/$TOTAL_STEPS]`. The wizard's seventeen steps each call it, and so does
  every phase function invoked from `main()` (`setup.sh:156-185`) — `postgres_setup`,
  `homeserver_setup`, `caddy_setup` and the rest all open with `log_step`.
- **Impact:** an interactive run displays `[18/17]`, `[19/17]` … through the entire
  installation. In headless mode the wizard is skipped, so `TOTAL_STEPS` is whatever
  `lib/01_utils.sh:9` defaulted it to (0) unless `27_wizard.sh` was sourced — it always is —
  giving `[1/17]` onward for a phase list that is not seventeen items long either.
- **Fix:** set `TOTAL_STEPS` in `setup.sh` from the actual count of steps that will run in
  the selected mode, not in the wizard module.
- **Severity:** LOW — **Confidence:** 5

### [LOW] `detect_existing_install` is never called; `upgrade_check` reimplements it

- **Location:** `lib/02_detect.sh:23-24`, `:188-198`
- **Behaviour:** `detect_all` (`:201-215`) calls twelve detectors and omits this one. Grep
  finds no other caller, so `EXISTING_INSTALL` stays `"false"` and `EXISTING_VERSION` stays
  empty for the whole run. Nothing reads either.
- **Assessment:** dead, but it duplicates live logic — `upgrade_check`
  (`lib/26_upgrade.sh:16-31`) tests for the same state file and parses the same `version=`
  line by hand. The two parsers will drift.
- **Fix:** delete `detect_existing_install` and the two globals, or call it from `detect_all`
  and have `upgrade_check` use the result. Do not leave both.
- **Severity:** LOW — **Confidence:** 5

### [LOW] `_generate_proxy_snippet` writes files that rollback does not know about

- **Location:** `lib/09_proxy_detect.sh:55-71`
- **Behaviour:** it creates `$install_dir/proxy-snippets/` and writes an nginx, Apache,
  Traefik or generic-requirements file there. No `rollback_snapshot` call appears anywhere in
  `lib/09_proxy_detect.sh` except the `SERVICE_STARTED` one at `:230`.
- **Impact:** a rolled-back install leaves a `proxy-snippets` directory behind. Minor in
  isolation, but it is config the operator may later apply to their real proxy, pointing at a
  homeserver that no longer exists.
- **Fix:** `rollback_snapshot "proxy" "FILE_CREATED" "$snippet_dir/<file>"` after each write,
  and `DIR_CREATED` for the directory — both action types are already implemented.
- **Severity:** LOW — **Confidence:** 5

### [LOW] `detect_disk` reports 0 GB free when `df` wraps its output

- **Location:** `lib/02_detect.sh:78`
- **Behaviour:** `df -k "$target" | awk 'NR==2 {printf "%d", $4/1024/1024}'`. When the
  filesystem's device name is longer than the column width, `df` wraps it onto its own line;
  `NR==2` is then the device name alone, `$4` is empty, and awk prints `0`. Long device names
  are routine with LVM (`/dev/mapper/vg--root-lv--root`), iSCSI and overlay mounts.
- **Impact:** `DISK_FREE_GB=0` fails the `MIN_DISK_GB` check in `_check_system_resources`,
  aborting the install on a machine with ample space. The comment above the line shows the
  author was already thinking about `df` portability, so this is a near-miss rather than an
  oversight of the whole area.
- **Fix:** `df -Pk` — POSIX output format, guaranteed one line per filesystem.
- **Severity:** LOW — **Confidence:** 4

### [INFO] `detect_os` sources `/etc/os-release` into the global shell scope

- **Location:** `lib/02_detect.sh:34`
- **Behaviour:** `. /etc/os-release` runs in the current scope, defining `NAME`, `VERSION`,
  `ID`, `ID_LIKE`, `HOME_URL`, `ANSI_COLOR`, `CPE_NAME`, `VERSION_CODENAME` and others as
  globals for the rest of the run.
- **Impact:** no collision exists today (nothing in the repo uses those names), and the file
  is root-owned so there is no injection concern. It is a latent namespace hazard: a future
  `VERSION` or `NAME` variable anywhere in `lib/` would silently inherit the distro's value.
- **Fix:** read the three needed fields in a subshell —
  `OS_ID=$(. /etc/os-release; echo "${ID:-unknown}")` — or `unset` the rest afterwards.
- **Severity:** INFO — **Confidence:** 5

### [INFO] `UNVERIFIED:` the compose-networking premise, and an overlap in `detect_compose_command`

- **Location:** `lib/02_detect.sh:170-186`
- **Claim under test:** the comments at `:174` and `:177` assert that `podman compose` uses
  service-name DNS while `podman-compose` is "pod-based, use localhost". That premise drives
  the four `COMPOSE_NETWORKING == "pod"` branches in `lib/13_caddy.sh` and
  `lib/11_postgres.sh:30`, which switch every inter-service address between
  `homeserver:8008` and `localhost:8008`. I did not verify it: current `podman-compose`
  (v1.x) creates a real network with service-name resolution rather than a shared pod, which
  would make the `pod` branches wrong. Confirming needs a running podman-compose, which is
  outside what I can execute here.
- **Separate, structural issue:** `podman compose` in Podman 4/5 is a shim that delegates to
  whichever external provider is installed — including `podman-compose`. On a host where
  `podman-compose` is the only provider, `podman compose version` succeeds, the first branch
  wins, and `COMPOSE_NETWORKING` is set to `dns` — the opposite of what the second branch
  would have chosen for the same underlying tool. The two branches disagree about a host
  they can both match.
- **Impact if the premise is wrong in either direction:** every service address in the
  Caddyfile and the homeserver's database host is wrong, and nothing detects it until
  containers fail to reach each other.
- **Fix:** determine the provider rather than the front-end command —
  `podman compose version` prints the delegate's identity — and settle the premise with a
  test against a real podman-compose before relying on it.
- **Severity:** INFO — **Confidence:** 2 (`UNCERTAIN` on the premise; the shim overlap
  itself is confidence 4)

### [MEDIUM] `pacman -Sy` without `-u` creates a partial-upgrade state on Arch

- **Location:** `lib/05_prerequisites.sh:238`
- **Behaviour:** `pacman -Sy --noconfirm podman fuse-overlayfs slirp4netns` refreshes the
  package database and installs from it **without** upgrading the packages already on the
  system. Arch's own documentation states that `pacman -Sy package` is unsupported and a
  leading cause of breakage: the newly installed binaries are linked against library
  versions the database advertises but the system does not have.
- **Trigger:** any Arch/Manjaro/EndeavourOS install where Podman is absent and the local
  database is stale — which is the normal state of a machine that has not run `-Syu`
  recently.
- **Impact:** `podman` (or a dependency) fails to start with a linker error about a missing
  `.so` version, and the operator's *whole system* is now in a partial-upgrade state, not
  just the Matrix stack. Recovering requires a full `-Syu`.
- **Fix:** `pacman -Syu --noconfirm --needed podman fuse-overlayfs slirp4netns`. The other
  `pacman` calls in the file (`:247`, `:292`, `:336`, `:351`) use plain `-S`, which inherits
  whatever state `:238` left, so fixing `:238` fixes them too.
- **Severity:** MEDIUM — **Confidence:** 5

### [MEDIUM] `_enable_podman_socket` enables the rootful socket while claiming to serve rootless integration

- **Location:** `lib/05_prerequisites.sh:60-61`, `:209-221`
- **Behaviour:** the function comment and the call-site comment both say "for rootless Podman
  systemd integration", but `systemctl enable --now podman.socket` at `:214` runs as root
  with no `--user`, enabling the **system** socket at `/run/podman/podman.sock`. The rootless
  equivalent would be `systemctl --user enable --now podman.socket` in the matrix user's
  session.
- **Trigger:** every install (the function is called unconditionally from `_check_podman`).
- **Impact:** two things, neither intended. Nothing is done for rootless integration, which
  is what the code says it is for — and Quadlet does not need the socket anyway. And a
  root-privileged Docker-compatible API socket is enabled and started on a host that did not
  ask for one; it is `0660 root:root` so not directly reachable by unprivileged users, but it
  is an extra root-level attack surface with a persistent unit enabled across reboots.
  Note the ordering also makes the stated intent impossible: `prereq_check_all` runs at
  `setup.sh:156`, before `user_setup` creates the matrix user at `:157`, so there is no user
  session to enable a rootless socket in yet.
- **Fix:** decide what is actually wanted. If nothing needs the socket — and with Quadlet
  and compose, nothing here does — delete the function. If the rootless socket is genuinely
  required, move the call into `lib/06_user.sh` after the user exists and use
  `run_as_user systemctl --user enable --now podman.socket`. Either way, correct the comment.
- **Severity:** MEDIUM — **Confidence:** 4

### [LOW] `_check_tools` claims success without re-checking after installing

- **Location:** `lib/05_prerequisites.sh:330-357`
- **Behaviour:** missing tools are collected into `missing`, the operator is prompted, and a
  `case "$OS_FAMILY"` installs them — with **no `*)` arm**, so an unrecognised family (see
  the AlmaLinux finding) installs nothing. The array is never re-tested; `:356` logs
  "Required tools present" unconditionally. `:346-353` repeats the pattern for
  `newuidmap`/`newgidmap`.
- **Impact:** the phase reports success with `openssl` still absent, and the run then dies at
  `lib/08_secrets.sh:51` (`openssl rand`) with no connection to the prerequisite check that
  passed a moment earlier.
- **Fix:** re-run the `check_command` loop after the install and `exit "$E_PREREQ"` with the
  still-missing names if any remain. Add the `*)` arm.
- **Severity:** LOW — **Confidence:** 5

### [LOW] `jq` is a hard prerequisite for code that never runs

- **Location:** `lib/05_prerequisites.sh:324`, `:339-342`
- **Behaviour:** `jq` is in the required-tools list, and declining to install it exits with
  `E_PREREQ`. Its only uses in the entire repository are at `lib/07_network.sh:153,169,172,185`
  — inside `network_cloudflare_create_records`, which has no call sites (see that finding).
- **Impact:** an install is blocked on a dependency nothing uses. Minor, but it is a real
  package pulled onto every host for nothing.
- **Fix:** resolve the Cloudflare function first — if it gets wired up, `jq` is justified; if
  it is deleted, drop `jq` from the list. Do not leave the dependency floating.
- **Severity:** LOW — **Confidence:** 5

### [LOW] The pip fallback installs from PyPI without hash pinning, unlike every other dependency

- **Location:** `lib/05_prerequisites.sh:309-319`
- **Behaviour:** `pip3 install "podman-compose==1.3.0"` runs as root, system-wide. The
  comment says the version is pinned "for reproducibility", and it is — but a version pin is
  not an integrity check: PyPI resolves it to whatever artefact currently sits at that
  version, with no `--require-hashes`.
- **Context:** the project pins every container image to an immutable `@sha256` digest
  (`lib/00_constants.sh:26-49`) and ships `docs/SUPPLY_CHAIN.md`, SBOM generation and cosign
  bundles. This one path installs executable code with none of that.
- **Also:** on Debian 12+, Ubuntu 23.04+, Fedora 38+ and current Arch, a root
  `pip3 install` into the system environment fails with PEP 668
  `externally-managed-environment`. The failure is swallowed by `|| true` at `:284`, `:288`
  and `:300`; `_check_compose:272-275` does then exit with a clear message, so this degrades
  correctly — but the fallback is effectively dead on every current distro.
- **Fix:** use `pip3 install --require-hashes -r` with a small pinned requirements file
  carrying the sha256, and add `--break-system-packages` or install into a dedicated venv so
  the fallback works at all. Or drop the pip path: every supported family packages
  `podman-compose`.
- **Severity:** LOW — **Confidence:** 4

## Verified OK

These were examined specifically and found sound.

- **The coturn SSRF hardening claim checks out.** `lib/14_coturn.sh:3,62` and
  `templates/configs/turnserver.conf.tpl:3` assert mitigation of CVE-2026-27624. I verified
  this against public advisories: the CVE is an authorisation bypass (CVSS 7.2) letting an
  attacker defeat `denied-peer-ip` using IPv4-mapped IPv6 addresses such as
  `::ffff:127.0.0.1`, fixed in coturn 4.9.0, with the documented workaround being
  `denied-peer-ip=::ffff:0.0.0.0-::ffff:255.255.255.255`. The template carries exactly that
  line (`:63`), the pinned image is coturn **4.9.0** (`lib/00_constants.sh:35`), and the
  `denied-peer-ip` list additionally covers RFC 1918, loopback, link-local, RFC 6598 shared
  space, TEST-NET, RFC 2544, IPv6 loopback/link-local/ULA and documentation ranges. The
  `NOTE:` at template lines 77-79 explaining why `no-udp-relay` is deliberately *not* set is
  correct reasoning, not a rationalisation.
- **Admin registration secret handling** (`lib/21_deploy.sh:126-165`) — secrets via
  environment not argv, HMAC and JSON built in Python with `json.dumps`, body posted via
  `--data @-`. The SHA-1 HMAC is not a crypto defect: it is what the Synapse
  `/_synapse/admin/v1/register` protocol specifies.
- **SQL construction in `_postgres_host_setup`** (`lib/11_postgres.sh:98-114`) — identifiers
  are constrained to `^[a-zA-Z_][a-zA-Z0-9_]{0,62}$` by `config_validate`, the password
  literal is escaped by doubling single quotes, all SQL arrives via heredoc rather than
  `psql -c` so it stays out of argv, and `ON_ERROR_STOP=1` makes failures fatal. The
  `\gexec` trick for conditional `CREATE DATABASE` is the correct idiom.
- **`get_user_home`** (`lib/01_utils.sh:282-291`) — `getent` rather than `eval ~$user`, with
  a non-zero return when the home cannot be resolved. Callers check it.
- **`_bridge_setup_single`'s path-traversal defence** (`lib/16_bridges.sh:94-109`) — the
  bridge name must match `^[a-z][a-z0-9_]*$` *and* be a plugin discovered in `bridges/`,
  layered on top of the independent check in `config_validate`. I could not construct an
  input that reaches `source` with an attacker-chosen path.
- **`version_gte`** (`lib/01_utils.sh:317-320`) — correct for greater-than, equal and
  less-than; the `sort -V` dependency is stated in a `NOTE:` and holds on all supported
  distros.
- **Port validation ordering** (`lib/04_config.sh:147-164`) — the regex check genuinely
  precedes `(( ))`, and `10#` prefixes prevent octal misreading of zero-padded values. The
  min/max comparison re-tests both regexes before comparing.
- **`printf %q` in the generated backup script** (`lib/22_backup.sh:39-47`) — correct for
  every value that is only ever *expanded* as a string. The one that escapes it is the
  arithmetic sink, reported separately.
- **Bash version gate** (`setup.sh:23-27`) — uses only constructs available in bash 3.x, so
  it runs on the shells it is meant to reject.
- **`_toml_strip_comment`'s quote tracking** (`lib/03_toml_parser.sh:102-121`) — the
  in-quote state machine handles `#` inside single and double quotes correctly. Only its
  fork-per-character implementation is at issue, not its logic.
- **`restore.sh` temp handling** (`lib/22_backup.sh:209-210`) — `mktemp -d` plus an `EXIT`
  trap. Correct; it is `backup.sh` that lacks the equivalent.
- **`rollback_snapshot_file` ordering** (`lib/25_rollback.sh:34-45`) — records `FILE_BACKUP`
  then `FILE_CREATED`, and because the manifest is replayed through `tac`, the remove happens
  before the restore. Correct.
- **Element/Cinny JSON generation** (`lib/15_webclient.sh:44-98`) — the only interpolated
  value is `$domain`, constrained by `_validate_domain` to alphanumerics, dots and hyphens,
  so the unquoted heredoc cannot produce malformed JSON.
- **Image pinning** (`lib/00_constants.sh:26-49`) — all eighteen images carry a
  `tag@sha256:` digest; none is tag-only.

## Coverage

**Read in full:** `setup.sh`, `lib/00_constants.sh`, `lib/01_utils.sh`, `lib/02_detect.sh`,
`lib/03_toml_parser.sh`, `lib/04_config.sh`, `lib/06_user.sh`, `lib/07_network.sh`,
`lib/08_secrets.sh`, `lib/10_hardening.sh`, `lib/11_postgres.sh`, `lib/12_homeserver.sh`,
`lib/13_caddy.sh`, `lib/14_coturn.sh`, `lib/15_webclient.sh`, `lib/16_bridges.sh`,
`lib/17_admin_ui.sh`, `lib/19_compose.sh`, `lib/20_quadlet.sh`, `lib/21_deploy.sh`,
`lib/22_backup.sh`, `lib/23_media_retention.sh`, `lib/25_rollback.sh`, `lib/26_upgrade.sh`,
`templates/configs/turnserver.conf.tpl`, all nine `templates/compose/*.yml` (structure),
`tests/test_compose_assembly.sh`.

**Read in part:** `lib/05_prerequisites.sh` (lines 1-60 and 200-393; the AUR helper
bootstrap at roughly 60-207 was **not** reviewed — note that `c65227f` rewrote exactly that
region, so it is the least-reviewed new code in the repo). `lib/09_proxy_detect.sh` (the
`proxy_detect` entry point and `_stop_existing_proxy`; the nginx/Apache/Traefik snippet
generators at roughly 72-192 were skimmed for structure only, not audited for correctness of
the emitted proxy configuration). `lib/27_wizard.sh` (the proxy, secrets and confirmation
steps; the other fourteen wizard steps were not read).

**Not read:** `lib/18_monitoring.sh`, `lib/24_report.sh`, the six `bridges/*.sh` plugins and
`bridges/_bridge_template.sh`, `scripts/pin-digests.sh` and `scripts/gen-sbom.sh` (both
audited in a prior pass — see `.claude/agent-memory/code-auditor/`), the remaining
`templates/configs/*.tpl` bodies, and all `tests/*.sh` other than
`test_compose_assembly.sh`. Findings about those files in this report come from grep
evidence across the tree, not from having read them end to end.

**Not attempted:** anything requiring a live run. No container, daemon, systemd unit or
`podman` command was executed. The compose-merge and TOML-parser findings were reproduced by
replaying the exact logic in a scratch directory, not by running `setup.sh`.

## Completion

**Status:** COMPLETE

**Tally by severity:** 4 Critical, 11 High, 27 Medium, 26 Low, 3 Info — 71 findings.

**Test suite at close:** `tests/test_runner.sh` — 338 passed, 0 failed, 0 skipped. (Up from
the 300 the mechanical stage reported; the renderer tests added mid-review account for the
difference.) No test I ran failed, and I changed no code.

**Fixed during the review.** Three of my findings were addressed by other work landing on
the branch while this pass was in progress, and I re-read the current state rather than the
version I first opened:
- `lib/08_secrets.sh` — the CRITICAL re-run secrets bug now has `_load_env_secrets`, which
  mirrors the sourced `.env` values back into `CONFIG` and fails loudly on any missing one.
  That closes the reported hole. The `podman` secrets-mode half of the same finding is
  **not** closed, and is now reported separately as its own HIGH.
- `lib/01_utils.sh` and `lib/19_compose.sh` — both renderers now escape `|` and return
  non-zero when a `sed` substitution fails, with `template_render` leaving the output file
  untouched on failure. That closes the two LOW renderer findings, which I have left in the
  report for the record. The MEDIUM about unsubstituted `{{PLACEHOLDER}}` tokens is a
  different failure mode and is **not** closed.
- `tests/test_compose_assembly.sh` gained renderer tests covering those cases. The compose
  **merge** — the CRITICAL — still has no test that calls `compose_assemble`.

**The headline result.** Six findings are independently sufficient to prevent a default
install from working: the duplicate `services:` keys in the assembled compose file, the
unrendered `log.config`, the root-owned install tree under rootless containers, and — on the
recovery side — the two rollback findings plus the non-functional `--rollback`. The
mechanical stage was clean and the 300-test suite passes because the tests assert properties
of *inputs* (templates exist, contain expected strings) rather than of *outputs*. Nothing in
the suite runs a phase function and inspects what it produced.

**The recurring shape.** Most findings here are one pattern: a value is computed and the
code that should consume it was never written, or consumes a different name. `SKIP_CADDY`,
`CONFIG[caddy.http_port]`, `CONFIG[proxy.detected]`, `hs_vars[LOG_FILE_PATH]`,
`checks_passed`, `.admin-token`, `CONFIG[coturn.tls]`, `EXISTING_INSTALL`,
`network_print_dns_instructions` — each is a half-connected wire. Grep for writes-without-reads
across the whole tree would likely find more than this pass did.

**What I could not establish.** Two items are marked `UNVERIFIED:`/`UNCERTAIN:` in the body
and should not be acted on without a real environment: the fail2ban `failregex` patterns
against a live Synapse log (confidence 3), and the `pod` vs `dns` compose-networking premise
that drives five branches (confidence 2). Both need a runtime check I declined to run under
the brief's constraints.

**Recommended next step.** Before fixing anything else, add one test that calls
`compose_assemble` and asserts the output parses as YAML with exactly one top-level
`services:` key. That single test would have caught the most severe finding in this report,
and its absence is why 300 passing tests coexist with an install that cannot start.
