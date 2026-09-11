# Disposition ledger - `qa/fleet-loop-20260910`

Every finding from the seven audit reports under `docs/qa-review/`, one row per
finding. Severity and Finding are copied verbatim from each auditor, including
the auditor's own finding label and any `UNVERIFIED` / `UNCERTAIN` marker.
Near-duplicates are **not** merged: each auditor's row stands on its own and is
cross-linked in the Evidence cell.

A blank Disposition is an open finding. Per
`/home/owner/.claude/skills/disposition-ledger/SKILL.md`, no blocker/major
finding ships while its row is blank.

Row counts by source: code-auditor 71, conformance-auditor 24, coverage-analyst
17, compat-auditor 17, dependency-auditor 16, ci-auditor 15, security-auditor 9.
**Total 169.** (The brief anticipated 14 ci-auditor findings; the report file
carries 15 `###` finding headings under `## Findings`, lines 109-547.)

Triage - difficulty and proposed remediation batches - follows the table.

| ID | Source | Severity | Finding | Disposition | Evidence / Link | Approved by |
|---|---|---|---|---|---|---|
| `code-auditor-1` | code-auditor | HIGH | [HIGH] The automatic rollback offer can never fire: the trap looks for a filename that is never created |  | duplicate cluster with code-auditor-2, code-auditor-3, security-auditor-9, coverage-analyst-12, coverage-analyst-6 | - |
| `code-auditor-2` | code-auditor | HIGH | [HIGH] `setup.sh --rollback` is non-functional: it always reports "No rollback manifest found" |  | duplicate of code-auditor-1; see security-auditor-9, coverage-analyst-12 | - |
| `code-auditor-3` | code-auditor | HIGH | [HIGH] Three rollback action types are emitted by production code but silently ignored by the executor |  | same rollback cluster as code-auditor-1, code-auditor-2 | - |
| `code-auditor-4` | code-auditor | MEDIUM | [MEDIUM] The deploy phase records nothing in the rollback manifest |  | same rollback cluster as code-auditor-1 | - |
| `code-auditor-5` | code-auditor | MEDIUM | [MEDIUM] `rollback_cleanup` is never called; manifests accumulate in the install directory |  | same rollback cluster as code-auditor-1 | - |
| `code-auditor-6` | code-auditor | MEDIUM | [MEDIUM] A second, more correct error/interrupt handler exists and is dead |  | duplicate of coverage-analyst-14 | - |
| `code-auditor-7` | code-auditor | CRITICAL | [CRITICAL] Re-running `setup.sh` on an existing install rewrites the homeserver config with the literal secrets `GENERATE_ME` and an empty DB password | accepted | fixed in working tree; `tests/test_security_regression.sh` section 3b, 14 new assertions, negative control verified. Duplicate of security-auditor-1. This row frames the macaroon change as token invalidation (availability), which contradicts security-auditor-1 and security-auditor-3, both of which claim arbitrary-user token forgery; the forgery claim is rejected (see security-auditor-1). | - |
| `code-auditor-8` | code-auditor | HIGH | [HIGH] `--podman-secrets` mode produces a stack that cannot start; nothing ever reads the Podman secrets |  | duplicate of security-auditor-4; coverage evidence in coverage-analyst-4 | - |
| `code-auditor-9` | code-auditor | MEDIUM | [MEDIUM] `--podman-secrets` is silently overridden by the config file |  | duplicate of conformance-auditor-2 | - |
| `code-auditor-10` | code-auditor | MEDIUM | [MEDIUM] `config_save_state` writes `backup.encryption_key` and the reCAPTCHA private key to the state file despite the comment saying it does not | accepted | verified and broader than filed. The filter was `*.password\|*.secret*`, which matches only keys **ending** in those, so `secrets.postgres_password`, `secrets.registration_shared_secret`, `secrets.coturn_secret`, every bridge as/hs token, `dns.cloudflare_api_token`, `registration.recaptcha_private_key` and `backup.encryption_key` were all persisted - the database password included, which the finding does not mention. Now `secrets.*\|*password*\|*secret*\|*token*\|*key*`. Nothing reads a secret back: the only consumers are `upgrade_check` (version, domain, homeserver type) and `detect_existing_install` (version). The file stays 0600. 13 tests in `tests/test_config_validation.sh`; negative control (old filter restored) = 8 reds. | - |
| `code-auditor-11` | code-auditor | MEDIUM | [MEDIUM] Host-mode Postgres never resets the role password, so a regenerated secret locks the homeserver out |  | - | - |
| `code-auditor-12` | code-auditor | MEDIUM | [MEDIUM] `deploy_run` reports success regardless of health-check results | accepted | verified: `_deploy_health_checks` counted results and returned nothing, and `deploy_run` logged "deployed successfully" regardless. The client API check is now decisive - it is served inside the container and needs nothing external, so its failure fails the phase - while federation and TURN stay warnings and the phase reports `N/M checks passed` instead of unqualified success. 4 tests in `tests/test_deploy.sh`; negative control (made advisory again) = 1 red. | - |
| `code-auditor-13` | code-auditor | LOW | [LOW] `_deploy_start_coturn` swallows every failure and then claims success | accepted | verified: every branch ended in `\|\| true` and `log_substep "Coturn started"` always ran. The fallback now tracks its status, records `deploy.coturn_result`, and says what a failure costs (TURN relay unavailable, NAT-to-NAT calls fail) with the command to look at the logs. The deploy is not aborted - coturn is rootful and separate. The result is surfaced in the post-install report (`lib/24_report.sh`), with 6 new tests in `tests/test_report.sh`. 4 tests in `tests/test_coturn_tls.sh`; negative control (failure swallowed again) = 2 reds. | - |
| `code-auditor-14` | code-auditor | LOW | [LOW] Dendrite installs never get an admin account, and the manual fallback command names a Synapse container | rejected | **does not hold against the current tree**: `_deploy_create_admin` branches on homeserver type and `_deploy_create_admin_dendrite` drives the `create-account` binary in the Dendrite image (work-dendrite). The `matrix-synapse` manual fallback command the finding objects to now sits inside `_deploy_create_admin_synapse`, where it names the right container. Re-checked by qa-agent, 2026-09-10; no change made. | - |
| `code-auditor-15` | code-auditor | LOW | [LOW] `--help` prints two lines of source code | accepted | verified: `head -17 "$0" \| tail -14` printed the comment markers, the `# shellcheck disable=SC2154` directive and the `set -Eeuo pipefail` line. Replaced with a `usage()` heredoc. 24 tests in `tests/test_cli.sh` (both flags, every documented option, no source text, unknown option rejected); negative control (old form restored) = 6 reds. | - |
| `code-auditor-16` | code-auditor | LOW | [LOW] Dead local in `_deploy_start_services` | accepted | verified: `local matrix_user` in `_deploy_start_services` was unused (the compose call goes through `run_as_user`, which resolves the user itself). Deleted. | - |
| `code-auditor-17` | code-auditor | HIGH | [HIGH] The pure-Bash TOML fallback is unreachable, and a config file that fails the Python path kills `setup.sh` with no output at all |  | duplicate of compat-auditor-4; coverage evidence in coverage-analyst-7 | - |
| `code-auditor-18` | code-auditor | LOW | [LOW] The Python TOML backend corrupts any value containing a newline |  | related to code-auditor-24 (both are newline handling) | - |
| `code-auditor-19` | code-auditor | INFO | [INFO] `_toml_strip_comment` forks a subshell per quote character |  | - | - |
| `code-auditor-20` | code-auditor | CRITICAL | [CRITICAL] Compose assembly concatenates fragments that each declare a top-level `services:` key, so the generated stack is either rejected or silently reduced to one container |  | duplicate of conformance-auditor-3; coverage gap in coverage-analyst-5 | - |
| `code-auditor-21` | code-auditor | HIGH | [HIGH] The `matrix-stack.container` Quadlet unit has no `Image=` and cannot generate a service | accepted | verified: the heredoc still wrote a `[Container]` unit with only `ContainerName=` and `PodmanArgs=`. podman-systemd.unit(5): "There is only one required key, Image, which defines the container image the service runs", so it generated no service. DECISION (design question 1): neither a pod unit nor per-service units - the placeholder is deleted and the existing plain `matrix-compose.service` is the single boot path. Per-service `.container` units would restate every image, volume and network the compose file already defines (two sources of truth); a `.pod` Quadlet needs Podman 5.0 while the agreed floor is 4.7.0. Found while fixing: `matrix-compose.service` was never enabled, so nothing started the stack on boot either - the phase now creates the `default.target.wants` symlink directly, because `systemctl --user enable` needs a session bus sudo does not provide and enable is defined as creating that symlink (systemctl(1)). Quadlet units need no equivalent: their generator applies [Install] itself. 10 tests in `tests/test_quadlet.sh`; negative controls: enable symlink removed = 4 reds, placeholder restored = 2 reds. | agent decision, 2026-09-10 |
| `code-auditor-22` | code-auditor | LOW | [LOW] `~/.config`, `~/.local` and `~/.local/share` are left owned by root in the matrix user's home |  | - | - |
| `code-auditor-23` | code-auditor | LOW | [LOW] `_compose_render_fragment` and `template_render` are near-identical copies that have diverged in their sed escaping | accepted | fixed in working tree; 24 new tests across `test_compose_assembly.sh` and `test_config_validation.sh`, per-fix negative controls verified. Duplicate of security-auditor-2; `lib/19_compose.sh:189` and `lib/01_utils.sh:241` now escape the same four characters (ampersand, slash, backslash and the sed delimiter). | - |
| `code-auditor-24` | code-auditor | LOW | [LOW] `template_render` cannot handle a value containing a newline | accepted | fixed in working tree; 24 new tests across `test_compose_assembly.sh` and `test_config_validation.sh`, per-fix negative controls verified. Scope: the silent-empty-on-sed-failure half is fixed - both renderers now `return 1` naming the key (`lib/01_utils.sh:232-246`, `lib/19_compose.sh:176-194`) instead of writing empty output. `sed` still cannot carry a literal newline; the failure is now loud rather than silent. Related to code-auditor-18. | - |
| `code-auditor-25` | code-auditor | CRITICAL | [CRITICAL] `log.config` is never rendered, so the Synapse container bind-mounts a directory over its logging config and the homeserver cannot start |  | duplicate of conformance-auditor-4 | - |
| `code-auditor-26` | code-auditor | HIGH | [HIGH] The fail2ban jail watches a log path that is never written |  | duplicate of conformance-auditor-6 and security-auditor-7 | - |
| `code-auditor-27` | code-auditor | HIGH | [HIGH] The nftables firewall fallback applies a default-drop policy that only permits port 22, locking out operators on a non-standard SSH port |  | duplicate of compat-auditor-13 | - |
| `code-auditor-28` | code-auditor | MEDIUM | [MEDIUM] The fail2ban filter would ban successful logins, and its patterns do not match Synapse's log format |  | related to compat-auditor-14 (same jail, different failure mode) | - |
| `code-auditor-29` | code-auditor | MEDIUM | [MEDIUM] `harden_ssh` reverts by deleting the config file, discarding an existing one it had just backed up |  | - | - |
| `code-auditor-30` | code-auditor | MEDIUM | [MEDIUM] `harden_ssh`'s lockout guard can be satisfied by a key belonging to an unrelated user |  | - | - |
| `code-auditor-31` | code-auditor | MEDIUM | [MEDIUM] SSH hardening is a silent no-op on distros whose `sshd_config` has no `Include` |  | duplicate of compat-auditor-17 | - |
| `code-auditor-32` | code-auditor | LOW | [LOW] Rolling back sysctl hardening removes the file but leaves the kernel values applied |  | - | - |
| `code-auditor-33` | code-auditor | LOW | [LOW] `_setup_subuid` checks only for the presence of a subuid entry, not the range the comment requires |  | - | - |
| `code-auditor-34` | code-auditor | LOW | [LOW] `harden_fail2ban` writes jail files for a fail2ban it may not have installed |  | related to compat-auditor-3 (fail2ban may never have installed) | - |
| `code-auditor-35` | code-auditor | CRITICAL | [CRITICAL] The install directory is entirely root-owned but every container runs rootless as the matrix user | accepted | verified: nothing chowns `install_dir` anywhere in `lib/`; the whole tree is written by root while every container runs rootless as the matrix user and bind-mounts it. Added `install_dir_set_ownership` (`lib/06_user.sh`), run as its own phase in `setup.sh` after Quadlet and before Deploy - the last point at which everything under `install_dir` has been written and nothing has read it yet. Post-deploy phases that add files (`backup_setup`) chown what they create. File **modes** are deliberately untouched: `security-auditor-3` depends on which UID each image runs as inside the user namespace, which is UNVERIFIED here. 10 tests in `tests/test_ownership.sh`; negative controls: phase removed = 2 reds, chown -R removed = 1 red, scripts chown removed = 1 red. | - |
| `code-auditor-36` | code-auditor | MEDIUM | [MEDIUM] `backup.retention_daily` / `retention_weekly` reach bash arithmetic unvalidated, giving command execution in the generated backup script | accepted | verified, with a correction to the mechanism. The values do reach `(( ))` in the root-run backup script and were not validated. But the injection does **not** work the way the finding describes: on bash 5.2.21 a bare `$(cmd)` operand is a syntax error (tested three ways, nothing executed). What does execute is an **array subscript** operand - `a[$(cmd)]` ran the command in the same test. So the exposure is real but narrower than filed. Both keys are now validated as non-negative integers in `config_validate`, matching `media_retention.days`. 12 tests in `tests/test_config_validation.sh` including the subscript form; negative control (validation removed) = 7 reds. | - |
| `code-auditor-37` | code-auditor | MEDIUM | [MEDIUM] The restore script cannot restore onto a clean host | accepted | verified: `cp -a $BACKUP_DIR/signing-keys/* $INSTALL_DIR/data/signing-keys/` fails when the destination does not exist, which is the disaster-recovery case the script exists for. Destinations are now created first. Test: restore onto a clean host; negative control (mkdir removed) = 3 reds. | - |
| `code-auditor-38` | code-auditor | MEDIUM | [MEDIUM] A failed `pg_restore` is reported as "Database restored" | accepted | verified: `pg_restore ... \|\| true` followed by `log "Database restored"`. The status is now propagated - the script reports the failure and exits 1. 2 tests; covered by the same negative control. | - |
| `code-auditor-39` | code-auditor | MEDIUM | [MEDIUM] `backup.sh` leaves an uncompressed full copy of the installation behind when it fails | accepted | verified: a failed dump exited 1 with $WORK_DIR (a full uncompressed copy of the installation) still in place. `trap rm -rf $WORK_DIR EXIT` added. Negative control (trap removed) = 1 red. | - |
| `code-auditor-40` | code-auditor | MEDIUM | [MEDIUM] Backup and restore hardcode the `synapse` database name and user, ignoring the validated config keys | accepted | duplicate of `remed-13`; fixed there | - |
| `code-auditor-41` | code-auditor | LOW | [LOW] The retention policy advertises daily and weekly tiers but implements neither | accepted | duplicate of `conformance-auditor-14`; fixed there | - |
| `code-auditor-42` | code-auditor | LOW | [LOW] Backups are unencrypted by default and contain the signing key and every secret | accepted | DECISION (design question 2): the default stays `none`; the exposure is fixed instead. The generated script now runs under `umask 077` and chmods the backup directory and work directory 0700, so the archive holding the signing key, the database and every config secret is 0600 rather than the 0664 it was (test asserts the mode). Defaulting to gpg/age cannot work without a recipient key: the installer would have to generate one and store it beside the archives, which protects nothing against a local reader and adds a permanent lose-the-key-lose-the-backup failure mode. `config_validate` already refuses `backup.encryption != none` without `backup.encryption_key`, so a configured encryption cannot silently degrade to plaintext. Negative controls: umask reverted = 1 red, chmod removed = 1 red. | agent decision, 2026-09-10 |
| `code-auditor-43` | code-auditor | HIGH | [HIGH] `--upgrade` runs compose as root against a stack that was created rootless, and its Postgres major-version guard silently never fires | accepted | verified, both halves. `--upgrade` never calls `detect_all`, so `COMPOSE_CMD` was the `lib/19_compose.sh` default and both compose calls ran as root against a stack created rootless under the matrix user; the `podman exec matrix-postgres` probe hit root podman, which owns no such container, returned empty, and the guard was nested inside `[[ -n $current_pg_major ]]` so it skipped silently. All three now go through `run_as_user` (same as `lib/21_deploy.sh:52`), and an unreadable version aborts with an actionable message instead of pulling. 13 tests in `tests/test_upgrade.sh`; negative controls: `run_as_user` removed = 4 reds, original fail-open nesting = 3 reds, hardcoded db identity = 2 reds. Behaviour change: an upgrade attempted while the stack is down now refuses instead of pulling. | - |
| `code-auditor-44` | code-auditor | MEDIUM | [MEDIUM] The upgrade menu's "Reconfigure settings" option does nothing | accepted | verified: `upgrade_prompt` returned 0 for "Reconfigure settings" and `setup.sh` then exited `E_OK`, so it was indistinguishable from Abort. It now returns `E_UPGRADE_RECONFIGURE` (a status, not a cross-file global, which also keeps shellcheck honest) and `setup.sh` falls through into the ordinary detection/wizard/phase run, passing any other non-zero status straight out. 6 tests in `tests/test_upgrade.sh` covering all four choices; negative control (signal removed) = 1 red. | - |
| `code-auditor-45` | code-auditor | MEDIUM | [MEDIUM] `--upgrade` bypasses `config_validate` entirely | accepted | verified: the `--upgrade` branch exited before reaching `config_validate`. It now validates straight after `upgrade_check`, so the same config is held to the same rules on upgrade as on install. Found while fixing: this would have broken `--upgrade --headless` with no `--config`, because `domain.confirmed` is only ever set by the wizard - `upgrade_check` now carries it forward, the domain being confirmed by construction (a mismatch aborts earlier). 3 tests, two of them driving `setup.sh --upgrade` under `unshare -r`; negative controls: validation removed = 1 red, carry-forward removed = 1 red. | - |
| `code-auditor-46` | code-auditor | MEDIUM | [MEDIUM] `upgrade_bridges` regenerates tokens for existing bridges and never restarts anything |  | - | - |
| `code-auditor-47` | code-auditor | MEDIUM | [MEDIUM] Media retention never purges anything: it authenticates with a token file that is never created | rejected | **rejected on re-derivation**: does not hold against the current tree. `lib/23_media_retention.sh` no longer makes any HTTP call and needs no token - the generated `media-cleanup.sh` reads the media bind mount and reports disk usage, while the purge itself is Synapse's own `media_retention.remote_media_lifetime` in `templates/configs/homeserver.synapse.yaml.tpl:69-70`. No `purge_media_cache` call remains in `lib/` (the only occurrences are the explanatory comments at the top of that file). Re-checked by qa-agent, 2026-09-10; no code change made. | - |
| `code-auditor-48` | code-auditor | LOW | [LOW] Two computed values in the generated media-cleanup script are unused | rejected | **does not hold against the current tree**: the generated `media-cleanup.sh` computes only `USAGE`, which it uses. The retention/cutoff values the finding names were removed when the file was rewritten to stop attempting an API purge. Re-checked by qa-agent, 2026-09-10; no change made. | - |
| `code-auditor-49` | code-auditor | LOW | [LOW] `media_retention_setup` depends on a directory `backup_setup` happens to create | rejected | **does not hold against the current tree**: `media_retention_setup` creates its own directories - `mkdir -p "$timer_dir" "$install_dir/scripts"` (`lib/23_media_retention.sh:45`) - with a comment saying why it does not rely on `backup_setup` ordering. Re-checked by qa-agent, 2026-09-10; no change made. | - |
| `code-auditor-50` | code-auditor | MEDIUM | [MEDIUM] Coturn TLS can never be enabled: the gate tests a path that nothing creates | accepted | same fix as `remed-1`. The gate tested `-d $install_dir/data/caddy/data/caddy/certificates`, which Caddy creates at runtime, so on a fresh install TLS was always off and on a re-run it turned on and wrote cert=/pkey= lines pointing at a path nothing mounted - coturn could then not start. The gate is now the pair turnserver.conf actually names (`cert.pem`, `privkey.pem`) inside that directory, so Caddy creating its own store no longer flips TLS on, and an operator who places the pair gets the mount on every path. Behaviour change for an existing install: a re-run that previously enabled broken TLS now leaves it off. | - |
| `code-auditor-51` | code-auditor | MEDIUM | [MEDIUM] The Cloudflare API token is passed on the curl command line |  | - | - |
| `code-auditor-52` | code-auditor | MEDIUM | [MEDIUM] Nearly half of `lib/07_network.sh` has no call sites, including the DNS instructions the operator needs |  | duplicate of coverage-analyst-13; coverage gap in coverage-analyst-3 | - |
| `code-auditor-53` | code-auditor | LOW | [LOW] Cloudflare zone derivation breaks on multi-part TLDs |  | - | - |
| `code-auditor-54` | code-auditor | MEDIUM | [MEDIUM] Unmatched `{{PLACEHOLDER}}` tokens pass through rendering into the generated config |  | - | - |
| `code-auditor-55` | code-auditor | LOW | [LOW] `templates/compose/coturn.yml` and the `coturn-compose.yml` fallback are both dead |  | - | - |
| `code-auditor-56` | code-auditor | LOW | [LOW] `_bridge_setup_single` can call a previous bridge's registration function | accepted | verified and worse than filed: plugins are sourced into the same shell, so a plugin without `bridge_generate_registration` inherited the previous plugin alphabetically - the test reproduced `beta-registration.yaml` containing `id: alpha`, i.e. a registration for the wrong bridge, not just a stale call. The interface functions are now unset before each source, and a plugin that defines none is skipped with a warning. 3 tests; negative control (unset removed) = 3 reds. | - |
| `code-auditor-57` | code-auditor | LOW | [LOW] `bridges_setup` reports a count of requested bridges, not configured ones | accepted | verified: the summary counted `bridge_list` (requested). It now reports `N configured of M requested`. 1 test; negative control = 1 red. | - |
| `code-auditor-58` | code-auditor | HIGH | [HIGH] Every outcome of the proxy-detection phase is discarded; Caddy is always deployed on 80/443 |  | related to conformance-auditor-21 (same discarded proxy decision) | - |
| `code-auditor-59` | code-auditor | HIGH | [HIGH] Rolling back after "Stop existing proxy" stops and disables it a second time instead of restoring it | accepted | verified against the current tree: `_stop_existing_proxy` (`lib/09_proxy_detect.sh:149`) recorded `SERVICE_STARTED` for a service it had just stopped and disabled, and that arm (`lib/25_rollback.sh:172`) stops and disables. Fixed by adding a `SERVICE_STOPPED` arm to `_rollback_action` and recording that instead. The action data carries the prior enabled state (`svc\|true\|false`), because `_stop_existing_proxy` disables unconditionally: an enabled proxy is restored with `systemctl enable --now`, a hand-started one with `systemctl start`, so neither gains nor loses its boot behaviour. DECISION on a failed restore: **report and continue**, not abort. Rollback runs when the install has already failed and the actions queued behind this one (restoring backed-up config, removing installer-written files) are what the operator needs done; aborting mid-replay would strand them, and the defect being fixed was silence, so the failure path emits the exact manual command via `log_warn`. `systemctl enable --now` and `is-enabled`'s exit codes are per systemctl(1) on this host. 14 tests in `tests/test_rollback.sh`, all driven through a PATH stub that records argv - no real `systemctl` is invoked and every manifest stays inside `TEST_TMP`. Negative controls: recorder reverted to `SERVICE_STARTED` = 7 reds; executor arm deleted = 4 reds; both files restored by checksum. The `SERVICE_STARTED` arm is kept and covered - it is the correct handler for a service the installer really started, which `code-auditor` proposes recording before `_deploy_start_services`. | agent decision, 2026-09-11 |
| `code-auditor-60` | code-auditor | MEDIUM | [MEDIUM] AlmaLinux and Debian derivatives are classified `unknown`, silently skipping package installation |  | - | - |
| `code-auditor-61` | code-auditor | LOW | [LOW] The step counter overruns: `TOTAL_STEPS` counts the wizard only |  | - | - |
| `code-auditor-62` | code-auditor | LOW | [LOW] `detect_existing_install` is never called; `upgrade_check` reimplements it |  | duplicate of coverage-analyst-17 | - |
| `code-auditor-63` | code-auditor | LOW | [LOW] `_generate_proxy_snippet` writes files that rollback does not know about |  | - | - |
| `code-auditor-64` | code-auditor | LOW | [LOW] `detect_disk` reports 0 GB free when `df` wraps its output |  | - | - |
| `code-auditor-65` | code-auditor | INFO | [INFO] `detect_os` sources `/etc/os-release` into the global shell scope |  | - | - |
| `code-auditor-66` | code-auditor | INFO | [INFO] `UNVERIFIED:` the compose-networking premise, and an overlap in `detect_compose_command` |  | - | - |
| `code-auditor-67` | code-auditor | MEDIUM | [MEDIUM] `pacman -Sy` without `-u` creates a partial-upgrade state on Arch |  | duplicate of compat-auditor-6 and dependency-auditor-8 | - |
| `code-auditor-68` | code-auditor | MEDIUM | [MEDIUM] `_enable_podman_socket` enables the rootful socket while claiming to serve rootless integration |  | duplicate of compat-auditor-15 and dependency-auditor-7 | - |
| `code-auditor-69` | code-auditor | LOW | [LOW] `_check_tools` claims success without re-checking after installing |  | - | - |
| `code-auditor-70` | code-auditor | LOW | [LOW] `jq` is a hard prerequisite for code that never runs |  | - | - |
| `code-auditor-71` | code-auditor | LOW | [LOW] The pip fallback installs from PyPI without hash pinning, unlike every other dependency |  | duplicate of dependency-auditor-1; platform reach in compat-auditor-5 | - |
| `conformance-auditor-1` | conformance-auditor | HIGH | F-01 [HIGH] `advanced.install_dir` and `advanced.matrix_user` are read under the wrong key | accepted | duplicate of `remed-2`; fixed there | - |
| `conformance-auditor-2` | conformance-auditor | HIGH | F-02 [HIGH] `--podman-secrets` is silently overridden by any `--config` file |  | duplicate of code-auditor-9 | - |
| `conformance-auditor-3` | conformance-auditor | CRITICAL | F-000 [CRITICAL] The assembled compose file repeats the top-level `services:` key, so only the last fragment is deployed |  | duplicate of code-auditor-20 | - |
| `conformance-auditor-4` | conformance-auditor | CRITICAL | F-00 [CRITICAL] `log.config` is mounted and referenced but never generated |  | duplicate of code-auditor-25 | - |
| `conformance-auditor-5` | conformance-auditor | CRITICAL | F-0A [CRITICAL] Grafana ships with `admin`/`admin` on a public subdomain |  | - | - |
| `conformance-auditor-6` | conformance-auditor | HIGH | F-04 [HIGH] fail2ban jail watches a Synapse log path that is never written |  | duplicate of code-auditor-26 and security-auditor-7 | - |
| `conformance-auditor-7` | conformance-auditor | HIGH | F-05 [HIGH] No Caddy fail2ban jail exists |  | - | - |
| `conformance-auditor-8` | conformance-auditor | MEDIUM | F-06 [MEDIUM] `templates/hardening/` is documented but never read |  | - | - |
| `conformance-auditor-9` | conformance-auditor | MEDIUM | F-07 [MEDIUM] Automatic security updates are a no-op on Arch and ineffective on openSUSE |  | - | - |
| `conformance-auditor-10` | conformance-auditor | LOW | F-08 [LOW] Spec requires generating AppArmor profiles; code deliberately does not |  | - | - |
| `conformance-auditor-11` | conformance-auditor | MEDIUM | F-03 [MEDIUM] `--help` prints two lines of source code | accepted | duplicate of `code-auditor-15`; fixed there | - |
| `conformance-auditor-12` | conformance-auditor | HIGH | F-09 [HIGH] The media purge the timer runs can never authenticate, and targets an unpublished port | rejected | duplicate of `code-auditor-47`; rejected on the same evidence | - |
| `conformance-auditor-13` | conformance-auditor | HIGH | F-10 [HIGH] `advanced.podman_compose_command` is documented, defaulted, and never read | accepted | verified: `advanced.podman_compose_command` was defaulted at `lib/04_config.sh` and read nowhere. Added `config_apply_compose_command`, called from `setup.sh` after `detect_all` (which would otherwise overwrite the choice), plus validation restricting the value to the four documented ones - `COMPOSE_CMD` is expanded unquoted at every call site. A requested tool that is not installed warns and leaves the detected one in place. 9 tests; negative controls: override neutered = 4 reds, validation removed = 1 red. Behaviour change: a config carrying an undocumented value now fails validation instead of being silently ignored. | - |
| `conformance-auditor-14` | conformance-auditor | HIGH | F-11 [HIGH] Backup retention has no weekly tier — the recovery window is 11 days, not 5 weeks | accepted | verified: the generated script kept the `RETENTION_DAILY + RETENTION_WEEKLY` most recent files, an 11-day window against a config advertising 7 daily + 4 weekly. Replaced with two real tiers: the N most recent archives, then one archive per distinct ISO week for the next M weeks; an archive whose name carries no parseable timestamp is never deleted. 23 tests in `tests/test_backup.sh` run the generated script end to end; negative control (single-tier restored) = 2 reds, window collapses from 26 days / 5 ISO weeks to 9 days / 2 weeks. | - |
| `conformance-auditor-15` | conformance-auditor | MEDIUM | F-12 [MEDIUM] `restore.sh` hard-codes `podman compose`, ignoring the detected tool | accepted | verified: `restore.sh` hardcoded `podman compose` in three places. The detected `COMPOSE_CMD` is now written into the script header with printf %q. Negative control (hardcoded) = 1 red. Related to `conformance-auditor-13`, which makes the config setting reach `COMPOSE_CMD` in the first place. | - |
| `conformance-auditor-16` | conformance-auditor | MEDIUM | F-13 [MEDIUM] `restore.sh` verifies the signing key against the current install, not against the server name |  | - | - |
| `conformance-auditor-17` | conformance-auditor | MEDIUM | F-14 [MEDIUM] `SUPPLY_CHAIN.md`'s "only network-fetched package" claim no longer holds |  | duplicate cluster with dependency-auditor-2 and ci-auditor-11 | - |
| `conformance-auditor-18` | conformance-auditor | CRITICAL | F-15 [CRITICAL] The whole deploy phase probes `localhost:8008`, which nothing publishes |  | related to code-auditor-12 (deploy reports success regardless) | - |
| `conformance-auditor-19` | conformance-auditor | MEDIUM | F-16 [MEDIUM] Caddy's healthcheck probes the admin endpoint the Caddyfile turns off |  | - | - |
| `conformance-auditor-20` | conformance-auditor | HIGH | F-17 [HIGH] A Cloudflare token makes Caddy load a DNS module the pinned image does not contain | accepted | verified: `lib/13_caddy.sh` set DNS_CHALLENGE from the presence of `dns.cloudflare_api_token` and the template emitted `acme_dns cloudflare` into `docker.io/library/caddy:2.11.4-alpine`. DECISION (design question 3): **drop DNS-01**, do not ship a custom image. Building and publishing a Caddy+module image would put a self-built image in a supply chain whose whole posture is digest-pinned upstream images, and it cannot be done from here at all; meanwhile the directive as shipped stops Caddy from starting, which takes 80/443 and the rest of the stack with it. Certificates come from HTTP-01/TLS-ALPN; the token keeps its working use (DNS record creation, `lib/07_network.sh`) and the operator is told so at install time. Dead `{{#DNS_CHALLENGE}}` block removed from `templates/configs/Caddyfile.tpl`. 9 tests in `tests/test_caddy.sh`; negative control (emission restored) = 3 reds. Behaviour change: an install that set a Cloudflare token now gets HTTP-01 instead of a Caddy that would not start. LEFTOVER for the `templates/compose/` owner: `caddy.yml` still injects `CF_API_TOKEN` into the Caddy container when a token is set (`lib/19_compose.sh:287`); inert now, but it hands a DNS-editing token to a container with no use for it. UNVERIFIED here: no image was pulled or inspected; the stock-build claim rests on Caddy documenting DNS providers as custom-build modules and on conformance-auditor F-17. | agent decision, 2026-09-10 |
| `conformance-auditor-21` | conformance-auditor | HIGH | F-18 [HIGH] "Skip Caddy and use my existing proxy" cannot take effect |  | related to code-auditor-58 | - |
| `conformance-auditor-22` | conformance-auditor | MEDIUM | F-19 [MEDIUM] Coturn's IPv6 branch reads a config key nothing ever sets |  | - | - |
| `conformance-auditor-23` | conformance-auditor | LOW | F-20 [LOW] Comment markers in the README project tree were corrupted since v0.1.1 |  | - | - |
| `conformance-auditor-24` | conformance-auditor | LOW | F-21 [LOW] Unreleased Arch/AUR work has no CHANGELOG entry |  | - | - |
| `coverage-analyst-1` | coverage-analyst | CRITICAL | F1 [CRITICAL] `_homeserver_synapse` is 0%-covered, and it currently emits invalid YAML on every registration policy |  | - | - |
| `coverage-analyst-2` | coverage-analyst | HIGH | F2 [HIGH] The whole deploy/backup/restore half of the tool has zero executed lines |  | - | - |
| `coverage-analyst-3` | coverage-analyst | HIGH | F3 [HIGH] `network_check_ports` and the Cloudflare DNS writer are wholly untested |  | coverage view of code-auditor-52 / coverage-analyst-13 | - |
| `coverage-analyst-4` | coverage-analyst | MEDIUM | F4 [MEDIUM] `_store_podman_secrets` - the non-default secret backend - is 0-covered |  | coverage view of code-auditor-8 / security-auditor-4 | - |
| `coverage-analyst-5` | coverage-analyst | MEDIUM | F5 [MEDIUM] `test_compose_assembly.sh` never calls `compose_assemble` |  | coverage view of code-auditor-20 / conformance-auditor-3 | - |
| `coverage-analyst-6` | coverage-analyst | MEDIUM | F6 [MEDIUM] `tests/test_rollback.sh:52-57` asserts a precondition, not a rollback |  | same rollback cluster as code-auditor-1 | - |
| `coverage-analyst-7` | coverage-analyst | LOW | F7 [LOW] The pure-Bash TOML fallback is never executed in CI |  | coverage view of code-auditor-17 / compat-auditor-4 | - |
| `coverage-analyst-8` | coverage-analyst | LOW | F8 [LOW] `lib/02_detect.sh` - 1 of 15 functions covered |  | - | - |
| `coverage-analyst-9` | coverage-analyst | HIGH | A1 [HIGH] Bridge registration YAML: every assertion matches the key name, never the value | accepted | verified: every registration assertion was `assert_file_contains "as_token"`, matching the key name, so an empty token passed. The assertions now parse the generated YAML and compare values: the two tokens must equal what was passed, `id` and `sender_localpart` must be non-empty, the user namespace must be scoped to the server name, and `url` must be an http(s) URL. Negative control (as_token emptied in one plugin) = 1 red where it was previously green. | - |
| `coverage-analyst-10` | coverage-analyst | MEDIUM | A2 [MEDIUM] `bridge_compose_fragment` assertions cannot see an empty image | accepted | verified: `assert_match "image:"` matched the key. The fragment is now parsed as YAML and the image value must look like a registry reference **and** be digest-pinned, matching the projects posture for every other image. Negative control (image emptied) = 2 reds. | - |
| `coverage-analyst-11` | coverage-analyst | MEDIUM | A3 [MEDIUM] `bridge_description` / `bridge_requires_synapse` are checked for existence, never called | accepted | verified: both functions were only checked for existence. They are now called - `bridge_description` must return something and `bridge_requires_synapse` must answer true or false. Negative control (description emptied) = 1 red. | - |
| `coverage-analyst-12` | coverage-analyst | HIGH - this is a bug, not dead weight | D1 [HIGH - this is a bug, not dead weight] `setup.sh` looks for a manifest path that `rollback_init_manifest` never creates |  | duplicate of code-auditor-1 | - |
| `coverage-analyst-13` | coverage-analyst | MEDIUM - should be used and is not | D2 [MEDIUM - should be used and is not] `network_cloudflare_create_records` is advertised in the shipped config and called from nowhere |  | duplicate of code-auditor-52 | - |
| `coverage-analyst-14` | coverage-analyst | MEDIUM - superseded implementation, safe to remove *after* D1 | D3 [MEDIUM - superseded implementation, safe to remove *after* D1] the rollback trap layer |  | duplicate of code-auditor-6 | - |
| `coverage-analyst-15` | coverage-analyst | LOW - unused API surface, keep | D4 [LOW - unused API surface, keep] parser and config accessors |  | - | - |
| `coverage-analyst-16` | coverage-analyst | LOW - genuinely removable | D5 [LOW - genuinely removable] three unused utils |  | - | - |
| `coverage-analyst-17` | coverage-analyst | LOW | D6 [LOW] `detect_existing_install` and `print_system_summary` |  | duplicate of code-auditor-62 | - |
| `compat-auditor-1` | compat-auditor | will-crash | F-01 [will-crash] Ubuntu 22.04 and Debian 12 ship Podman below the enforced 4.4.0 floor, and the installer's own remedy reinstalls the same version |  | - | - |
| `compat-auditor-2` | compat-auditor | will-crash | F-02 [will-crash] `_install_podman` asks dnf for a `uidmap` package that does not exist on RHEL-family distros |  | - | - |
| `compat-auditor-3` | compat-auditor | will-crash | F-03 [will-crash] `harden_fail2ban` runs a bare `dnf install fail2ban`, which fails on CentOS Stream 9 / RHEL 9 without EPEL |  | related to code-auditor-34 | - |
| `compat-auditor-4` | compat-auditor | will-crash | F-04 [will-crash] The TOML parser crashes the whole installer when Python lacks `tomllib`, and the pure-Bash fallback it has for exactly this case is unreachable |  | duplicate of code-auditor-17; coverage gap in coverage-analyst-7 | - |
| `compat-auditor-5` | compat-auditor | degraded | F-05 [degraded] Every `pip3 install` fallback is dead on all currently-supported distros (PEP 668) |  | duplicate cluster with code-auditor-71 and dependency-auditor-1 | - |
| `compat-auditor-6` | compat-auditor | silent-corruption | F-06 [silent-corruption] `pacman -Sy` performs an unsupported partial upgrade on Arch |  | duplicate of code-auditor-67 and dependency-auditor-8 | - |
| `compat-auditor-7` | compat-auditor | degraded | F-07 [degraded] On Arch, `_install_podman` never tries the official repo for `podman-compose` and jumps straight to the AUR — for a package that has been in `extra` all along |  | related to dependency-auditor-1 (same Arch podman-compose path). compat-auditor states `podman-compose` has been in Arch `extra` all along; dependency-auditor treats the AUR/pip path as the live one. Not adjudicated here. | - |
| `compat-auditor-8` | compat-auditor | will-crash | F-08 [will-crash] The AUR helper bootstrap cannot succeed on a minimal Arch host: `git` and `sudo` are not in `base`, and `makepkg` is called without `--syncdeps` |  | related to dependency-auditor-10 (PKGBUILD review). NOTE, UNVERIFIED against this finding: commit `c65227f` "fix(arch): harden AUR bootstrap" post-dates the audit and touches this path. | - |
| `compat-auditor-9` | compat-auditor | will-crash | F-09 [will-crash] The generated `matrix-stack.container` Quadlet has no `Image=`, so the Quadlet generator rejects it on every distro | accepted | duplicate of `code-auditor-21`; fixed there | agent decision, 2026-09-10 |
| `compat-auditor-10` | compat-auditor | silent-corruption | F-10 [silent-corruption] `run_as_user systemctl --user` cannot work: `sudo -u` sets no `XDG_RUNTIME_DIR`, and every call site swallows the failure |  | related to compat-auditor-11 (both concern `run_as_user`) | - |
| `compat-auditor-11` | compat-auditor | will-crash | F-11 [will-crash] `run_as_user` hard-requires `sudo`, which the same codebase already knows Arch may not have |  | related to compat-auditor-10 | - |
| `compat-auditor-12` | compat-auditor | will-crash | F-12 [will-crash] `harden_sysctl` aborts the installer on any host with IPv6 disabled, and every hardening sub-step can kill the run the same way |  | - | - |
| `compat-auditor-13` | compat-auditor | degraded | F-13 [degraded] The nftables fallback ruleset breaks IPv6 and does not survive a reboot |  | duplicate of code-auditor-27 | - |
| `compat-auditor-14` | compat-auditor | degraded | F-14 [degraded] The fail2ban jail relies on `backend = auto` finding `/var/log/auth.log`, which Ubuntu 24.04 no longer produces |  | related to code-auditor-28 and code-auditor-26 (same jail) | - |
| `compat-auditor-15` | compat-auditor | degraded | F-15 [degraded] `_enable_podman_socket` enables the *root* podman socket in an otherwise rootless deployment |  | duplicate of code-auditor-68 and dependency-auditor-7 | - |
| `compat-auditor-16` | compat-auditor | degraded | F-16 [degraded] openSUSE is a claimed platform with no test coverage and an unverified package list |  | - | - |
| `compat-auditor-17` | compat-auditor | degraded | F-17 [degraded] The SSH hardening drop-in is written without checking that `sshd_config` includes the drop-in directory |  | duplicate of code-auditor-31 | - |
| `dependency-auditor-1` | dependency-auditor | HIGH | DEP-001 - HIGH - Unpinned `pip3 install podman-compose` on the Arch path, contradicting the documented posture |  | duplicate cluster with code-auditor-71 and compat-auditor-5; see compat-auditor-7 for the contradicting account of the Arch package path | - |
| `dependency-auditor-2` | dependency-auditor | HIGH | DEP-002 - HIGH - `docs/SUPPLY_CHAIN.md` omits the AUR path entirely, understating what the installer executes |  | duplicate cluster with conformance-auditor-17 and ci-auditor-11 | - |
| `dependency-auditor-3` | dependency-auditor | HIGH | DEP-003 - HIGH - Pinned Synapse `v1.127.1` carries three published advisories, one HIGH |  | - | - |
| `dependency-auditor-4` | dependency-auditor | MEDIUM | DEP-004 - MEDIUM - `pin-digests.sh` trusts the registry's `Docker-Content-Digest` header instead of computing the digest |  | - | - |
| `dependency-auditor-5` | dependency-auditor | MEDIUM | DEP-005 - MEDIUM - No image signature or provenance verification at pull time |  | - | - |
| `dependency-auditor-6` | dependency-auditor | MEDIUM | DEP-006 - MEDIUM - `pin-digests.sh --check` runs only at release; nothing verifies a version bump was re-pinned |  | - | - |
| `dependency-auditor-7` | dependency-auditor | MEDIUM | DEP-007 - MEDIUM - `_enable_podman_socket` enables the **root** Podman API socket, while the comment claims it is for rootless |  | duplicate of code-auditor-68 and compat-auditor-15 | - |
| `dependency-auditor-8` | dependency-auditor | MEDIUM | DEP-008 - MEDIUM - `pacman -Sy` without `-u` sets up a partial upgrade |  | duplicate of code-auditor-67 and compat-auditor-6 | - |
| `dependency-auditor-9` | dependency-auditor | MEDIUM | DEP-009 - MEDIUM - Broad image currency gap; several pins carry applicable advisories |  | - | - |
| `dependency-auditor-10` | dependency-auditor | LOW | DEP-010 - LOW - PKGBUILD review displays untrusted content with `cat` and does not cover fetched sources |  | related to compat-auditor-8 | - |
| `dependency-auditor-11` | dependency-auditor | LOW | DEP-011 - LOW - The release workflow does not gate on tests or lint |  | duplicate of ci-auditor-2 | - |
| `dependency-auditor-12` | dependency-auditor | LOW | DEP-012 - LOW - `cosign-installer` pinned to v3.9.1 (June 2025), two majors behind |  | - | - |
| `dependency-auditor-13` | dependency-auditor | LOW | DEP-013 - LOW - The digest drift gate turns a routine upstream event into a release failure | accepted | DECISION (design question 4): **fail**, as it already does; the friction dependency-auditor objects to is answered in the message rather than by weakening the gate. A tag moving under a pin is precisely the event pinning exists to detect, and a release is a deliberate act, so the pins that ship should be pins someone looked at; warning would let a release go out against a tag nobody reviewed. `--check` now counts the drifted images and prints the re-pin command (`scripts/pin-digests.sh && git diff lib/00_constants.sh`) instead of exiting 1 silently. The contradiction with `ci-auditor-5` is resolved: that row was about a vacuous pass on zero/partially parsed images, already fixed, and both rows now point the same way - fail closed. 3 tests added to `tests/test_pin_digests.sh`; negative control (summary removed) = 2 reds. | agent decision, 2026-09-10 |
| `dependency-auditor-14` | dependency-auditor | LOW | DEP-014 - LOW - UNVERIFIED: the claimed `ghcr.io/mautrix/<bridge>` mirrors could not be confirmed |  | - | - |
| `dependency-auditor-15` | dependency-auditor | LOW | DEP-015 - LOW - SBOM coverage stops at container images; the installer's own host-package surface is unrecorded |  | - | - |
| `dependency-auditor-16` | dependency-auditor | INFO | DEP-016 - INFO - `ifconfig.me` is a third-party dependency in the install path |  | - | - |
| `ci-auditor-1` | ci-auditor | HIGH | [HIGH] The CI job gates nothing — `main` has no branch protection and no rulesets |  | - | - |
| `ci-auditor-2` | ci-auditor | HIGH | [HIGH] A tag push publishes a signed, attested release without running lint or tests |  | duplicate of dependency-auditor-11 | - |
| `ci-auditor-3` | ci-auditor | MEDIUM | [MEDIUM] `test_runner.sh` derives its exit code and its summary line from independent sources, which can disagree |  | - | - |
| `ci-auditor-4` | ci-auditor | MEDIUM | [MEDIUM] The release signs artifacts but never verifies that the signature it just produced is verifiable |  | - | - |
| `ci-auditor-5` | ci-auditor | MEDIUM | [MEDIUM] The digest drift gate passes vacuously if it finds zero images |  | CONTRADICTION with dependency-auditor-13 - see that row | - |
| `ci-auditor-6` | ci-auditor | MEDIUM | [MEDIUM] The `pull_request` path has never executed |  | - | - |
| `ci-auditor-7` | ci-auditor | LOW | [LOW] The lint gate cannot fail on any `info`-severity finding |  | - | - |
| `ci-auditor-8` | ci-auditor | LOW | [LOW] ShellCheck itself is installed unpinned from apt |  | - | - |
| `ci-auditor-9` | ci-auditor | LOW | [LOW] `runs-on: ubuntu-latest` in the release workflow |  | - | - |
| `ci-auditor-10` | ci-auditor | LOW | [LOW] `tests/distro/test_integration.sh` is never executed by anything |  | - | - |
| `ci-auditor-11` | ci-auditor | LOW | [LOW] `docs/SUPPLY_CHAIN.md:22` overstates when CI runs |  | duplicate cluster with conformance-auditor-17 and dependency-auditor-2 | - |
| `ci-auditor-12` | ci-auditor | LOW | [LOW] Repo Actions policy does not enforce the pinning discipline the workflows follow |  | - | - |
| `ci-auditor-13` | ci-auditor | LOW | [LOW] Both pinned action versions are behind the current major |  | - | - |
| `ci-auditor-14` | ci-auditor | INFO | [INFO] No `concurrency` group on either workflow |  | - | - |
| `ci-auditor-15` | ci-auditor | INFO | [INFO] Every release gets the entire CHANGELOG as its release notes |  | - | - |
| `security-auditor-1` | security-auditor | CRITICAL | F0 [CRITICAL] Re-running the installer replaces every homeserver secret with the literal string `GENERATE_ME` (confidence 5) | accepted | fixed in working tree; `tests/test_security_regression.sh` section 3b, 14 new assertions, negative control verified. Duplicate of code-auditor-7. The defect is accepted; this finding's stated impact of arbitrary-user account takeover is **rejected**: `macaroon_secret_key` signs only guest tokens, `delete_pusher` links and OIDC session cookies (`synapse/util/macaroons.py`); a macaroon presented as a normal access token is rejected unless the DB user has `is_guest=true`. The re-run defect is a High availability bug, not account takeover. `registration_shared_secret` is the severe key. | - |
| `security-auditor-2` | security-auditor | CRITICAL | F1 [CRITICAL] Config value reaches a `sed` script unescaped — root command execution (confidence 5) | accepted | fixed in working tree; 24 new tests across `test_compose_assembly.sh` and `test_config_validation.sh`, per-fix negative controls verified. `lib/19_compose.sh:189` now escapes the four-character escape class; `monitoring.grafana_subdomain` and `dns.cloudflare_api_token` validated at `lib/04_config.sh:216-229`. Duplicate of code-auditor-23. | - |
| `security-auditor-3` | security-auditor | HIGH | F2 [HIGH] `homeserver.yaml` holds five secrets and is written world-readable (0644) (confidence 5) |  | OPEN: no `chmod` follows the `template_render` call in `lib/12_homeserver.sh` as of this reading; other agents are editing `lib/` concurrently, so re-check before acting. Scoped rejection of one impact clause only - this finding's claim that `macaroon_secret_key` lets a local reader forge access tokens for any user is **rejected**: `macaroon_secret_key` signs only guest tokens, `delete_pusher` links and OIDC session cookies (`synapse/util/macaroons.py`); a macaroon presented as a normal access token is rejected unless the DB user has `is_guest=true`. The re-run defect is a High availability bug, not account takeover. `registration_shared_secret` is the severe key. The `registration_shared_secret` exposure this row also names stands. | - |
| `security-auditor-4` | security-auditor | HIGH | F3 [HIGH] `--podman-secrets` mode stores secrets nothing consumes, and leaves plaintext on disk anyway (confidence 5) |  | duplicate of code-auditor-8; coverage gap in coverage-analyst-4 | - |
| `security-auditor-5` | security-auditor | HIGH | F4 [HIGH] Backup archives carry the signing key and every config secret, unencrypted and world-readable (confidence 4) | accepted | same fix and decision as `code-auditor-42`. The severity disagreement is moot now: the archive is 0600 in a 0700 directory either way. | agent decision, 2026-09-10 |
| `security-auditor-6` | security-auditor | MEDIUM | F5 [MEDIUM] `backup.retention_daily`/`retention_weekly` reach a bash arithmetic context — command execution in the daily timer (confidence 5) | accepted | duplicate of `code-auditor-36`; fixed there, with the same correction to the stated mechanism (the bare `$(cmd)` operand does not execute; the array-subscript form does). | - |
| `security-auditor-7` | security-auditor | MEDIUM | F6 [MEDIUM] The fail2ban Matrix jail watches a log path that is never written (confidence 5) |  | duplicate of code-auditor-26 and conformance-auditor-6 | - |
| `security-auditor-8` | security-auditor | MEDIUM | F7 [MEDIUM] `net.ipv4.ip_unprivileged_port_start=80` opens ports 80-1023 to every local user (confidence 4) |  | - | - |
| `security-auditor-9` | security-auditor | MEDIUM | F8 [MEDIUM] The rollback path can never find its manifest, so failed installs are never cleaned up (confidence 5) |  | duplicate of code-auditor-1 / code-auditor-2; dead-code view in coverage-analyst-12 | - |

## Triage 1: difficulty

Difficulty is the cost of the *fix*, not the severity of the defect.
`trivial` = one-line or constant change. `moderate` = single-function change
plus a test. `hard` = cross-module change, behaviour change, or a rewrite.
`needs-decision` = cannot be fixed until the user picks between options.

### trivial

- `code-auditor-1` - consult the live `MANIFEST_FILE` instead of re-deriving the path
- `code-auditor-5` - add the `rollback_cleanup` call
- `code-auditor-10` - stop writing the two secret keys to the state file
- `code-auditor-13` - stop swallowing the coturn start failure
- `code-auditor-15` - replace the `--help` body
- `code-auditor-16` - delete the dead local
- `code-auditor-19` - replace the per-character subshell
- `code-auditor-22` - `chown` the three home subdirectories
- `code-auditor-34` - guard the jail write on fail2ban being installed
- `code-auditor-38` - propagate the `pg_restore` exit status
- `code-auditor-39` - trap-clean the uncompressed copy
- `code-auditor-45` - call `config_validate` on the `--upgrade` path
- `code-auditor-48` - delete the two unused computed values
- `code-auditor-49` - create the directory explicitly
- `code-auditor-55` - delete the dead coturn template and fallback
- `code-auditor-57` - count configured bridges, not requested ones
- `code-auditor-61` - correct `TOTAL_STEPS`
- `code-auditor-62` - call it or delete it (see `coverage-analyst-17`)
- `code-auditor-63` - register the snippet with rollback
- `code-auditor-64` - parse `df` with `--output` or `-P`
- `code-auditor-67` - `pacman -Syu`
- `code-auditor-69` - re-check after install
- `code-auditor-70` - drop the `jq` prerequisite
- `conformance-auditor-1` - read the documented key
- `conformance-auditor-11` - duplicate of `code-auditor-15`
- `conformance-auditor-17` - documentation edit
- `conformance-auditor-19` - probe an endpoint the Caddyfile serves
- `conformance-auditor-22` - set or drop the coturn IPv6 key
- `conformance-auditor-23` - restore the README tree markers
- `conformance-auditor-24` - add the CHANGELOG entry
- `coverage-analyst-10` - assert on the image value, not the key
- `coverage-analyst-11` - call the two functions in the test
- `coverage-analyst-12` - duplicate of `code-auditor-1`
- `coverage-analyst-15` - no action; the report recommends keeping these
- `coverage-analyst-16` - delete the three unused utils
- `coverage-analyst-17` - delete or wire up (see `code-auditor-62`)
- `compat-auditor-2` - drop `uidmap` from the dnf package list
- `compat-auditor-6` - duplicate of `code-auditor-67`
- `compat-auditor-7` - try `pacman -S podman-compose` before the AUR
- `dependency-auditor-2` - documentation edit
- `dependency-auditor-8` - duplicate of `code-auditor-67`
- `dependency-auditor-12` - bump the pinned `cosign-installer`
- `ci-auditor-5` - fail the drift gate when the image count is zero
- `ci-auditor-6` - open one PR to exercise the path
- `ci-auditor-9` - pin the runner image
- `ci-auditor-11` - documentation edit
- `ci-auditor-13` - bump both pinned actions
- `ci-auditor-14` - add the `concurrency` group
- `security-auditor-9` - duplicate of `code-auditor-1`

### moderate

- `code-auditor-2` - select the newest manifest by glob
- `code-auditor-3` - implement the three ignored action types
- `code-auditor-4` - record deploy actions in the manifest
- `code-auditor-9` - fix CLI-over-config precedence
- `code-auditor-12` - make `deploy_run` exit non-zero on a failed health check
- `code-auditor-18` - reject or preserve multi-line TOML values
- `code-auditor-25` - add the `log.config` template and render it
- `code-auditor-27` - read the real SSH port before writing the ruleset
- `code-auditor-29` - restore the backup instead of deleting
- `code-auditor-30` - scope the lockout guard to the invoking user
- `code-auditor-31` - append directly when no `Include` exists
- `code-auditor-32` - restore prior sysctl values on rollback
- `code-auditor-33` - check the range, not just presence
- `code-auditor-36` - validate the retention values as integers
- `code-auditor-40` - read the validated DB name and user
- `code-auditor-44` - implement or remove the reconfigure option
- `code-auditor-46` - preserve existing bridge tokens and restart
- `code-auditor-50` - gate coturn TLS on a path something creates
- `code-auditor-51` - pass the Cloudflare token by env or stdin
- `code-auditor-53` - use the public-suffix-aware zone lookup
- `code-auditor-54` - fail on unmatched `{{PLACEHOLDER}}` tokens
- `code-auditor-56` - namespace the per-bridge registration function
- `code-auditor-59` - restore the stopped proxy on rollback
- `code-auditor-60` - classify on `ID_LIKE`
- `code-auditor-65` - source `/etc/os-release` in a subshell
- `code-auditor-68` - enable the user socket, not the root one
- `code-auditor-71` - hash-pin the pip fallback
- `conformance-auditor-2` - duplicate of `code-auditor-9`
- `conformance-auditor-4` - duplicate of `code-auditor-25`
- `conformance-auditor-5` - set a generated Grafana admin password
- `conformance-auditor-7` - add the Caddy jail
- `conformance-auditor-9` - implement the Arch and openSUSE update paths
- `conformance-auditor-13` - read `advanced.podman_compose_command`
- `conformance-auditor-15` - use the detected compose tool in `restore.sh`
- `conformance-auditor-16` - verify the key against the server name
- `coverage-analyst-3` - add tests for `network_check_ports` and the DNS writer
- `coverage-analyst-4` - add a test for `_store_podman_secrets`
- `coverage-analyst-5` - call `compose_assemble` in the test
- `coverage-analyst-6` - assert the rollback, not the precondition
- `coverage-analyst-7` - execute the pure-Bash TOML path in CI
- `coverage-analyst-8` - add `lib/02_detect.sh` tests
- `coverage-analyst-9` - assert on values, not key names
- `compat-auditor-3` - enable EPEL or drop fail2ban on RHEL-family
- `compat-auditor-8` - complete the AUR bootstrap prerequisites
- `compat-auditor-11` - drop the hard `sudo` requirement
- `compat-auditor-12` - make the sysctl steps non-fatal
- `compat-auditor-13` - add IPv6 rules and persist the ruleset
- `compat-auditor-14` - point the jail at the journal
- `compat-auditor-15` - duplicate of `code-auditor-68`
- `compat-auditor-17` - duplicate of `code-auditor-31`
- `dependency-auditor-3` - bump and re-pin Synapse
- `dependency-auditor-4` - compute the digest locally
- `dependency-auditor-6` - run `pin-digests.sh --check` in CI
- `dependency-auditor-7` - duplicate of `code-auditor-68`
- `dependency-auditor-9` - bump the stale image pins
- `dependency-auditor-10` - review fetched sources, not just the PKGBUILD
- `dependency-auditor-11` - duplicate of `ci-auditor-2`
- `ci-auditor-2` - gate the release workflow on lint and tests
- `ci-auditor-3` - derive exit code and summary from one source
- `ci-auditor-4` - verify the signature after producing it
- `ci-auditor-8` - pin the ShellCheck version
- `ci-auditor-10` - run `tests/distro/test_integration.sh`
- `ci-auditor-15` - extract the current release's CHANGELOG section
- `security-auditor-3` - `chown` + `chmod 640`; must land with the ownership model
- `security-auditor-5` - `umask 077` in the generated backup script
- `security-auditor-6` - duplicate of `code-auditor-36`

### hard

- `code-auditor-11` - reset the Postgres role password on a regenerated secret
- `code-auditor-14` - implement the Dendrite admin path (or drop Dendrite: `needs-decision`)
- `code-auditor-17` - make the pure-Bash TOML fallback reachable
- `code-auditor-20` - rewrite compose assembly to merge, not concatenate
- `code-auditor-26` - depends on `code-auditor-25`; Synapse must log to the watched file
- `code-auditor-28` - depends on `code-auditor-25`; needs the real log format
- `code-auditor-35` - define and apply an ownership model across every phase
- `code-auditor-37` - make restore work on a clean host
- `code-auditor-41` - implement the daily and weekly retention tiers
- `code-auditor-43` - run upgrade rootless and make the PG guard fire
- `code-auditor-47` - provision the admin token the purge needs
- `code-auditor-58` - honour the proxy-detection outcome
- `conformance-auditor-3` - duplicate of `code-auditor-20`
- `conformance-auditor-6` - duplicate of `code-auditor-26`
- `conformance-auditor-12` - duplicate of `code-auditor-47`
- `conformance-auditor-14` - duplicate of `code-auditor-41`
- `conformance-auditor-18` - publish the probed port or probe what is published
- `conformance-auditor-21` - duplicate of `code-auditor-58`
- `coverage-analyst-1` - fix the YAML emission and cover the function
- `coverage-analyst-2` - build out the deploy/backup/restore test surface
- `compat-auditor-4` - duplicate of `code-auditor-17`
- `compat-auditor-10` - give `run_as_user` a working user-session context
- `dependency-auditor-5` - verify image signatures at pull time
- `dependency-auditor-15` - extend the SBOM to host packages
- `security-auditor-7` - duplicate of `code-auditor-26`

### needs-decision

- `code-auditor-6` - which error/interrupt handler survives (with `coverage-analyst-14`)
- `code-auditor-8` - wire Podman secrets through, or remove the flag
- `code-auditor-21` - Quadlet unit design: pod unit or per-service units
- `code-auditor-42` - change the backup encryption default, or document the risk
- `code-auditor-52` - wire up `lib/07_network.sh` or delete the dead half
- `code-auditor-66` - marked `UNVERIFIED:` by its author; verify the premise first
- `conformance-auditor-8` - use `templates/hardening/` or delete it
- `conformance-auditor-10` - generate AppArmor profiles, or amend the spec
- `conformance-auditor-20` - a Caddy image with the DNS module, or drop DNS-01
- `coverage-analyst-13` - wire up or delete (with `code-auditor-52`)
- `coverage-analyst-14` - remove only after `coverage-analyst-12` is fixed
- `compat-auditor-1` - raise the Podman floor's remedy, or drop Ubuntu 22.04 / Debian 12
- `compat-auditor-5` - `--break-system-packages`, a venv, or drop the pip fallback
- `compat-auditor-9` - duplicate of `code-auditor-21`
- `compat-auditor-16` - test openSUSE or remove the claim from the README
- `dependency-auditor-1` - follows from `compat-auditor-5` / `compat-auditor-7`
- `dependency-auditor-13` - warn or fail on digest drift (see `ci-auditor-5`)
- `dependency-auditor-14` - marked `UNVERIFIED` by its author; confirm the mirrors first
- `dependency-auditor-16` - keep `ifconfig.me`, self-host, or drop the lookup
- `ci-auditor-1` - repo settings change; needs the user or a repo admin
- `ci-auditor-7` - whether `info`-severity ShellCheck findings should fail CI
- `ci-auditor-12` - repo Actions policy; needs the user or a repo admin
- `security-auditor-4` - duplicate of `code-auditor-8`
- `security-auditor-8` - keep `ip_unprivileged_port_start=80` or bind differently

### already dispositioned (not re-triaged)

`code-auditor-7`, `code-auditor-23`, `code-auditor-24`, `security-auditor-1`,
`security-auditor-2` - all `accepted`, fixed in the working tree.

Counts: trivial 49, moderate 66, hard 25, needs-decision 24, already
dispositioned 5. Total 169.

## Triage 2: proposed batches

Ordered by severity first, then by difficulty within severity. Batch 0 is
already landed. **Batch D must be answered before Batches 1, 2, 5, 6, 7 and 8
can be scheduled** - the decisions in it change what those fixes are.

### Batch 0 - landed (accepted)

`code-auditor-7`, `security-auditor-1` (secrets re-run);
`security-auditor-2`, `code-auditor-23`, `code-auditor-24` (compose renderer
escaping, loud sed failure, `monitoring.grafana_subdomain` and
`dns.cloudflare_api_token` validation).

Files already touched: `lib/01_utils.sh`, `lib/04_config.sh`, `lib/08_secrets.sh`,
`lib/19_compose.sh`, `tests/test_compose_assembly.sh`,
`tests/test_config_validation.sh`, `tests/test_security_regression.sh`.
**Every later batch that edits those files rebases on this work.**

### Batch D - decisions, before anything else

`compat-auditor-1`, `compat-auditor-5`, `compat-auditor-16`,
`dependency-auditor-1` (which platforms are actually supported - the README
claims outrun the tested set); `code-auditor-8` / `security-auditor-4` (wire
Podman secrets through or remove the flag); `code-auditor-21` /
`compat-auditor-9` (Quadlet unit design); `code-auditor-14` (Dendrite);
`code-auditor-42` / `security-auditor-5` (backup encryption default);
`code-auditor-52` / `coverage-analyst-13` (wire up or delete
`lib/07_network.sh`); `conformance-auditor-8`, `conformance-auditor-10`
(hardening templates, AppArmor); `conformance-auditor-20` (Caddy DNS module);
`security-auditor-8` (unprivileged port start); `code-auditor-6` /
`coverage-analyst-14` (which handler survives); `ci-auditor-1`, `ci-auditor-7`,
`ci-auditor-12` (repo settings - the user or a repo admin, not an agent);
`dependency-auditor-13` vs `ci-auditor-5` (digest gate, contradictory
readings); `dependency-auditor-14`, `dependency-auditor-16`, `code-auditor-66`
(all three need a fact verified before a fix exists).

### Batch 1 - CRITICAL: the stack cannot start

`code-auditor-20` / `conformance-auditor-3` (repeated `services:` key),
`code-auditor-25` / `conformance-auditor-4` (`log.config` never rendered),
`coverage-analyst-1` (`_homeserver_synapse` emits invalid YAML),
`coverage-analyst-5` (`compose_assemble` untested), `code-auditor-54`
(unmatched placeholders), `conformance-auditor-18` / `code-auditor-12`
(`localhost:8008` probe), `conformance-auditor-19` (Caddy healthcheck).

Files: `lib/19_compose.sh`, `lib/12_homeserver.sh`, `lib/21_deploy.sh`,
`templates/compose/*`, `templates/configs/*`.
**Collides with Batch 0** (`lib/19_compose.sh`), **Batch 3** and **Batch 5**
(same compose fragments), **Batch 8** (Caddy fragment and Caddyfile), and
**Batch 10** (`lib/00_constants.sh` image pins).

### Batch 2 - CRITICAL/HIGH: ownership and the rootless runtime

`code-auditor-35` (install directory root-owned), `code-auditor-22`
(`~/.config` and friends), `security-auditor-3` (`homeserver.yaml` 0644),
`compat-auditor-10`, `compat-auditor-11` (`run_as_user`), plus
`code-auditor-21` / `compat-auditor-9` once Batch D settles the Quadlet design.

**These must land together.** `security-auditor-3`'s own note says a bare
`chmod 600` breaks the rootless bind mount - the mode fix is only correct
alongside the ownership model from `code-auditor-35`.

### Batch 3 - CRITICAL: exposed Grafana

`conformance-auditor-5`. Small, but it edits the monitoring compose fragment,
so it lands after Batch 1's assembly rewrite.

### Batch 4 - HIGH: the rollback subsystem

`code-auditor-1` / `coverage-analyst-12` / `security-auditor-9`,
`code-auditor-2`, `code-auditor-3`, `code-auditor-4`, `code-auditor-5`,
`code-auditor-59`, `code-auditor-63`, `coverage-analyst-6`, and
`code-auditor-6` / `coverage-analyst-14` after Batch D.

All touch `setup.sh:72,95` and `lib/25_rollback.sh`. One batch, one branch;
splitting them guarantees conflicts. Independent of Batches 1-3.

### Batch 5 - HIGH: the secrets backend

`code-auditor-8` / `security-auditor-4` / `coverage-analyst-4`,
`code-auditor-9` / `conformance-auditor-2`, `code-auditor-10`.
Gated on Batch D. **Collides with Batch 1**: wiring Podman secrets adds
`secrets:` blocks to the same compose fragments Batch 1 rewrites.

### Batch 6 - HIGH: config parsing and the platform floor

`code-auditor-17` / `compat-auditor-4` / `coverage-analyst-7` (unreachable
TOML fallback), `code-auditor-18`, `code-auditor-19`, `compat-auditor-2`,
`compat-auditor-3`, `compat-auditor-7`, `compat-auditor-8`, `code-auditor-60`,
`code-auditor-67` / `compat-auditor-6` / `dependency-auditor-8`,
`code-auditor-68` / `compat-auditor-15` / `dependency-auditor-7`,
`code-auditor-69`, `code-auditor-70`, `code-auditor-71`.
Gated on Batch D's platform answer. Files: `lib/03_prereq.sh`,
`lib/05_toml.sh`, `lib/02_detect.sh` - no overlap with Batches 1-5.

### Batch 7 - HIGH: host hardening

`code-auditor-27` / `compat-auditor-13` (nftables), `code-auditor-29`,
`code-auditor-30`, `code-auditor-31` / `compat-auditor-17`, `code-auditor-32`,
`code-auditor-33`, `code-auditor-34`, `compat-auditor-12`,
`conformance-auditor-7`, `conformance-auditor-9`.
Then, **only after Batch 1 ships `log.config`**: `code-auditor-26` /
`conformance-auditor-6` / `security-auditor-7` and `code-auditor-28` /
`compat-auditor-14`. The jail cannot be fixed while the log it watches is
never written.

### Batch 8 - HIGH: proxy, DNS and coturn

`code-auditor-58` / `conformance-auditor-21`, `conformance-auditor-20`,
`code-auditor-50`, `code-auditor-51`, `code-auditor-53`,
`conformance-auditor-22`, `code-auditor-52` / `coverage-analyst-13` /
`coverage-analyst-3`.
**Collides with Batch 1** on the Caddy compose fragment and the Caddyfile
template.

### Batch 9 - HIGH/MEDIUM: backup, restore, upgrade, media

`conformance-auditor-14` / `code-auditor-41`, `security-auditor-5` /
`code-auditor-42`, `security-auditor-6` / `code-auditor-36`, `code-auditor-37`,
`code-auditor-38`, `code-auditor-39`, `code-auditor-40`, `code-auditor-43`,
`code-auditor-44`, `code-auditor-45`, `code-auditor-46`, `code-auditor-47` /
`conformance-auditor-12`, `code-auditor-48`, `code-auditor-49`,
`conformance-auditor-13`, `conformance-auditor-15`, `conformance-auditor-16`,
`coverage-analyst-2`.
Files: `lib/22_backup.sh`, `lib/23_upgrade.sh`, `lib/24_media.sh`,
`scripts/restore.sh`. **No overlap with Batches 1-8 - this can run in
parallel with them.**

### Batch 10 - supply chain and CI

`ci-auditor-2` / `dependency-auditor-11`, `dependency-auditor-3`,
`dependency-auditor-9`, `dependency-auditor-4`, `dependency-auditor-5`,
`dependency-auditor-6`, `dependency-auditor-10`, `dependency-auditor-12`,
`dependency-auditor-15`, `ci-auditor-3`, `ci-auditor-4`, `ci-auditor-5`,
`ci-auditor-6`, `ci-auditor-8`, `ci-auditor-9`, `ci-auditor-10`,
`ci-auditor-13`, `ci-auditor-14`, `ci-auditor-15`, plus the documentation
trio `dependency-auditor-2` / `conformance-auditor-17` / `ci-auditor-11`.
Files: `.github/workflows/`, `scripts/`, `docs/`. **Collision:**
`dependency-auditor-3` and `dependency-auditor-9` re-pin
`lib/00_constants.sh:31-49`, which Batch 1 also reads - land the re-pin either
before Batch 1 starts or after it merges, not alongside.

### Batch 11 - LOW cleanup, no dependencies

`code-auditor-13`, `code-auditor-15` / `conformance-auditor-11`,
`code-auditor-16`, `code-auditor-55`, `code-auditor-56`, `code-auditor-57`,
`code-auditor-61`, `code-auditor-62` / `coverage-analyst-17`,
`code-auditor-64`, `code-auditor-65`, `conformance-auditor-1`,
`conformance-auditor-23`, `conformance-auditor-24`, `coverage-analyst-8`,
`coverage-analyst-9`, `coverage-analyst-10`, `coverage-analyst-11`,
`coverage-analyst-15`, `coverage-analyst-16`.
Single-file, independent, safe to hand to one agent last. `code-auditor-11`
(Postgres role password) is HIGH-consequence and `hard`; it sits with Batch 9
rather than here.

### Collision summary

| Pair | Shared surface |
|---|---|
| Batch 0 <-> 1, 5 | `lib/19_compose.sh`, `lib/01_utils.sh` |
| Batch 1 <-> 3, 5, 8 | `templates/compose/*` fragments |
| Batch 1 <-> 10 | `lib/00_constants.sh` image pins |
| Batch 1 -> 7 | fail2ban rows blocked until `log.config` renders |
| Batch 2 internal | `chmod`/`chown` fixes are only correct together |
| Batch 4 internal | `setup.sh:72,95` + `lib/25_rollback.sh` |
| Batch D -> 1, 2, 5, 6, 7, 8 | decisions change the shape of the fix |

## Decisions taken (2026-09-10)

Approved by: user (daemon45@gmail.com), 2026-09-10. These resolve the
`needs-decision` rows named in each line and unblock Batches 1, 2, 5, 6, 7, 8.

| Decision | Choice | Rows resolved |
|---|---|---|
| Platform support | Narrow README: drop Ubuntu 22.04 and Debian 12 (podman 3.4.4 / 4.3.1, both below the 4.4.0 floor Quadlet requires; no backports exist). Keep openSUSE and make it real: add a Vagrant box, verify package names, exercise all five `opensuse*` case branches. `_install_podman` must fail with an actionable message naming the required version. | `compat-auditor-1`, `compat-auditor-16` |
| Podman secrets | Wire `--podman-secrets` through properly: compose templates consume podman secrets, the `.env` path stays for default mode, tests must prove a podman-secrets install actually starts. | `code-auditor-8`, `security-auditor-4` |
| Unwired subsystems | Wire everything up, including AppArmor profile generation so the spec becomes true. Covers `lib/07_network.sh`'s dead half, `templates/hardening/`, AppArmor, and `validate_regex`. | `code-auditor-52`, `coverage-analyst-13`, `conformance-auditor-8`, `conformance-auditor-10` |
| Dendrite | Implement the Dendrite admin path to the same bar as Synapse. Dendrite then needs equal coverage elsewhere. | `code-auditor-14` |

Not actionable in code - needs the user or a repo admin in GitHub settings:
`ci-auditor-1` (no branch protection on `main`), `ci-auditor-12` (repo Actions policy).

Still open, second decision batch: `code-auditor-6`/`coverage-analyst-14` (which
error/interrupt handler survives), `code-auditor-21`/`compat-auditor-9` (Quadlet
pod unit vs per-service units), `code-auditor-42` (backup encryption default),
`code-auditor-66` (UNVERIFIED premise - verify first), `conformance-auditor-20`
(Caddy image with DNS module vs drop DNS-01), `compat-auditor-5`/`dependency-auditor-1`
(`--break-system-packages` vs venv vs drop pip fallback), `dependency-auditor-13`/`ci-auditor-5`
(warn vs fail on digest drift), `dependency-auditor-14` (UNVERIFIED mirrors - confirm first),
`dependency-auditor-16` (`ifconfig.me` - keep, self-host, or drop), `ci-auditor-7`
(should `info`-severity ShellCheck fail CI), `security-auditor-8`
(`ip_unprivileged_port_start=80` vs bind differently).

## Found during remediation (not in the original audit)

Rows added 2026-09-10. None of these came from the seven auditors; each was
surfaced by an agent while fixing something else.

| ID | Source | Severity | Finding | Disposition | Evidence / Link | Approved by |
|---|---|---|---|---|---|---|
| `remed-1` | fix-compose | High | `_quadlet_generate_coturn` (`lib/20_quadlet.sh:99-130`) omits the `{{#TLS}}` certificate mount that `coturn.yml` carries, so TLS-enabled coturn gets no certs on the Quadlet path - the primary path. Same at the `podman run` fallback (`lib/21_deploy.sh:183-188`). | accepted | verified and widened. The divergence was real but all three paths were TLS-off in practice: `CONFIG[coturn.tls]`, which `lib/19_compose.sh:277` feeds to the fragment, was never set by anything, and `coturn_setup` kept its decision in a local. `lib/14_coturn.sh` now publishes `coturn.tls` + `coturn.cert_dir`; `_quadlet_generate_coturn` and the `podman run` fallback mount the same directory the fragment does. 12 tests in `tests/test_coturn_tls.sh` (both polarities on each path); negative controls: publication removed = 6 reds, quadlet volume = 1 red, podman mount = 1 red. `_quadlet_generate_coturn` gained a `QUADLET_SYSTEM_DIR` test hook (default unchanged). | - |
| `remed-2` | fix-rollback | High | `CONFIG[install_dir]` is never populated from TOML. The example config nests `install_dir` under `[advanced]`, so it parses as `advanced.install_dir` and nothing in `lib/` reads that key. Duplicate of `code-auditor-...` (`advanced.` prefix cluster) - cross-check before fixing. | accepted | verified against the current tree: every consumer reads `CONFIG[install_dir]` / `CONFIG[matrix_user]` while the parser produces `advanced.install_dir` / `advanced.matrix_user`. Fixed by `_config_alias_advanced` in `config_load` (a bare top-level key still wins), which also lets the existing install_dir validation see the value. 5 tests in `tests/test_config_validation.sh`; negative control (alias call removed) = 3 reds. | - |
| `remed-3` | fix-toml | Medium | With `tomllib` present, a malformed TOML file still falls through to the Bash subset parser, which skips unparseable lines and yields a silently partial config. Now warned rather than silent, but still partial. | | | |
| `remed-4` | orchestrator | Medium | `ci.yml` does not guarantee PyYAML is installed. `tests/test_compose_assembly.sh` skips its parse assertions without it, so the regression test for the compose-merge defect would silently stop running in CI. | | | |
| `remed-5` | work-podman-secrets | Critical | `templates/compose/monitoring.yml` uses `${GRAFANA_ADMIN_PASSWORD:-admin}` and nothing ever writes that variable, in either secrets mode. Grafana ships with `admin`/`admin` on a public TLS subdomain. Independently filed by conformance-auditor as CRITICAL. | accepted | assigned to `work-podman-secrets`; failing test first | user, 2026-09-10 |
| `remed-6` | work-podman-secrets | High | Both homeserver fragments carry a dead `env_file: {{INSTALL_DIR}}/.env` line. podman-compose aborts on a missing env_file, which is the concrete reason `--podman-secrets` mode cannot start. | accepted | assigned to `work-podman-secrets` | user, 2026-09-10 |
| `remed-7` | work-podman-secrets | Medium | `_store_podman_secrets` uses `podman secret exists` (Podman 4.5.0) and re-run detection needs `podman secret inspect --showsecret` (4.7.0), while `MIN_PODMAN_VERSION` is `4.4.0` (`lib/00_constants.sh:22`). podman-secrets mode will fail loudly with a version message; whether to raise the floor is a user decision. | | needs-decision | |
| `remed-8` | work-podman-secrets | Medium | Synapse documents `registration_shared_secret_path` (1.67.0), `macaroon_secret_key_path` (1.121.0), `form_secret_path` and `turn_shared_secret_path`, none of which the installer uses; `database.args.password` has no documented file-based alternative, so `homeserver.yaml` keeps the DB password in plaintext regardless. Follow-up against `lib/12_homeserver.sh`. | deferred (PENDING user) | user approved option (a) for the current task; conversion to `*_path` options deferred to a follow-up | user, 2026-09-10 |
| `remed-9` | work-podman-secrets | Low | `matrix-redis-password` is created by `_store_podman_secrets` but no redis service exists in any compose fragment. Inert in both modes. Open question whether worker mode was intended. | | | |

## From work-dendrite (2026-09-10)

| ID | Source | Severity | Finding | Disposition | Evidence / Link | Approved by |
|---|---|---|---|---|---|---|
| `remed-10` | work-dendrite | Critical | `registration_disabled` in the Dendrite config was fed the registration *enable* flag, so the `closed` and `invite-only` policies rendered **open registration**. An operator configuring a closed server got an open one. | accepted | fixed in `lib/12_homeserver.sh:139` + `templates/configs/homeserver.dendrite.yaml.tpl`; 5 polarity tests both directions; negative control bit 5 tests | user, 2026-09-10 |
| `remed-11` | work-dendrite | High | The Dendrite TURN block was rendered under `global`, which has no such key (`config_global.go`), so it was silently discarded and TURN never functioned on Dendrite. Moved to `client_api` (`config_clientapi.go`). | accepted | fixed; 2 tests; negative control bit 2 | user, 2026-09-10 |
| `remed-12` | work-dendrite | High | `lib/21_deploy.sh:61,281,291` probe `localhost:8008` while both homeserver fragments declare `ports: []` under `dns` networking. Blocks the deploy phase before admin creation is reached. **Affects Synapse equally.** Duplicate of conformance-auditor's `ports: []` finding. | | needs fix; blocked on `templates/compose/` ownership | |
| `remed-13` | work-dendrite | Medium | `lib/22_backup.sh:66,68,275` and `lib/26_upgrade.sh:83` hardcode `-U synapse … synapse`, ignoring `database.user` / `database.name`. | accepted | verified at `lib/22_backup.sh:66,68,275` and `lib/26_upgrade.sh:83`. Both scripts now carry `DB_USER`/`DB_NAME` in their printf %q header and the upgrade probe reads `database.user`/`database.name`. Negative controls: dump identity hardcoded = 2 reds, restore identity hardcoded = 2 reds, upgrade identity hardcoded = 2 reds. | - |
| `remed-14` | work-dendrite | Medium | `lib/23_media_retention.sh:33` calls `/_synapse/admin/v1/purge_media_cache`; Dendrite has no such endpoint. | rejected | stale: `lib/23_media_retention.sh:33` no longer calls `/_synapse/admin/v1/purge_media_cache` - the file was rewritten before this reading. The Dendrite branch now says explicitly that Dendrite has no remote-media retention and that `media_retention.days` has no effect there. Re-checked by qa-agent, 2026-09-10. | - |
| `remed-15` | work-dendrite | Medium | `lib/18_monitoring.sh:57` scrapes `/_synapse/metrics` on :9000; Dendrite serves `/metrics` on :8008 (`setup/base/base.go:140`). | accepted | verified at `lib/18_monitoring.sh`: one hardcoded `/_synapse/metrics` on :9000 for both homeservers. Synapse gets a dedicated `type: metrics` listener on 9000 (`templates/configs/homeserver.synapse.yaml.tpl:24-28`); the Dendrite template sets `global.metrics.enabled` with no listener. Dendrite now scrapes `/metrics` on `PORT_DENDRITE`. 9 tests in `tests/test_monitoring.sh` over homeserver type x networking mode, parsed with PyYAML; negative control (dendrite branch reverted) = 4 reds. The Dendrite port/path itself is **not independently verified here** - it is work-dendrite reading `setup/base/base.go` at v0.14.1, cited in the comment. NOT fixed: the shipped Grafana dashboard queries `synapse_*` metrics only, so a Dendrite install gets an empty dashboard; that is new work, not a regression. | - |
| `remed-16` | work-dendrite | Medium | `lib/12_homeserver.sh:213` `homeserver_add_appservice` no-ops for Dendrite but logs success. Bridges silently do not register. | accepted | verified at `lib/12_homeserver.sh:213`: the function fell through the Synapse-only branch and logged "Registered appservice". It now fails with a message naming the file that was not registered, and `_bridge_setup_single` stops enabling the bridge. Live impact was nil: `config_validate` rejects dendrite+bridges and `bridges_setup` skips non-Synapse, so this is the backstop. 3 tests in `tests/test_bridges_registration.sh`; negative control = 2 reds. Dendrite appservice registration is **not implemented**: its config key could not be verified from here, and writing an unverified key would reproduce the silent-no-op it replaces. | - |
| `remed-17` | work-dendrite | Low | `lib/12_homeserver.sh:151` `open-captcha` sets no recaptcha keys; `federation.enabled=false` never writes `global.disable_federation`. | | | |

### Rejected on evidence from work-dendrite

The auditor findings alleging JSON injection via unescaped admin username/password
and the registration shared secret reaching process argv in the **Synapse** admin
path are `rejected`: `_deploy_register_admin` (`lib/21_deploy.sh:132`) already uses
`json.dumps`, passes secrets via the environment, and posts with `--data @-`.
Re-checked against the current tree by work-dendrite, 2026-09-10. Neither defect
remains. (Rows: security-auditor's argv finding and code-auditor-B's JSON-body finding.)

## Decisions taken (2026-09-10, second batch)

Approved by: user (daemon45@gmail.com), 2026-09-10.

| Decision | Choice | Rows resolved |
|---|---|---|
| AppArmor | **Not implemented**, and the agent's recommendation against it accepted. Podman does not apply AppArmor in rootless mode, so a loaded profile attaches to nothing while reading as protection. `harden_mac` now states what actually confines the containers; the spec row was amended so it no longer asserts the code is wrong. | `conformance-auditor-10` |
| `validate_regex` | **Deleted**, agent's argument accepted: four of the twelve config checks are not plain regex tests, so adoption would give a mixed style, and it removes no duplication (the repeated part is `log_error` plus the counter). Missing coverage added instead. | `coverage-analyst-13` (as coverage, not a bug fix) |
| Podman floor | **Raise `MIN_PODMAN_VERSION` to 4.7.0** - one version story rather than gating `--podman-secrets` separately. Conditional on re-verifying the platform matrix first: any release below 4.7.0 is reported back, not dropped silently. CentOS Stream 9 is the likely casualty. | `remed-7` |
| Hardening settings | The four divergent template settings (`AllowTcpForwarding no`, `use_tempaddr=2`, `icmp_ratelimit=100`, `nf_conntrack_max`) become **user-configurable options with plain-language explanations**, defaulting to current effective behaviour so no working install changes on upgrade. Explanations state consequences, not mechanism. | new work, see `remed-18` |

| ID | Source | Severity | Finding | Disposition | Evidence / Link | Approved by |
|---|---|---|---|---|---|---|
| `remed-18` | user | Enhancement | SSH and sysctl hardening settings are not operator-configurable; the templates carry values that diverge from the effective config with no way to choose. | accepted | assigned to `work-unwired`; defaults preserve current behaviour | user, 2026-09-10 |
| `remed-19` | work-platforms | High | `_check_tools` warns but never fails when `newuidmap` is absent, so rootless Podman proceeds broken. | accepted | assigned to `work-platforms` alongside the floor change | user, 2026-09-10 |
| `remed-20` | work-platforms | Medium | `UNVERIFIED:` whether openSUSE Leap 16.0/16.1 ship a PEP 668 `EXTERNALLY-MANAGED` marker. They have no `podman-compose` provider, so pip is their only path; if the marker is present they have **no compose path at all**. Interacts with the open pip-fallback decision. | | needs-decision; unconfirmed, not assumed working | |

### Rejected - orchestrator error, not a code defect

The claim that the `opensuse*` glob fails to match `opensuse-leap` /
`opensuse-tumbleweed` is `rejected`. It matches correctly; verified by
`work-platforms` against `lib/02_detect.sh`, and `docs/qa-review/compat-auditor.md:28`
agrees. The inverted claim originated in my own subagent brief, not in any audit
report. No code change was made. Recorded so it does not resurface.

## Decisions taken (2026-09-10, third batch)

Approved by: user (daemon45@gmail.com), 2026-09-10.

| Decision | Choice | Rows resolved |
|---|---|---|
| Grafana upgrade break | **Keep it fatal.** An existing env-mode install with monitoring fails its next run if `.env` lacks `GRAFANA_ADMIN_PASSWORD`, consistent with every other missing secret; the error names the variable. Rejected alternative: generating and appending one, which would leave Grafana on its old password while the report advertised the new one. | `remed-5` follow-on |
| `hardening.*` validation | **Keep**, including the behaviour change for the five pre-existing keys. `ssh = "yes"` now fails validation rather than silently meaning off. | scope call by `work-unwired`, accepted |
| pip fallback | **Dedicated virtualenv.** Immune to PEP 668, does not touch distro-managed site-packages. Also resolves whether Leap 16.0/16.1 have a compose path - they do, regardless of the `EXTERNALLY-MANAGED` marker. | `compat-auditor-5`, `dependency-auditor-1`, `dependency-auditor-13` (partial), `remed-20` |
| `ip_unprivileged_port_start=80` | **Keep and document.** Rootless Caddy needs 80/443 for ACME. User's stated basis: single admin operating for a small group, not a shared multi-user host. Trade-off to be written at the sysctl line and in the example TOML. | `security-auditor-8` |

### Corrections to the record

| What | Status |
|---|---|
| "Nothing checks for a usable key before SSH lockdown" | **False.** The guard exists at `lib/10_hardening.sh:47-52` (`_ssh_has_authorized_key`) and refuses the whole drop-in when no key is found. Verified directly. The real finding is `code-auditor-30`, **MEDIUM**: the guard globs `/home/*/.ssh/authorized_keys`, so a key belonging to an unrelated user satisfies it. The false version originated in an orchestrator summary, not in an audit report. |
| `icmp_ratelimit=100` as a hardening setting | **Inverted.** `icmp(7)` documents the default as 1000 and the value as the minimum space between responses in milliseconds, so 100 lets the host emit ICMP errors ten times faster than default. Dropped from the template; it was never rendered, so no regression. |
| `ports: []` as the cause of the failing readiness probe | **Wrong cause.** `ports: []` is correct - Caddy fronts the homeserver over `matrix-net` and publishes 80/443/8448 itself. The probes were pointed at a host port that has never existed. Publishing one would have added host exposure to satisfy a health check. |
| "Podman creates a directory at a missing bind-mount source" | **Not Podman's behaviour for `--volume`**: `podman-run(1)` says it returns an error and the source must be pre-created. Which behaviour applies through an external docker-compose provider is `UNVERIFIED`. |

## Correction: the Fedora 41/42 premise (2026-09-11)

The decision to narrow supported Fedora releases to **43+** stands, but the reason
recorded when it was approved was false and has been replaced.

- **Claimed, and wrong:** "Fedora 41 and 42 repositories are no longer carried by the
  mirrors, so `dnf install podman` fails." Checked by `work-fedora-ssh`: MirrorManager
  still serves `metalink?repo=fedora-41` and repoints it at archive mirrors (17 URLs
  under `pub/archive/fedora/linux/releases/41/`), and `repomd.xml` returns 200 at the
  size the metalink declares. `dnf install podman` works. The podman versions quoted
  in the original claim (5.6.2 / 5.8.2) were the F43/F44 figures, not F41/F42, which
  ship 5.2.5 and 5.4.1.
- **Actual justification, verified:** both releases are end-of-life (F41 2025-12-15,
  F42 2026-05-27, endoflife.date), so neither receives security updates. That is
  disqualifying for an installer whose purpose includes host hardening. README and
  spec NFR-01 now state this reason.
- The Fedora minimum was encoded **nowhere in code** - `lib/02_detect.sh` maps ID to
  family only, and `lib/05_prerequisites.sh` gates solely on `MIN_PODMAN_VERSION`.
  Prose in `README.md` and the spec was the sole enforcement.

The false premise originated in an orchestrator summary, not in an audit report. This
is the third such case this session; see also the `opensuse*` glob and the SSH lockout
guard entries in "Corrections to the record".

| ID | Source | Severity | Finding | Disposition | Evidence / Link | Approved by |
|---|---|---|---|---|---|---|
| `remed-21` | work-fedora-ssh | Medium | Running the installer **directly as root** (no `SUDO_USER`) on a host where root has an `authorized_keys` entry: the lockout guard passes, then the drop-in writes `PermitRootLogin no` and root loses SSH access anyway. The guard waves through the exact case it exists to prevent. | accepted | assigned to `work-fedora-ssh`; guard to depend on what the drop-in will actually write for `PermitRootLogin` | user, 2026-09-11 |

## From qa-agent (2026-09-10) - found during remediation

| ID | Source | Severity | Finding | Disposition | Evidence / Link | Approved by |
|---|---|---|---|---|---|---|
| `remed-qa-1` | qa-agent | High | Neither user timer was ever enabled. `backup_setup` and `media_retention_setup` both ran `run_as_user systemctl --user enable <timer> 2>/dev/null \|\| true`, which cannot work: `sudo -u` provides no session bus, and the failure was swallowed. Backups and media checks therefore never ran on any install. The same defect covered `matrix-compose.service`, so the stack did not start on boot either. | accepted | fixed with `systemd_user_enable_unit` (`lib/01_utils.sh`), which writes the `<target>.wants` symlink directly - systemctl(1) defines enable as creating exactly those symlinks. Quadlet units need no equivalent: their generator applies [Install] itself (podman-systemd.unit(5)). Used at all three call sites. 6 tests across `tests/test_quadlet.sh` and `tests/test_ownership.sh`; negative control (helper neutered) = 4 reds in each file. | agent, 2026-09-10 |
| `remed-qa-2` | qa-agent | High | The backup timer is a *user* unit owned by the matrix user, but `backup.sh`/`restore.sh` were written root:root 0750 into a root-owned tree, so the timer could not execute them even once enabled. Same for `media-cleanup.sh`. | accepted | fixed alongside `code-auditor-35`: `backup_setup` chowns its scripts directory and `media_retention_setup` chowns its script, both after the install-directory ownership phase. Test in `tests/test_ownership.sh`; negative control = 1 red. | agent, 2026-09-10 |
| `remed-qa-3` | qa-agent | Low | `assert_file_contains` in `tests/test_utils.sh` called `grep -q "$pattern" "$file"`, so any assertion on a pattern starting with a dash (a command-line flag, e.g. `-v /path:/path:ro`) was parsed by grep as options and could never pass. | accepted | `grep -q -- "$pattern"`. Found while asserting on a podman run argv; no existing caller relied on the old behaviour. | agent, 2026-09-10 |
| `remed-qa-4` | team-lead | Low | `run_as_user $COMPOSE_CMD -f ...` relies on an invisible word split (`COMPOSE_CMD` may be `podman compose`), flagged SC2086 at `lib/21_deploy.sh:57` and `lib/26_upgrade.sh:122,128`. The sibling call sites are unflagged only because `$COMPOSE_CMD` is in command position there. | accepted | fixed with an explicit array: `compose_argv` (`lib/01_utils.sh`) fills a named array with `read -r -a`, and the three `run_as_user` sites pass `"${compose[@]}"`. No disable directive. The reason lives once, at the helper. Found while testing: the existing upgrade assertions could not see the split at all - they matched the sudo stub log, which joins argv with spaces either way - so two assertions on podman's own log were added. 5 tests across `tests/test_deploy.sh` and `tests/test_upgrade.sh`; negative controls: quoted whole = 3 + 2 reds, helper stops splitting = 3 + 2 reds. `shellcheck -x --severity=info` is clean on all three files. | team-lead, 2026-09-11 |
| `remed-qa-5` | qa-agent | High | Leftover from `conformance-auditor-20`: `templates/compose/caddy.yml` and `lib/19_compose.sh:287` still injected `CF_API_TOKEN` into the Caddy container whenever `dns.cloudflare_api_token` was set. DNS-01 had already been dropped, so nothing in that container could use it - a zone-editing credential handed to a container with no use for it. | accepted | verified against the current tree before changing anything: the `{{#DNS_CHALLENGE}}` block and the two `_vars` assignments were both still present, and a rendered default install carried `CF_API_TOKEN: cf-token-value` under `services.caddy.environment`. Env block and `DNS_CHALLENGE`/`CF_API_TOKEN` removed from both. Then traced the whole path: `network_cloudflare_create_records` (`lib/07_network.sh:138`), the token's only other consumer, **has no call sites anywhere in the repo** - so the claim in `conformance-auditor-20`'s evidence and in `tests/test_caddy.sh`'s header that "the token keeps its working use (DNS record creation)" is wrong, and the key was reaching nothing at all. DECISION: **remove the config surface**. Dropped the `[dns]` section from `config/matrix-setup.example.toml` and the `dns.cloudflare_api_token` validation from `lib/04_config.sh`; nothing advertises the key and nothing validates it. The one remaining read is in `lib/13_caddy.sh`, and it exists only to tell an operator whose carried-over config still sets the key that it is ignored - loudly doing nothing rather than silently doing nothing. `caddy_vars[DNS_CHALLENGE]` was dead too (`Caddyfile.tpl` has no such marker) and is gone. The `config_save_state` redaction test is kept: it matches on `*token*`, so a stale key still cannot reach the state file. 3 tests in `tests/test_compose_assembly.sh` asserting on the parsed `services.caddy.environment` mapping, not on the absence of a string; `tests/test_config_validation.sh` now asserts a carried-over token does not fail validation. Negative controls: injection restored (template block + compose vars together - either alone is inert) = 2 reds; validation restored = 2 reds; all files restored by checksum. NOT DONE, and not this agent's file: `network_cloudflare_create_records` is still dead code in `lib/07_network.sh` - that is `code-auditor-52` / `coverage-analyst-13`, whose "wire it up" option now needs the config key re-added (three lines). | agent decision, 2026-09-11 |

## Cloudflare DNS path closed out (2026-09-11)

| ID | Source | Severity | Finding | Disposition | Evidence / Link | Approved by |
|---|---|---|---|---|---|---|
| `code-auditor-52` (Cloudflare half) | code-auditor | Medium | `network_cloudflare_create_records` (`lib/07_network.sh:138`) had zero call sites anywhere in `lib/`, `setup.sh` or the tests. | accepted | **deleted**, 56 lines removed; suite 1451 passed / 0 failed and shellcheck clean after removal. The `SKIP_CADDY` / `caddy.http_port` / `proxy.detected` half of this row was wired up separately and remains fixed. | user, 2026-09-11 |
| `coverage-analyst-13` (Cloudflare half) | coverage-analyst | Medium | Same function, reported as untested dead code. | accepted | duplicate of the row above; closed as deleted rather than covered. | user, 2026-09-11 |

### Correction: the "working use" claim was false

`conformance-auditor-20`'s evidence and the header comment in `tests/test_caddy.sh`
both stated that `dns.cloudflare_api_token` "keeps its working use (DNS record
creation)" after Caddy DNS-01 was dropped. That was wrong: the only function that
would have consumed it had no callers, so once the Caddy env injection was removed
the key reached nothing at all. Traced and corrected by `work-loose-ends`; the
comments asserting it have been fixed.

Consequence chain worth recording, because no single audit finding described it:
the stock Caddy image carries no DNS provider module, so DNS-01 produced a Caddy
that would not start and took ports 80 and 443 with it. Dropping DNS-01 left the
Cloudflare token injected into a container with no use for it. Removing that
injection left the config key dead. Removing the key left the API function
unreachable. Four findings across three auditors were facets of one dead feature.

## Supply chain closed out (2026-09-11)

| ID | Source | Severity | Finding | Disposition | Evidence / Link | Approved by |
|---|---|---|---|---|---|---|
| `dependency-auditor-3` (DEP-003) | dependency-auditor | HIGH | Pinned Synapse `v1.127.1` is affected by GHSA-8q93-326v-3m7g (high, fixed 1.152.1) plus two medium advisories. | accepted | **resolved**: bumped to `v1.160.0`. Target chosen over the 1.152.1 minimum because diffing `config_documentation.md` between the tags gives 0 keys removed and all 40 the template writes still present. `MIN_PG_VERSION` moved 13 to 14 (Synapse dropped PostgreSQL 13 at v1.143.0); covered by `tests/test_version_floors.sh`. | user, 2026-09-11 |
| `dependency-auditor-4` | dependency-auditor | MEDIUM | `pin-digests.sh` takes the digest from the server-asserted `Docker-Content-Digest` header rather than computing it - trust on first use. | | **still open as a property of the script.** Mitigated in practice for this re-pin only: both new digests were verified by fetching the manifest body and hashing the raw bytes, and both images were identified from their config blobs as base-image rebuilds of the same upstream versions (caddy v2.11.4, postgres 16.14). The script itself was not changed. | |
| `dependency-auditor-9` | dependency-auditor | MEDIUM | No dependency-update mechanism exists. | accepted | `renovate.json` added, tracking the Actions SHAs and all 17 image pins via a custom regex manager; validated with `renovate-config-validator --strict`. **Inert until the Renovate GitHub App is installed** - a third-party app taking write access to a repo that publishes signed releases, left as the user's decision. Honest coverage gap recorded: `PODMAN_COMPOSE_VERSION` and the AUR bootstrap are not tracked, and the weekly digest check can only re-resolve the tag already pinned, never propose a newer version - which is how Synapse came to sit 45 releases behind a green gate. | user, 2026-09-11 |

Stale citations corrected: `lib/23_media_retention.sh:16,25` cited Synapse
v1.127.1 docs for `media_retention.remote_media_lifetime` and the media admin
API. Both were re-checked at v1.160.0 - same semantics, so the rationale stood
and only the version was stale. Now cite v1.160.0. The remaining v1.127.1
references in `docs/SUPPLY_CHAIN.md` are deliberate before/after comparisons
(schema version, and a licence widening to
`AGPL-3.0-or-later OR LicenseRef-Element-Commercial`) and are correct as written.
