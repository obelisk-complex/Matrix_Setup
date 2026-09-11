# security-auditor report

**Target:** `/media/owner/Workspace/Matrix_Setup` @ `qa/fleet-loop-20260910` — secret lifecycle and privilege boundaries in the Bash provisioning suite.
**Started:** 2026-09-10
**Status:** COMPLETE (see Completion)

## What works well

The defences that hold, so it is clear what not to disturb while fixing the rest.

- **Secret generation is sound.** 384 bits from `openssl rand` for every secret and every bridge token, with no weaker fallback anywhere (`lib/08_secrets.sh:47-49`).
- **No secret material reaches argv, a log line or a shell trace.** This was the highest-weight item in the brief and the codebase gets it right at every sink: Podman secrets via stdin, the admin registration HMAC and password via the environment plus `--data @-`, and all Postgres SQL via a heredoc. Traced individually; details under Verified OK.
- **`.env` and `podman-compose.yml` are created private, not chmod'd private.** Both use `( umask 077; ... )` around the write and only then `chmod 600`, so there is no world-readable window at all. This is the harder thing to get right and it is right.
- **Injection sinks are enumerated and guarded at the config boundary.** `config_validate` constrains SQL identifiers, Matrix localparts, Unix usernames, integer-arithmetic inputs and bridge plugin names, with comments naming the sink each guard protects — and `tests/test_security_regression.sh` encodes them as regressions. The two gaps I found (F1, F5) are values that were *missed* by this scheme, not an absence of one.
- **Coturn is genuinely hardened,** including the IPv4-mapped-IPv6 deny range that most SSRF filters omit.
- **Every container image is pinned by digest,** all sixteen of them, bridges included. No `curl | bash` anywhere in the repo.
- **The SSH lockout guard refuses to disable password auth without a key present,** which is the failure mode that strands operators.
- **Several past findings were fixed properly rather than papered over** — the `sudo -u postgres psql -c` argv leak, the `eval`-based home directory lookup, the fail-open nftables path and the health check that counted a skipped TURN test as a pass all have real fixes with tests behind them.

## Findings

### F0 [CRITICAL] Re-running the installer replaces every homeserver secret with the literal string `GENERATE_ME` (confidence 5)

- **Location:** `lib/08_secrets.sh:13-19` (the early return) consumed by `lib/12_homeserver.sh:41,42,166,173,187` and `lib/14_coturn.sh:29`.
- **Situation:** `secrets_generate_all` deliberately does not regenerate secrets when `$install_dir/.env` already exists — the correct instinct, and it is what makes a second `sudo bash setup.sh` safe for the `.env` file.
- **Behaviour:** the early-return path sources `.env` with `set -a; source "$env_file"`, which populates *environment variables* (`MACAROON_SECRET_KEY`, ...). It never repopulates the `CONFIG[secrets.*]` associative array. `lib/08_secrets.sh:22-27` is the only code in the repo that writes those keys — confirmed by grepping every assignment to `CONFIG[secrets.` across `lib/` and `bridges/` — and it is skipped. Every later consumer reads `CONFIG[secrets.*]` with a `:-` fallback and therefore silently takes the fallback. `main()` in `setup.sh:159-167` runs `homeserver_setup` on every invocation with no re-run guard, so `homeserver.yaml` is re-rendered from those fallbacks.
- **Proof of concept:** verified by executing the real `secrets_generate_all` and `homeserver_setup` twice against a scratch install dir, exactly as `tests/test_security_regression.sh:116-129` calls it. First run renders real 64-char secrets. Second run renders:
  ```yaml
      password: ""
  registration_shared_secret: "GENERATE_ME"
  turn_shared_secret: ""
  macaroon_secret_key: "GENERATE_ME"
  form_secret: "GENERATE_ME"
  ```
  The `.env` file is untouched and still holds the real secrets, so nothing looks wrong to the operator; `templates/configs/homeserver.synapse.yaml.tpl:79,123,124` interpolate the literal value, and Synapse performs no environment substitution inside `homeserver.yaml`, so `GENERATE_ME` is what the running server uses.
- **Impact:** `macaroon_secret_key` becomes a value hardcoded in this public repository. Anyone can mint a valid access token for **any user on the homeserver**, including admins, with no credentials and no local access — complete remote takeover of every account. `registration_shared_secret: "GENERATE_ME"` lets anyone reachable on the admin endpoint create admin accounts. `form_secret` becomes forgeable. The Postgres password and TURN secret become empty strings. The trigger is the *documented, expected* operation: running the installer a second time to change a setting.
- **Why this survived testing:** `tests/test_security_regression.sh:116-129` asserts idempotency by comparing `POSTGRES_PASSWORD` in `.env` between two runs. `.env` *is* preserved, so the test passes. It never inspects the rendered `homeserver.yaml`, which is where the damage lands. The control is present, the test is present, and the test cannot fail for this bug.
- **Recommendation:** make the early-return path rehydrate `CONFIG` rather than only the environment, so every downstream consumer sees the preserved values:
  ```bash
  if [[ -f "$env_file" ]]; then
      log_substep "Existing .env found, preserving secrets"
      set -a; source "$env_file"; set +a
      CONFIG[secrets.registration_shared_secret]="${REGISTRATION_SHARED_SECRET:-}"
      CONFIG[secrets.macaroon_secret_key]="${MACAROON_SECRET_KEY:-}"
      CONFIG[secrets.form_secret]="${FORM_SECRET:-}"
      CONFIG[secrets.postgres_password]="${POSTGRES_PASSWORD:-}"
      CONFIG[secrets.coturn_secret]="${COTURN_SECRET:-}"
      CONFIG[secrets.redis_password]="${REDIS_PASSWORD:-}"
      return 0
  fi
  ```
  Then delete the `:-GENERATE_ME` and `:-` fallbacks at `lib/12_homeserver.sh:41,42,166,173,187` and `lib/14_coturn.sh:29` — a missing secret must abort the run, never render a placeholder into a live config. The same gap exists on the `secrets.mode=podman` branch (see F3), where no `.env` is written at all. Extend the regression test to assert that a second run renders a `homeserver.yaml` whose secrets match the first.
- **OWASP:** A02 Cryptographic Failures (hardcoded/known key material), A07 Identification and Authentication Failures.

### F1 [CRITICAL] Config value reaches a `sed` script unescaped — root command execution (confidence 5)

- **Location:** `lib/19_compose.sh:182-183` (escape set), reached from `lib/19_compose.sh:160` / `:141` / `:151`.
- **Situation:** `compose_assemble()` renders each compose fragment by building a `sed` substitution per template variable, using `|` as the `s` delimiter.
- **Behaviour:** the escape at `lib/19_compose.sh:182` is `sed 's/[&/\]/\\&/g'` — it escapes `&`, `/` and `\` but **not** the delimiter `|`. A value containing `|` therefore terminates the `s` command and the remainder of the value is parsed as further `sed` script. GNU `sed`'s `e` command executes a shell command.
- **Trigger:** any of the three config values that reach `_compose_build_vars` without passing `config_validate`:
  - `monitoring.grafana_subdomain` → `_vars[GRAFANA_SUBDOMAIN]` (`lib/19_compose.sh:160`) — always populated, default `grafana`, no validation anywhere in `lib/04_config.sh`.
  - `dns.cloudflare_api_token` → `_vars[CF_API_TOKEN]` (`lib/19_compose.sh:141`).
  - `webclient.image` → `_vars[WEBCLIENT_IMAGE]` (`lib/19_compose.sh:151`).
- **Proof of concept:** in the TOML config,
  ```toml
  [monitoring]
  grafana_subdomain = "grafana|g;e id > /tmp/pwned;s|a|a"
  ```
  `setup.sh` requires root (`lib/01_utils.sh:265 require_root`), so `id` runs as **root**. Verified mechanically against GNU sed 4.9 by replaying the exact escape-and-substitute pair from `lib/19_compose.sh:182-183`: the injected command ran and wrote its output file, while the substitution itself completed with exit 0 and no visible error in the rendered output.
- **Impact:** an operator who applies a config file they did not author (a vendor-supplied profile, a fleet config, a copied gist) hands the config's author arbitrary root code execution on the homeserver host. Silent — the render succeeds.
- **Contrast (this is a regression, not a blind spot):** the sibling renderer `template_render` at `lib/01_utils.sh:236` uses the escape set `[&/\|]`, which *does* include the delimiter and is safe. `lib/19_compose.sh:182` is the same function with `|` dropped from the class.
- **Recommendation:** stop building `sed` scripts from data. Substitute in bash:
  ```bash
  for key in "${!_rvars[@]}"; do
      content="${content//\{\{${key}\}\}/${_rvars[$key]}}"
  done
  ```
  This needs no escaping at all and is faster. Apply the same change to `template_render`. Additionally validate `monitoring.grafana_subdomain` (`^[a-z0-9-]{1,63}$`), `webclient.image` and `dns.cloudflare_api_token` in `config_validate`.
- **OWASP:** A03 Injection.

### F2 [HIGH] `homeserver.yaml` holds five secrets and is written world-readable (0644) (confidence 5)

- **Location:** written at `lib/12_homeserver.sh:104-107`; the mode is set by `lib/01_utils.sh:238` (`echo "$content" > "$output"`, inherited umask). No `chmod` follows — `lib/12_homeserver.sh:109-113` only snapshots and logs.
- **Situation:** every other secret-bearing artefact in the suite is explicitly locked down: `.env` 0600 (`lib/08_secrets.sh:61,87`), `podman-compose.yml` 0600 (`lib/19_compose.sh:93-94`), `turnserver.conf` 0640 (`lib/14_coturn.sh:57`), bridge registrations 0640 (`lib/16_bridges.sh:130`), state file 0600 (`lib/04_config.sh:252`). `homeserver.yaml` is the one that was missed.
- **Behaviour:** it is created with the inherited umask. `setup.sh` sets no `umask`, so under root's default 0022 the file lands at **0644, root:root**, inside `$install_dir/config` (also 0755 from the bare `mkdir -p` at `lib/12_homeserver.sh:14`).
- **Contents:** `registration_shared_secret`, `macaroon_secret_key`, `form_secret`, the Postgres password and the coturn TURN shared secret (`lib/12_homeserver.sh:41,42,166,173,187`).
- **Proof of concept:** rendering the real template `templates/configs/homeserver.synapse.yaml.tpl` through the real `template_render` under `umask 0022` produces mode `644` with all five secret placeholders substituted. Reproduced in a scratch directory; the check was `stat -c '%a'` on the output. Any local account on the host can then `cat /opt/matrix/config/homeserver.yaml`.
- **Impact:** any unprivileged local user — including a compromised unrelated service account — reads `registration_shared_secret` and can create arbitrary accounts, including admins, via `/_synapse/admin/v1/register`. `macaroon_secret_key` lets them forge access tokens for any user, i.e. full impersonation without touching a password. The TURN secret allows free relay use; the DB password gives direct database access if Postgres is on the host.
- **Note on why the loose mode may look necessary:** the file is bind-mounted `:ro` into the rootless Synapse container (`templates/compose/synapse.yml:15`), whose in-container root maps to a subuid, not to `root`. World-read is what currently makes the mount readable, so a bare `chmod 600` would break startup. The fix must chown as well.
- **Recommendation:** in `lib/12_homeserver.sh`, immediately after the `template_render` call:
  ```bash
  chown "${CONFIG[matrix_user]:-$DEFAULT_MATRIX_USER}:" "$config_dir/homeserver.yaml"
  chmod 640 "$config_dir/homeserver.yaml"
  ```
  matching the treatment `lib/19_compose.sh:94-95` already gives the compose file, and do the same for `dendrite.yaml` at `lib/12_homeserver.sh:149-152`. Better still, have `template_render` itself create output under `umask 077` so no caller can forget, and tighten `$config_dir` to 0750. Add a regression assertion alongside test 3 in `tests/test_security_regression.sh`, which currently checks the `.env` mode but not this one.
- **OWASP:** A01 Broken Access Control / A05 Security Misconfiguration.

### F3 [HIGH] `--podman-secrets` mode stores secrets nothing consumes, and leaves plaintext on disk anyway (confidence 5)

- **Location:** `lib/08_secrets.sh:29-33` and `lib/08_secrets.sh:92-122`; consumers absent from `templates/compose/*.yml`.
- **Situation:** the flag `--podman-secrets` (`setup.sh:52`) is presented as the hardened alternative to a plaintext `.env`, and the wizard offers it as such (`lib/27_wizard.sh:402` contrasts it with the "standard" `.env`).
- **Behaviour:** three things, each verifiable:
  1. `_store_podman_secrets` creates six Podman secrets, but **no compose template references them.** `grep -rn secret templates/compose/` returns nothing — there is no `secrets:` top-level key and no `secrets:` entry on any service. The stored secrets are inert.
  2. Because line 29 branches, `_store_env_file` never runs, so `$install_dir/.env` is never created — yet `templates/compose/synapse.yml:26` declares `env_file: {{INSTALL_DIR}}/.env` and `templates/compose/postgres.yml:15` reads `${POSTGRES_PASSWORD}` from the compose environment. The values resolve empty.
  3. The plaintext secrets are written to disk regardless, because `homeserver_setup` interpolates `CONFIG[secrets.*]` into `homeserver.yaml` (F2) and `coturn_setup` into `turnserver.conf`, on both branches.
- **Impact:** an operator who selects this mode believing secrets are kept out of the filesystem gets the opposite of what they chose — the plaintext is still in `homeserver.yaml` at 0644, and they have lost the 0600 `.env` that at least had a correct mode. The deployment additionally will not start correctly with an empty `POSTGRES_PASSWORD`. This is the "security control that is present but cannot work" case: the control is inert from its first step and nothing in the suite would report that.
- **Recommendation:** either wire the secrets through (`secrets:` blocks in the compose fragments plus `POSTGRES_PASSWORD_FILE` and Synapse's `*_path` config keys), or remove the flag until it is implemented. Shipping it in its current form is worse than not offering it. Whichever is chosen, `homeserver.yaml` must stop carrying literal secrets in this mode.
- **OWASP:** A02 Cryptographic Failures / A04 Insecure Design.

### F4 [HIGH] Backup archives carry the signing key and every config secret, unencrypted and world-readable (confidence 4)

- **Location:** `lib/22_backup.sh:59` (`mkdir -p "$WORK_DIR"`), `:86` (signing keys), `:103` (whole config dir), `:117` (`tar -czf "$ARCHIVE"`). Default encryption is `none` (`lib/04_config.sh` defaults, `backup.encryption:=none`).
- **Situation:** the generated `backup.sh` runs unattended from a systemd user timer at 03:00 daily (`lib/22_backup.sh:329-343`).
- **Behaviour:** the archive contains the Synapse signing key (the identity of the homeserver for the whole federation), plus `${INSTALL_DIR}/config` in full — `homeserver.yaml` with all five secrets, `turnserver.conf` with the TURN secret, and `config/appservices/*-registration.yaml` with every bridge's `as_token`/`hs_token`. Neither `$WORK_DIR` nor `$ARCHIVE` gets an explicit mode and no `umask` is set in the generated script, so under the usual 0022 they are 0755 and 0644 respectively, in `/opt/matrix/backups` (`lib/00_constants.sh:60`), itself created 0755 by the `mkdir -p` at line 59.
- **Impact:** an unprivileged local user reads `matrix-backup-*.tar.gz` and obtains the homeserver signing key. With that key they can forge federation traffic as the server for as long as the key is trusted — a compromise that cannot be undone by rotating passwords, only by rotating the key and breaking room history continuity. The same archive yields the admin-registration secret and the bridges' third-party tokens.
- **Confidence note (4, not 5):** I read the full generation path and the mode follows from the absence of any `chmod`/`umask` in the emitted script, but I did not execute a backup run — doing so needs Podman and a live Postgres container, which the brief puts out of scope. What would settle it: run the generated `backup.sh` against a throwaway install and `stat -c '%a'` the archive and `$BACKUP_DIR`.
- **Recommendation:** add `umask 077` at the top of the generated script body (`lib/22_backup.sh:38`, alongside `set -euo pipefail`) so `$WORK_DIR`, the archive and the metadata file are all created private; `chmod 700 "$BACKUP_DIR"` after the `mkdir -p`. Separately, reconsider defaulting `backup.encryption` to `none` for an artefact of this sensitivity, and warn at setup time when an unencrypted backup will contain the signing key.
- **OWASP:** A02 Cryptographic Failures.

### F5 [MEDIUM] `backup.retention_daily`/`retention_weekly` reach a bash arithmetic context — command execution in the daily timer (confidence 5)

- **Location:** `lib/22_backup.sh:146`, values injected at `lib/22_backup.sh:42-43`.
- **Situation:** the retention policy values are copied from config into the generated `backup.sh` with `printf %q`, which correctly protects the *assignment*.
- **Behaviour:** `%q` does not help at the use site. Line 146 is `tail -n +$((RETENTION_DAILY + RETENTION_WEEKLY + 1))`, and bash arithmetic re-evaluates variable *contents* recursively, so a value of the form `a[$(...)]` executes the command substitution. Neither key is validated: `config_validate` covers `coturn.min_port`, `coturn.max_port`, `smtp.port` and `media_retention.days`, but not `backup.retention_daily` or `backup.retention_weekly` (`lib/04_config.sh:147-181`).
- **Proof of concept:** `backup.retention_daily = "a[$(id > /tmp/pwned)]"` in the TOML. Verified by replaying line 146's exact expression with that value: the command substitution ran and produced its output file. The payload persists in `/opt/matrix/scripts/backup.sh` and fires on every timer run, i.e. daily, as the `matrix` user.
- **Impact:** code execution as the service account that owns the entire Matrix deployment, recurring and surviving reboots. Lower than F1 only because it is not root.
- **Note:** the codebase already recognises this exact class — `lib/04_config.sh:175-181` validates `media_retention.days` with the comment "prevents bash arithmetic command injection in the generated cleanup script", and `tests/test_security_regression.sh:100-105` asserts it. The two backup retention keys are the same sink with the guard missing.
- **Recommendation:** extend the integer loop in `config_validate` to cover `backup.retention_daily` and `backup.retention_weekly`, and add them to the regression test next to the `media_retention.days` case.
- **OWASP:** A03 Injection.


### F6 [MEDIUM] The fail2ban Matrix jail watches a log path that is never written (confidence 5)

- **Location:** `lib/10_hardening.sh:221` vs `lib/12_homeserver.sh:97` and `templates/compose/synapse.yml:19`.
- **Situation:** `harden_fail2ban` is enabled by default (`CONFIG[hardening.fail2ban]:=true`) and is the suite's only brute-force protection for Matrix logins.
- **Behaviour:** the jail is written with `logpath = $install_dir/data/synapse/homeserver.log`. Synapse is configured to log to `/data/logs/homeserver.log` (`lib/12_homeserver.sh:97`), and `/data/logs` is bind-mounted from `$install_dir/data/logs` (`templates/compose/synapse.yml:19`). `$install_dir/data/synapse/` is never created by any code path in the repo. fail2ban finds no file, the jail produces no bans, and the failure surfaces only in fail2ban's own log.
- **Corroborating evidence:** `templates/hardening/fail2ban-matrix.conf.tpl:8` contains the **correct** path, `logpath = {{INSTALL_DIR}}/data/logs/homeserver.log`. That template is never rendered by any lib — `lib/10_hardening.sh:216` writes an inline heredoc instead. The right value exists in the repo and is not the one that ships.
- **Impact:** unlimited-rate password guessing against `/_matrix/client/*/login` with no lockout, on a deployment whose post-install report tells the operator fail2ban is configured. This is the "control looks present but cannot fire" case named in the brief.
- **Two further defects in the same jail, which matter once the path is fixed:**
  - `lib/10_hardening.sh:237` — the first `failregex` matches *every* login POST, not just failures. At `maxretry = 5` / `findtime = 300` this bans legitimate users, and anyone behind shared NAT, after five normal logins.
  - `<HOST>` will resolve to the Caddy container's address, not the client's, because all traffic is proxied. Synapse needs `x_forwarded: true` and the filter needs to read the forwarded address, or the jail bans the reverse proxy and takes the whole server offline.
- **Recommendation:** render `templates/hardening/fail2ban-matrix.conf.tpl` instead of the inline heredoc, giving one source of truth for the path. Restrict the `failregex` to authentication *failures* (401/403 from `synapse.rest.client.login`). What would demonstrate the fix works: start the stack, make six bad logins from one address, confirm `fail2ban-client status matrix-synapse` shows the ban and that the banned address is the client's, not Caddy's.
- **OWASP:** A07 Identification and Authentication Failures / A09 Security Logging and Monitoring Failures.

### F7 [MEDIUM] `net.ipv4.ip_unprivileged_port_start=80` opens ports 80-1023 to every local user (confidence 4)

- **Location:** `lib/10_hardening.sh:261`, written to `/etc/sysctl.d/99-matrix.conf` and applied at `:279`.
- **Situation:** rootless Podman needs to bind 80 and 443, and lowering this sysctl is the usual way to allow it. It sits inside the block labelled "sysctl hardening".
- **Behaviour:** the sysctl sets the *floor* of the privileged range, so it does not grant 80 and 443 specifically — it makes the **entire range 80 through 1023** bindable by any unprivileged local account. That includes 88 (Kerberos), 389/636 (LDAP), 514 (syslog), 993/995, and 80/443 themselves whenever Caddy is not holding them.
- **Impact:** the concrete one is certificate issuance. A local user who binds port 80 during a Caddy restart, a `compose down`, or a reboot window can answer an ACME HTTP-01 challenge and obtain a **publicly trusted TLS certificate for the homeserver's domain**. With it they can impersonate the homeserver to clients and to federating servers on any network path they can influence. Secondary: squatting a well-known port to capture traffic meant for a service that has not started yet.
- **Confidence note (4, not 5):** the sysctl semantics and the resulting bindable range follow directly from the kernel's definition and the value at line 261 is unambiguous. The ACME hijack additionally needs a window where port 80 is free; I did not measure that window on a real host, which is why this is Medium and not High.
- **Recommendation:** do not lower the global floor. Grant the capability to the runtime instead — `AmbientCapabilities=CAP_NET_BIND_SERVICE` on the Caddy Quadlet unit — or set the floor to 443 if only 443 is genuinely needed, shrinking the exposed range to one port. If the floor must stay at 80, state the trade-off in the post-install report. The existing `rollback_snapshot_sysctl` at `lib/10_hardening.sh:254` already records the prior value, so reverting is supported.
- **OWASP:** A05 Security Misconfiguration.

### F8 [MEDIUM] The rollback path can never find its manifest, so failed installs are never cleaned up (confidence 5)

- **Location:** `lib/25_rollback.sh:13-14` (manifest creation) vs `setup.sh:72` and `setup.sh:111`.
- **Situation:** on any failure the tool offers to undo its changes, and on decline prints `sudo bash setup.sh --rollback` as the recovery command. This is the stated safety net for a half-configured host.
- **Behaviour:** `rollback_init_manifest` creates the manifest with `mktemp "${install_dir}/${MATRIX_SETUP_MANIFEST_FILE}.XXXXXXXXXX"`, producing e.g. `/opt/matrix/.rollback-manifest.aB3xY9zQ1p`. Both consumers look for the un-suffixed name:
  - `setup.sh:72-73` tests `-f "$install_dir/.rollback-manifest"`, which never exists, so the interactive "Roll back the changes made so far?" prompt at `:77` is unreachable and the handler always falls through to the "run it manually" branch.
  - `setup.sh:111` runs `--rollback` without ever calling `rollback_init_manifest`, so `MANIFEST_FILE` is empty and `rollback_execute_all` (`lib/25_rollback.sh:79-82`) logs "No rollback manifest found" and returns 1.
- **Impact:** a failed run leaves SSH hardening applied, firewall rules installed, sysctls changed (including F7), a system user created and generated secrets on disk, while telling the operator to run a command that does nothing. The security consequence is a host left in a state nobody believes it is in — for instance SSH password authentication disabled with none of the stack present.
- **Why the tests do not catch it:** `tests/test_rollback.sh:18-34` calls `rollback_init_manifest` itself and then uses the `$MANIFEST_FILE` variable it set, exercising only the in-process path. The broken case is the cross-invocation one, where a second `setup.sh` process must rediscover the file by name.
- **Recommendation:** use the fixed path `${install_dir}/${MATRIX_SETUP_MANIFEST_FILE}` rather than `mktemp`, created under `umask 077` (it records no secrets, but it drives destructive actions and should not be attacker-writable). In the `--rollback` branch at `setup.sh:111`, set `MANIFEST_FILE` from the configured install dir before calling `rollback_execute_all`, and fail loudly when the file is absent. Add a test that runs rollback in a fresh shell knowing only `install_dir`.
- **OWASP:** A04 Insecure Design.

## Verified OK

Checked and found correctly implemented; no finding raised.

- **Secret entropy and generation.** `_gen_secret` (`lib/08_secrets.sh:47-49`) is `openssl rand -base64 48` — 384 bits from the OS CSPRNG, 64 characters after encoding. No `$RANDOM`, no time seeding, no `/dev/urandom | tr` truncation. Uniform across all six stack secrets and both per-bridge appservice tokens.
- **No secret reaches argv.** Traced every sink. `_store_podman_secrets` pipes via `printf ... | podman secret create ... -` (`lib/08_secrets.sh:114`). `_deploy_register_admin` passes the shared secret and admin password as *environment* variables to `python3` and the JSON body over stdin with `--data @-` (`lib/21_deploy.sh:141-162`). `_postgres_host_setup` feeds all SQL through a heredoc rather than `psql -c` (`lib/11_postgres.sh:104-114`). Each of these carries a comment claiming the property; each claim checks out against the code.
- **No secret reaches a log line.** Every `log_*` call site was checked. `lib/08_secrets.sh:89` logs the path and mode, not the value. `lib/21_deploy.sh:119-122` prints a manual fallback command with no secret in it and deliberately does not echo the API response. The post-install report (`lib/24_report.sh`) prints *locations* of secrets (`:61`, `:63`) and never a value, which is why its `chmod 644` at `:127` is acceptable.
- **Admin registration.** HMAC computed in Python, body built with `json.dumps` (so a password containing quotes or backslashes cannot break out), nonce fetched per attempt, result matched rather than logged. `lib/21_deploy.sh:132-165`.
- **SQL identifier handling.** `database.user` and `database.name` are constrained to `^[a-zA-Z_][a-zA-Z0-9_]{0,62}$` at `lib/04_config.sh:170` before they are interpolated as identifiers, and the password literal is escaped by doubling single quotes (`lib/11_postgres.sh:98`). `ON_ERROR_STOP=1` makes failure loud.
- **Bridge plugin loading.** Three independent guards before `source`: strict name regex, membership in the discovered `BRIDGE_NAMES` map, and a file-exists check (`lib/16_bridges.sh:97-109`), plus validation at config load (`lib/04_config.sh:205-213`). `tests/test_security_regression.sh:149-157` exercises the traversal case. This is genuinely defence in depth.
- **`get_user_home` avoids `eval`.** Resolves through `getent passwd` (`lib/01_utils.sh:279-288`), so a username with shell metacharacters cannot be evaluated; `matrix_user` is separately constrained to a Unix username at `lib/04_config.sh:130`.
- **SSH lockout guard.** `harden_ssh` refuses to disable password authentication and root login unless an authorized key actually exists (`lib/10_hardening.sh:22-52`), and tests the config with `sshd -t` before reloading, removing the drop-in if the test fails (`:70-75`). This is the right ordering and the right default.
- **Coturn relay hardening.** `templates/configs/turnserver.conf.tpl:28-66` denies RFC1918, loopback, link-local, CGNAT, TEST-NET, benchmarking, IPv6 ULA/link-local/loopback, and — importantly — IPv4-mapped IPv6 (`::ffff:0.0.0.0-...`), which is the bypass most SSRF filters miss. `no-multicast-peers`, `no-cli`, `no-tlsv1`, `no-tlsv1_1`, per-user and total quotas, and `stale-nonce` are all set. `use-auth-secret` with a 384-bit shared secret is the correct Matrix TURN pattern. The comment explaining why `no-udp-relay` is *not* set is accurate.
- **Container image supply chain.** Every image in `lib/00_constants.sh:31-49` is pinned by both tag and `@sha256:` digest, including all six bridges. No `:latest`, no unpinned pulls, and no `curl | bash` anywhere in the repo.
- **Compose file and `.env` permissions.** Both are created inside a `( umask 077; ... )` subshell *before* any content is written, then explicitly `chmod 600` (`lib/08_secrets.sh:61-87`, `lib/19_compose.sh:93-94`). There is no world-readable window. The compose file is additionally chowned to the service user. This is exactly the ordering the brief asks about, done correctly — which is what makes `homeserver.yaml` (F2) stand out as the omission.
- **State file excludes secrets.** `config_save_state` skips keys matching `*.password|*.secret*` and writes at 0600 (`lib/04_config.sh:245-253`).
- **`template_render` escapes its `sed` delimiter.** `lib/01_utils.sh:236` uses the character class `[&/\|]`, which includes `|`. The Caddyfile, homeserver config and turnserver config all render through this function and are not injectable. Only `lib/19_compose.sh:182` dropped the `|` (F1).

## Dropped / unreachable

- **Cloudflare API token in the Caddyfile.** Suspected, then dropped. `lib/13_caddy.sh:87` populates `caddy_vars[CF_API_TOKEN]`, but `templates/configs/Caddyfile.tpl:9` reads `{env.CF_API_TOKEN}` — Caddy's own environment lookup — not a `{{CF_API_TOKEN}}` placeholder. The variable is unused and the rendered Caddyfile contains no secret. The token reaches the container only through `templates/compose/caddy.yml:27`, and that file is 0600. Not a finding. (The dead `caddy_vars` entry is untidy but inert.)
- **`podman-compose.yml` world-readable.** Suspected by analogy with F2, then dropped: `lib/19_compose.sh:93-95` gets the umask, the `chmod` and the `chown` all right.
- **Postgres password in `psql` argv.** Checked and clean; `lib/11_postgres.sh:104` uses a heredoc.
- **`bridges.enabled` path traversal into `source`.** Checked and clean; three guards plus config validation, with test coverage.
- **`set -e` and the `[[ cond ]] && harden_x` chain in `harden_all` (`lib/10_hardening.sh:11-16`).** Looked like it would abort the run when a hardening flag is `false`, but `harden_all` is invoked from `run_phase` as `if ! "$@"`, which suppresses `errexit` for the whole function body. Not reachable as a security failure. (Setting `hardening.auto_updates=false` still makes `harden_all` *return* 1 from its last statement and the phase report a failure — a functional wart, and the code auditor's territory rather than a security finding.)
- **`config/log.config` is mounted but never rendered.** `templates/configs/log.config.tpl` exists and `tests/test_templates.sh:96` asserts it exists, but no lib ever calls `template_render` on it — the same dead-template pattern as the fail2ban config in F6. Meanwhile `templates/compose/synapse.yml:16` bind-mounts `{{INSTALL_DIR}}/config/log.config` and `templates/configs/homeserver.synapse.yaml.tpl:42` points Synapse at it. Real, and it compounds F6 (no log file means no fail2ban input either way), but on its own it is a functional defect rather than a security one. Recorded here so it is not lost; it belongs to the code auditor.

## Completion

## Dropped / unreachable
<!-- suspected weaknesses that did not survive tracing -->

## Completion

**Status:** COMPLETE
**Finished:** 2026-09-10

### Tally

| Severity | Count | IDs |
|---|---|---|
| Critical | 2 | F0, F1 |
| High | 3 | F2, F3, F4 |
| Medium | 4 | F5, F6, F7, F8 |
| Low | 0 | — |

All nine are confidence 4 or 5. None are labelled `UNCERTAIN:`; nothing at confidence 1-2 survived tracing. Two findings (F4, F7) are confidence 4 and each carries a note naming exactly what would raise it to 5.

### Fix order

F0 first — it is the only finding that hands an unauthenticated remote attacker every account on the server, and its trigger is the ordinary act of re-running the installer. F1 next. F0 and F3 share a root cause (`CONFIG[secrets.*]` not being the single source of truth for stored secrets) and should be fixed together. F2 and F4 are both "secret written without a mode"; the durable fix for both is to make the writer private by default rather than to add another `chmod` at each call site.

### Verification performed

- Ran the repo's own suite: `bash tests/test_runner.sh` — **300 passed, 0 failed, 0 skipped**. Every finding above coexists with a fully green suite, which is itself part of the result: for F0 and F8 I have named the specific test that passes *because* it asserts the wrong thing.
- Three findings were reproduced by executing the real code, not by reading it: F0 (ran `secrets_generate_all` + `homeserver_setup` twice against a scratch install dir and read the rendered YAML), F1 (replayed the escape-and-substitute pair from `lib/19_compose.sh:182-183` against GNU sed 4.9), F5 (replayed the arithmetic expression from `lib/22_backup.sh:146`). F2 was reproduced by rendering the real Synapse template through the real `template_render` and calling `stat`.
- All reproduction ran in the session scratch directory. Nothing was run against the user's live session: no containers, no daemons, no systemd units, no network calls, and no writes outside the repo other than the report file. Line numbers cite the working tree at `qa/fleet-loop-20260910`, which is clean at `c65227f`.

### Not checked, and why

- **Runtime behaviour of the deployed stack.** Anything needing Podman, a live Postgres or a running Synapse was out of scope per the brief. This bounds F4 (archive and directory modes inferred from the absence of `chmod`/`umask` in the generated script, not observed), F6 (the fail2ban jail's failure to match was inferred from the path mismatch, not observed) and F7 (the length of the window in which port 80 is unbound).
- **The bridge plugins in `bridges/`** were read only for their token-handling interface (`lib/16_bridges.sh:118-135`). Each plugin's own `bridge_generate_registration` writes third-party credentials and deserves its own pass.
- **`lib/18_monitoring.sh` and `lib/17_admin_ui.sh`** were read for secret flow only. Grafana's default admin credentials and the admin UI's exposure surface were not audited; both are reachable from the public internet through Caddy when enabled, and are worth a separate look.
- **Dependency CVE scanning** was not run — there are no language package manifests in this repo, and the container images are digest-pinned, so the relevant question is whether the pinned digests have since acquired advisories. `scripts/pin-digests.sh` exists to re-pin; checking the current digests against advisory feeds needs network access, which the brief excludes.
