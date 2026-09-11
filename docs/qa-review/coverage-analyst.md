# coverage-analyst report

**Target:** Test coverage of `/media/owner/Workspace/Matrix_Setup` (setup.sh, lib/00_*..27_*.sh, bridges/*.sh, scripts/*.sh) against `tests/` (13 files, 300 passing assertions)
**Branch:** qa/fleet-loop-20260910
**Started:** 2026-09-10T00:00:00Z
**Status:** COMPLETE

## What works well

Three areas hold up under mutation, and the credit is earned rather than
incidental.

**`tests/test_secrets.sh` asserts values, not shapes.** It checks the exact
`.env` content (`REGISTRATION_SHARED_SECRET=reg_secret_test`) and the exact
file mode (`assert_eq "600" "$perms"`). Demonstrated: mutating
`lib/08_secrets.sh` to `chmod 644` with `umask 022` **killed** the suite
(298 passed, 2 failed), and replacing `_gen_secret` with a constant also
**killed** it (298 passed, 2 failed) via the uniqueness assertion. This is a
test that can fail.

**`tests/test_security_regression.sh:158-186` genuinely exercises rollback.**
It builds a real manifest, stubs only `sysctl` (into a log file it then asserts
on), and checks the outcome of each action type by value:
file actually gone, file content actually restored to `original`, sysctl called
with `net.ipv4.tcp_syncookies=0`. Demonstrated: disabling the `rm -f` in
`_rollback_action` **killed** the suite (299/1), and disabling the `mv` restore
**killed** it (299/1).

**`lib/04_config.sh` is the best-covered module at 70% line / 124 measured
lines.** `config_validate` alone accounts for 87 executed lines across
`tests/test_config_validation.sh` and `tests/test_security_regression.sh`, with
paired positive and negative cases, so both arms of most branches run.

**`tests/test_phase_resolution.sh` is a good use of a static check.** It shows
0 executed lines in `setup.sh` because it deliberately greps rather than
executes - it asserts every `run_phase` callee resolves to a defined function.
That is the right shape for catching a renamed-function bug in a script that
cannot be safely run in CI. Not a coverage gap; do not "fix" it.

**The TOML Bash fallback is correct today, even though CI never runs it.** I
forced `_toml_parse_python` to fail and re-ran: `300 passed, 0 failed`. A
differential run of both backends over `config/matrix-setup.example.toml`
produced identical output, 28 keys each, zero diff.


## Method

Line coverage for Bash was measured, not estimated. No `kcov`/`bashcov` is
installed on this host, so I instrumented the suite with Bash's own xtrace:

- `PS4='@@${BASH_SOURCE[0]:-}|${LINENO:-}@@'`, `BASH_XTRACEFD` pointed at an
  append-mode log, `set -x`, injected into every `bash` invocation in the run
  via `BASH_ENV`. This captures subshells and the `bash -c` children the tests
  spawn, which a naive `set -x` in the runner would miss.
- Repo copied to
  `/tmp/claude-1000/-media-owner-Workspace-Matrix-Setup/429f2141-39f7-456b-8a49-bbc886347ac0/scratchpad/repo`;
  the working tree was not mutated.
- **Verification that the measurement is real:** the suite reports
  `300 passed, 0 failed, 0 skipped` uninstrumented, and `300 passed, 0 failed,
  0 skipped` under instrumentation, exit 0 both times. The trace contains 15,048
  xtrace records resolving to 1,030 distinct `file|line` pairs across 38
  production files plus the test files. The denominator is non-zero and names
  the files expected.
- A first instrumentation attempt *did* perturb the suite (72 failures, PS4
  tripping `set -u` inside `bash -c`). Those numbers were discarded; every
  figure below comes from the clean run.

**Numerator is exact. Denominator is approximate.** xtrace emits a record for
simple commands and compound-statement heads, not for every physical line
(`}`, `fi`, function-definition lines never appear). The "executable lines"
denominator is a static count of non-blank, non-comment, non-structural-keyword
lines, which over-counts. Real line coverage is therefore *somewhat higher*
than the percentages below. Function coverage (a boolean per function region)
is the trustworthy headline number and is what the risk ranking is built on.

Function regions are `def line -> next def line - 1`. Top-level code between
functions is attributed to the preceding function; this is noted where it
changes a verdict.

### Headline

| Metric | Measured |
|---|---|
| Files measured | 38 production files (28 `lib/`, `setup.sh`, 7 `bridges/`, 2 `scripts/`) |
| Function coverage | **51 / 246 = 20.7%** (exact) |
| Line coverage | **411 / 3785 = 10.9%** (numerator exact, denominator over-counts) |
| Files with zero executed lines | **21 of 38** |
| Tests | 300 passed, 0 failed, 0 skipped (identical instrumented and not) |


## Function inventory

Measured, from the xtrace log. "hit" = distinct source lines in the function
region that executed at least once.

### Files with zero production lines executed (21 of 38)

`lib/05_prerequisites.sh` (227 exec lines), `lib/06_user.sh` (84),
`lib/07_network.sh` (124), `lib/09_proxy_detect.sh` (155), `lib/11_postgres.sh`
(70), `lib/12_homeserver.sh` (135), `lib/13_caddy.sh` (58), `lib/14_coturn.sh`
(37), `lib/15_webclient.sh` (73), `lib/17_admin_ui.sh` (15),
`lib/18_monitoring.sh` (120), `lib/19_compose.sh` (100), `lib/20_quadlet.sh`
(80), `lib/21_deploy.sh` (142), `lib/22_backup.sh` (220),
`lib/23_media_retention.sh` (53), `lib/24_report.sh` (92), `lib/27_wizard.sh`
(267), `setup.sh` (110), `scripts/gen-sbom.sh` (21), `scripts/pin-digests.sh`
(83).

Not one line of any of these ran during the 300-test suite.

### Per-file

| File | Exec lines | Hit | Line % | Functions covered |
|---|---:|---:|---:|---|
| lib/00_constants.sh | 66 | 57 | 86% | n/a (no functions; top-level constants) |
| lib/01_utils.sh | 176 | 37 | 21% | 10 / 25 |
| lib/02_detect.sh | 158 | 32 | 20% | 1 / 15 |
| lib/03_toml_parser.sh | 123 | 20 | 16% | 2 / 8 |
| lib/04_config.sh | 175 | 124 | 70% | 3 / 8 |
| lib/05_prerequisites.sh | 227 | 0 | 0% | 0 / 18 |
| lib/06_user.sh | 84 | 0 | 0% | 0 / 6 |
| lib/07_network.sh | 124 | 0 | 0% | 0 / 8 |
| lib/08_secrets.sh | 64 | 29 | 45% | 4 / 5 |
| lib/09_proxy_detect.sh | 155 | 0 | 0% | 0 / 7 |
| lib/10_hardening.sh | 201 | 11 | 5% | 1 / 11 |
| lib/11_postgres.sh | 70 | 0 | 0% | 0 / 4 |
| lib/12_homeserver.sh | 135 | 0 | 0% | 0 / 5 |
| lib/13_caddy.sh | 58 | 0 | 0% | 0 / 1 |
| lib/14_coturn.sh | 37 | 0 | 0% | 0 / 1 |
| lib/15_webclient.sh | 73 | 0 | 0% | 0 / 3 |
| lib/16_bridges.sh | 80 | 14 | 17% | 1 / 3 |
| lib/17_admin_ui.sh | 15 | 0 | 0% | 0 / 1 |
| lib/18_monitoring.sh | 120 | 0 | 0% | 0 / 3 |
| lib/19_compose.sh | 100 | 0 | 0% | 0 / 3 |
| lib/20_quadlet.sh | 80 | 0 | 0% | 0 / 3 |
| lib/21_deploy.sh | 142 | 0 | 0% | 0 / 8 |
| lib/22_backup.sh | 220 | 0 | 0% | 0 / 4 |
| lib/23_media_retention.sh | 53 | 0 | 0% | 0 / 1 |
| lib/24_report.sh | 92 | 0 | 0% | 0 / 1 |
| lib/25_rollback.sh | 140 | 31 | 22% | 4 / 13 |
| lib/26_upgrade.sh | 73 | 4 | 5% | 1 / 5 |
| lib/27_wizard.sh | 267 | 0 | 0% | 0 / 19 |
| setup.sh | 110 | 0 | 0% | 0 / 4 |
| bridges/discord.sh | 42 | 8 | 19% | 4 / 8 |
| bridges/irc.sh | 48 | 12 | 25% | 4 / 8 |
| bridges/signal.sh | 42 | 8 | 19% | 4 / 8 |
| bridges/slack.sh | 42 | 8 | 19% | 4 / 8 |
| bridges/telegram.sh | 46 | 8 | 17% | 4 / 8 |
| bridges/whatsapp.sh | 42 | 8 | 19% | 4 / 8 |
| scripts/gen-sbom.sh | 21 | 0 | 0% | 0 / 0 |
| scripts/pin-digests.sh | 83 | 0 | 0% | 0 / 2 |

### The 51 covered functions (complete list)

`lib/01_utils.sh`: log_info, log_warn, log_error, log_success, log_debug,
log_step, log_substep, template_render, get_user_home, version_gte
`lib/02_detect.sh`: detect_os
`lib/03_toml_parser.sh`: toml_parse_file, _toml_parse_python
`lib/04_config.sh`: config_validate, _config_apply_defaults, _validate_domain
`lib/08_secrets.sh`: secrets_generate_all, secrets_generate_bridge_tokens,
_gen_secret, _store_env_file
`lib/10_hardening.sh`: _harden_nftables
`lib/16_bridges.sh`: _bridge_setup_single
`lib/25_rollback.sh`: rollback_init_manifest, rollback_snapshot,
rollback_execute_all, _rollback_action
`lib/26_upgrade.sh`: _pg_major_from_image
`bridges/*.sh` (x6): bridge_name, bridge_image, bridge_generate_registration,
bridge_compose_fragment

Note `bridge_description` and `bridge_requires_synapse` show 0 hits in every
plugin: `tests/test_bridge_loader.sh:22` checks they are *declared*
(`declare -f`), never calls them.


## Findings

Ranked by the cost of a silent failure, not by line count.

### F1 [CRITICAL] `_homeserver_synapse` is 0%-covered, and it currently emits invalid YAML on every registration policy

**Situation.** `lib/12_homeserver.sh` has **0 of 135 executable lines covered**
and **0 of 5 functions**. It generates `homeserver.yaml`, the file Synapse
parses at startup. Nothing in `tests/` sources it. `tests/test_templates.sh`
covers `template_render` but only against toy templates written inside the test
(`tests/test_templates.sh:12,26,53,63,74`); it asserts the real templates merely
*exist* (`tests/test_templates.sh:97`), never that they render.

**Behaviour.** I drove `_homeserver_synapse` and `_homeserver_dendrite`
directly, in the scratch copy, with the real defaults from
`_config_apply_defaults` and each of the four `registration.policy` values, and
parsed the result with `yaml.safe_load`:

| homeserver | registration.policy | unresolved `{{ }}` lines | YAML |
|---|---|---:|---|
| synapse | closed | 8 | **INVALID** |
| synapse | invite-only (default) | 8 | **INVALID** |
| synapse | open-email | 6 | **INVALID** |
| synapse | open-captcha | 4 | **INVALID** |
| dendrite | closed | 1 | valid |
| dendrite | invite-only | 1 | valid |
| dendrite | open-email | 1 | valid |
| dendrite | open-captcha | 1 | valid |

Generated file under the default policy, lines 68-81:

```yaml
registration_shared_secret: "GENERATE_ME"

{{#REGISTRATIONS_REQUIRE_3PID}}
registrations_require_3pid:
  - email
{{/REGISTRATIONS_REQUIRE_3PID}}

{{#ENABLE_CAPTCHA}}
enable_registration_captcha: true
recaptcha_public_key: "{{RECAPTCHA_PUBLIC_KEY}}"
recaptcha_private_key: "{{RECAPTCHA_PRIVATE_KEY}}"
{{/ENABLE_CAPTCHA}}
```

`yaml.safe_load` fails at line 71: *"while scanning a simple key ... could not
find expected ':'"*.

**Mechanism.** `template_render` (`lib/01_utils.sh:220-229`) iterates
`"${!_vars[@]}"` - it only strips a `{{#KEY}}...{{/KEY}}` block for keys that
*exist in the array*. `_homeserver_synapse` sets `REGISTRATIONS_REQUIRE_3PID`
only under `open-email` (`lib/12_homeserver.sh:59`) and `ENABLE_CAPTCHA` only
under `open-captcha` (`lib/12_homeserver.sh:64`). Under any other policy the
keys are absent, so both blocks and their markers survive verbatim into the
output. `tests/test_templates.sh:36` only ever tests the *present-and-false*
case (`[METRICS]="false"`), never the *absent* case - which is the case
production hits by default.

Line 8 is the same class in the plain-substitution path:
`web_client_location: "https://{{WEBCLIENT_SUBDOMAIN}}.example.com/"`.
`WEBCLIENT_SUBDOMAIN` is set in `lib/13_caddy.sh:35` but never in
`lib/12_homeserver.sh`, and `tests/test_templates.sh:70` explicitly asserts that
unknown placeholders are *left as-is* - correct behaviour for the helper,
silently wrong for this caller.

**Impact.** Synapse cannot parse the config and will not start. This is the
default path of the tool's primary purpose, and 300 tests are green.

**Suggested tests.**
1. Render every real template in `templates/configs/` through the production
   variable-building function for each `registration.policy` and each
   `homeserver.type`, then assert `! grep -q '{{' "$out"` and that
   `yaml.safe_load` (or `python3 -c 'import yaml'`) succeeds. That single test
   would have caught all eight rows above.
2. Add a `template_render` case for a `{{#KEY}}` block whose key is **absent
   from the array**, pinning the intended semantics.

- **Files:** `lib/12_homeserver.sh:27-117` (uncovered);
  `lib/01_utils.sh:220-229` (mechanism);
  `templates/configs/homeserver.synapse.yaml.tpl:2,8,71-80`;
  test that ought to cover it: `tests/test_templates.sh:97`
- **Effort:** M
- **Confidence: 5** - executed the production function in a scratch copy and
  parsed the output; reproduced across all eight policy/homeserver combinations.
- **Caveat, stated because it bounds the claim:** I invoked
  `_homeserver_synapse` directly rather than through `setup.sh`, with
  `CONFIG[domain.name]` set and `_config_apply_defaults` applied. If the real
  wizard sets `ENABLE_CAPTCHA`/`REGISTRATIONS_REQUIRE_3PID`/`WEBCLIENT_SUBDOMAIN`
  somewhere I did not find, the severity drops. I grepped for all three across
  `lib/`, `setup.sh` and `templates/`: `WEBCLIENT_SUBDOMAIN` is assigned only at
  `lib/13_caddy.sh:35`, and the other two only inside the two `case` arms named
  above. `lib/27_wizard.sh` is itself 0%-covered, so this is worth a second pair
  of eyes.

### F2 [HIGH] The whole deploy/backup/restore half of the tool has zero executed lines

**Situation.** Twenty-one of 38 production files have **zero** executed lines.
The ones where a silent failure is expensive:

| File | Exec lines | What a silent failure costs |
|---|---:|---|
| `lib/22_backup.sh` | 220 | Generates the backup **and restore** scripts as heredocs. A broken restore script is discovered during a disaster, which is the worst possible time. `_backup_generate_restore_script` (`lib/22_backup.sh:159`) is never executed, never syntax-checked, never run. |
| `lib/21_deploy.sh` | 142 | `_deploy_create_admin` / `_deploy_register_admin` (`lib/21_deploy.sh:87,132`) create the admin account using the registration shared secret. `_deploy_wait_for_homeserver` (`:57`) is the readiness gate. |
| `lib/05_prerequisites.sh` | 227 | AUR bootstrap, Podman install, socket enablement. `c65227f` ("harden AUR bootstrap; it could never have worked as written") is the proof this file can be wrong for a long time undetected. Untested still. |
| `lib/27_wizard.sh` | 267 | 19 wizard steps; the sole interactive entry point. Everything the user types passes through here before validation. |
| `lib/19_compose.sh` | 100 | `compose_assemble` (`:12`) decides which fragments make up the deployed stack. |
| `lib/10_hardening.sh` | 201 (11 hit) | `harden_ssh` (`:39`) rewrites sshd config. Getting this wrong locks the operator out of their own server. Only `_harden_nftables` shows any hits, and only 9 lines. |
| `lib/07_network.sh` | 124 | `network_cloudflare_create_records` (`:138`) writes DNS records via an external API. `network_check_ports` (`:100`) gates deployment. |

**Behaviour.** The generated backup and restore scripts are heredoc bodies. Note
`lib/22_backup.sh:56` and `:182` define `log()` *inside the heredocs* - they are
lines of a generated artefact, not functions of this codebase, and appear in the
inventory as functions only because of that. Nothing parses these artefacts, so
a syntax error in the generated restore script ships.

**Impact.** Backup/restore is the highest-consequence untested code in the repo:
its failure mode is silent until the moment it is needed.

**Suggested tests.** These do not need containers or a live system:
1. `bash -n` every generated script. `_backup_generate_backup_script` and
   `_backup_generate_restore_script` write to a path you control; render into
   `$TEST_TMP` and syntax-check. Catches heredoc-quoting and expansion bugs for
   near-zero effort. **Start here.**
2. `compose_assemble` with a fixed CONFIG, asserting the fragment *set* for each
   feature combination and that the result parses as YAML.
3. `harden_ssh` against a fixture `sshd_config` in `$TEST_TMP`, asserting the
   resulting file and that `_ssh_has_authorized_key` (`lib/10_hardening.sh:22`)
   refuses to disable password auth when no key is present. That guard is the
   lockout guard, and it is 0-covered.

- **Effort:** L overall; the `bash -n` check in (1) is S.
- **Confidence: 5** for the zero-coverage measurement (trace data);
  **3** for the relative risk ordering, which is my judgement.

### F3 [HIGH] `network_check_ports` and the Cloudflare DNS writer are wholly untested

**Situation.** `lib/07_network.sh` - 0 of 124 lines, 0 of 8 functions.
`tests/test_network.sh` is named for this file but does not test it: its own
header says *"Tests for domain validation (_validate_domain from
lib/04_config.sh)"* and it sources `lib/04_config.sh`
(`tests/test_network.sh:7`), never `lib/07_network.sh`. The trace confirms 0
executed lines in `lib/07_network.sh` during the whole suite.

**Behaviour.** `network_cloudflare_create_records` (`lib/07_network.sh:138`)
issues authenticated writes to a third-party DNS API. `network_check_ports`
(`:100`) and `network_check_port_reachable` (`:122`) gate whether deployment
proceeds. `network_dns_matches_server` (`:83`) decides whether the domain
actually points here.

**Impact.** A regression in the Cloudflare writer misconfigures a user's real
DNS zone - an externally visible, not-locally-reversible change. A regression in
the port check either blocks a valid install or waves through an invalid one.

**Suggested tests.** Inject the HTTP client (or stub `curl` as a function, the
pattern already used successfully for `sysctl` at
`tests/test_security_regression.sh:177`) and assert on the request method, URL,
record type and payload - never against the live API. Separately, rename
`tests/test_network.sh` to `test_domain_validation.sh`; the current name asserts
coverage that does not exist.

- **Files:** `lib/07_network.sh:83,100,122,138`; test that ought to cover it:
  `tests/test_network.sh:1-7`
- **Effort:** M
- **Confidence: 5** - zero executed lines measured; the misnaming is stated in
  the test's own header comment.

### F4 [MEDIUM] `_store_podman_secrets` - the non-default secret backend - is 0-covered

**Situation.** `lib/08_secrets.sh` is 45% covered and its `.env` path is well
tested (see "What works well"), but `_store_podman_secrets`
(`lib/08_secrets.sh:92-121`) shows **0 executed lines**. It is selected when
`CONFIG[secrets.mode] == "podman"` (`lib/08_secrets.sh:29`); every test runs the
`env` default.

**Behaviour.** The function has a genuine branch worth pinning: an existing
secret is preserved and skipped, while any *other* `podman secret create`
failure is fatal and returns 1 (`lib/08_secrets.sh:113-117`). Neither arm runs.

**Impact.** If the "already exists" detection breaks, a re-run either aborts a
working install or silently leaves a stale secret in place while the config
expects a new one. Bounded below F1-F3 because failure is loud at container
start.

**Suggested test.** Stub `run_as_user` as a function that records its arguments
and returns a scripted exit code - the same technique already used for `sysctl`.
Assert both arms, including that a non-"exists" failure propagates a non-zero
return.

- **Files:** `lib/08_secrets.sh:92-121`; test that ought to cover it:
  `tests/test_secrets.sh:44`
- **Effort:** S
- **Confidence: 5** - zero executed lines measured.

### F5 [MEDIUM] `test_compose_assembly.sh` never calls `compose_assemble`

**Situation.** `tests/test_compose_assembly.sh` is 79 lines and contributes
roughly 40 of the 300 assertions. `lib/19_compose.sh` shows **0 executed
lines**.

**Behaviour.** Every assertion is `assert_file_exists` or
`assert_file_contains` against a static file in `templates/compose/`. The file
tests the *ingredients*; nothing tests the *assembly*. `compose_assemble`
(`lib/19_compose.sh:12`), `_compose_build_vars` (`:109`) and
`_compose_render_fragment` (`:163`) are never called.

**Impact.** The tests cannot detect a fragment omitted from the assembled
compose file, a fragment included when its feature is disabled, or a variable
not substituted during assembly. A green suite is read as "compose assembly
works"; it means "the template files still contain these substrings".

**Suggested test.** Call `compose_assemble` with a fixed CONFIG per feature
combination; assert the set of services in the output and that the result parses
as YAML with no residual `{{`. Consider renaming the current file to
`test_compose_templates.sh` and giving the new one the assembly name.

- **Files:** `lib/19_compose.sh:12,109,163`; test that ought to cover it:
  `tests/test_compose_assembly.sh:1-79`
- **Effort:** M
- **Confidence: 5** - zero executed lines measured; read the whole test file.

### F6 [MEDIUM] `tests/test_rollback.sh:52-57` asserts a precondition, not a rollback

**Situation.** The block is headed `# --- Test: file-based rollback action ---`.

**Behaviour.** It creates `$TEST_TMP/removable-file`, records a `FILE_CREATED`
snapshot, then asserts
`assert_file_exists "$TEST_TMP/removable-file" "file exists before rollback"`
and stops. No rollback is invoked. The assertion holds identically whether
rollback works or is deleted entirely.

**Impact.** Low in isolation, because
`tests/test_security_regression.sh:158-186` does test this path properly and
mutation-kills both file actions. The cost is misleading: a reader auditing
`test_rollback.sh` sees rollback covered where it is not, and the coverage
measurement shows `rollback_execute_phase` (`lib/25_rollback.sh:59`),
`rollback_snapshot_file` (`:34`), `rollback_snapshot_sysctl` (`:48`),
`rollback_offer` (`:170`), `rollback_cleanup` (`:162`), `setup_error_trap`
(`:201`), `_on_error` (`:206`) and `_on_interrupt` (`:213`) as **0-covered**.
`rollback_execute_phase` is the single-phase variant and has no test anywhere.

**Also note:** `tests/test_security_regression.sh:159-162` does
`unset -f rollback_snapshot` and replaces it with a *re-implementation* of the
production recorder. The rollback *reader* is therefore tested against a
hand-written writer. If the production manifest format changed, that section
would still pass. `tests/test_rollback.sh:38-41` does pin the real format
(4 pipe-delimited fields, leading timestamp), so the two files together close
the loop - but only by accident of being in different files, and only for the
format, not the field semantics.

**Suggested test.** In `test_rollback.sh`, call `rollback_execute_phase` for one
phase and assert that phase's file is gone *and* another phase's file survives -
the selectivity is the whole point of the function and nothing tests it.

- **Files:** `tests/test_rollback.sh:52-57`; code `lib/25_rollback.sh:59-76`
- **Effort:** S
- **Confidence: 4** - read both files and confirmed 0 hits for
  `rollback_execute_phase` in the trace. Not mutation-demonstrated, because the
  security-regression file covers the adjacent actions.

### F7 [LOW] The pure-Bash TOML fallback is never executed in CI

**Situation.** `_toml_parse_bash` (`lib/03_toml_parser.sh:123`),
`_toml_parse_value` (`:170`) and `_toml_strip_comment` (`:102`) show **0
executed lines**. `toml_parse_file` (`:14`) tries Python first
(`lib/03_toml_parser.sh:25`), and Python 3.11+ is present on any host that runs
CI, so the fallback never runs.

**Behaviour.** Not broken today. I forced the fallback by making the Python
branch fail and re-ran the suite: `300 passed, 0 failed`. A differential run of
both backends over `config/matrix-setup.example.toml` gave identical output,
28 keys each, zero diff.

**Impact.** Low now, latent later: a future edit to the Bash parser cannot be
caught by any test, because no test path reaches it. The fallback exists
precisely for hosts CI does not resemble.

**Suggested test.** Parameterise the existing `tests/test_toml_parser.sh` over
both backends - call `_toml_parse_bash` directly for a second pass of the same
13 cases, and add a differential assertion over
`config/matrix-setup.example.toml`. Cheap, and it turns a latent path into a
covered one.

- **Files:** `lib/03_toml_parser.sh:102,123,170`; test that ought to cover it:
  `tests/test_toml_parser.sh`
- **Effort:** S
- **Confidence: 5** - demonstrated by forcing the branch and by differential run.

### F8 [LOW] `lib/02_detect.sh` - 1 of 15 functions covered

**Situation.** Only `detect_os` (`lib/02_detect.sh:31`) executes.
`detect_arch`, `detect_ram`, `detect_disk`, `detect_virtualization`,
`detect_init_system`, `detect_selinux`, `detect_apparmor`, `detect_ipv6`,
`detect_resolved`, `detect_public_ip`, `detect_podman`,
`detect_compose_command`, `detect_existing_install`, `detect_all`,
`print_system_summary` are all 0-covered.

**Impact.** Mostly low - these read the environment and their failure is usually
visible. Two are not: `detect_existing_install` (`:188`) decides whether the run
is a fresh install or a re-run, and `detect_compose_command` (`:170`) picks the
compose binary. A wrong answer from either changes what the tool does to an
existing system.

**Suggested test.** These are pure functions over filesystem and command
lookups; point them at a fixture root or stub `command -v`. Prioritise
`detect_existing_install` and `detect_compose_command`; the rest are genuinely
low value.

- **Files:** `lib/02_detect.sh:170,188`; test that ought to cover it:
  `tests/test_detect.sh`
- **Effort:** M
- **Confidence: 5** for the measurement; **3** for the risk split.


## Assertion strength

Method: each mutation was applied with `sed` to the **scratch copy only**, the
full suite run, then reverted. "SURVIVED" = the suite stayed at
`300 passed, 0 failed` with the code broken.

### A1 [HIGH] Bridge registration YAML: every assertion matches the key name, never the value

**Situation.** `tests/test_bridge_loader.sh:74-76` is the only test of
`bridge_generate_registration`, the function that writes each bridge's
appservice registration - the file that carries the token authenticating the
bridge to the homeserver and the namespace regex declaring which users the
bridge owns.

**Behaviour.** The assertions are
`assert_file_contains "$reg_file" "as_token"`,
`... "hs_token"`, `... "example.com"`. `assert_file_contains` is a `grep`
(`tests/test_utils.sh`). `as_token` appears in the file as the literal *key*
`as_token:` regardless of what value follows, so the assertion is satisfied by
the key alone. Demonstrated, three separate mutations of
`bridges/discord.sh:22-35`:

| Mutation | Result |
|---|---|
| `as_token: "${as_token}"` -> `as_token: ""` (empty appservice token) | **SURVIVED** - 300 passed, 0 failed |
| `hs_token: "${hs_token}"` -> `hs_token: "${as_token}"` (both tokens identical) | **SURVIVED** - 300 passed, 0 failed |
| `regex: "@discord_.*:${domain}"` -> `regex: "@.*:${domain}"` (bridge claims *every* user) | **SURVIVED** - 300 passed, 0 failed |

**Impact.** The third is the worst: an `exclusive: true` namespace of `@.*` makes
Synapse hand the entire local user namespace to the bridge, and ordinary user
registration then fails with a namespace conflict. A homeserver that cannot
register users, shipped past a fully green suite. The first two are credential
failures: an empty or duplicated appservice token.

**Fix.** Assert the value, not the key:
`assert_file_contains "$reg_file" 'as_token: "test_as_token"'`, and assert the
namespace regex is anchored to the bridge's own prefix. This applies to all six
plugins, which share the assertion loop.

- **File:** `tests/test_bridge_loader.sh:74-76`; code `bridges/*.sh` (all 6)
- **Effort:** S
- **Confidence: 5** - demonstrated by mutation; suite stayed green three times.

### A2 [MEDIUM] `bridge_compose_fragment` assertions cannot see an empty image

**Situation.** `tests/test_bridge_loader.sh:104-105` checks the generated compose
fragment.

**Behaviour.** `assert_match "image:" "$fragment"` and
`assert_match "container_name:" "$fragment"`. Same key-not-value defect.
Demonstrated: `bridges/discord.sh:44` `image: ${BRIDGE_DISCORD_IMAGE}` -> `image: `
**SURVIVED**, 300 passed, 0 failed.

**Impact.** `BRIDGE_*_IMAGE` comes from `lib/00_constants.sh`. A typo'd or
deleted constant yields `image:` with no value; the fragment is syntactically
valid YAML and the suite is green. Failure surfaces at `podman-compose up`.
Lower than A1 because it fails loudly at deploy rather than silently at runtime.

**Fix.** `assert_match 'image: [^[:space:]]' "$fragment"`, and assert the image
matches the expected `BRIDGE_<NAME>_IMAGE` constant.

- **File:** `tests/test_bridge_loader.sh:104-105`; code `bridges/*.sh`
- **Effort:** S
- **Confidence: 5** - demonstrated by mutation.

### A3 [MEDIUM] `bridge_description` / `bridge_requires_synapse` are checked for existence, never called

**Situation.** `tests/test_bridge_loader.sh:22` verifies six required functions
per plugin.

**Behaviour.** The check is
`bash -c "source '$plugin'; declare -f $func" &>/dev/null` - it asserts the
function is *declared*. Coverage confirms the consequence: `bridge_name` and
`bridge_image` show hits (they are called later in the file), but
`bridge_description` and `bridge_requires_synapse` show **0 executed lines in
all six plugins**. `bridge_requires_synapse` gates whether a bridge is offered
on a Dendrite homeserver.

**Impact.** A plugin whose `bridge_requires_synapse` returns `false` when it
should return `true` passes every test, and the bridge is offered on Dendrite,
where its appservice will not work.

**Fix.** Call them and assert the values: non-empty description,
`bridge_requires_synapse` in `{true,false}` and equal to the expected value per
plugin.

- **File:** `tests/test_bridge_loader.sh:22`; code e.g. `bridges/discord.sh:6,8`
- **Effort:** S
- **Confidence: 4** - read both, plus zero-hit measurement from the trace. Not
  mutation-demonstrated.


## Dead code

Method: for each of the 246 defined functions, all whole-word references across
`lib/`, `bridges/`, `scripts/`, `setup.sh` and `tests/`, minus its own
definition line. **15 functions have zero references anywhere.** Chesterton's
fence applied to each: what it is for, before whether to remove it.

### D1 [HIGH - this is a bug, not dead weight] `setup.sh` looks for a manifest path that `rollback_init_manifest` never creates

**Situation.** `rollback_init_manifest` (`lib/25_rollback.sh:12-15`) creates the
manifest with `mktemp "${install_dir}/${MATRIX_SETUP_MANIFEST_FILE}.XXXXXXXXXX"`
- a random ten-character suffix. `setup.sh:72` and `setup.sh:95` both test for
the *unsuffixed* path
`"${CONFIG[install_dir]:-$DEFAULT_INSTALL_DIR}/$MATRIX_SETUP_MANIFEST_FILE"`,
i.e. `<install_dir>/.rollback-manifest` (`lib/00_constants.sh:9`).

**Behaviour.** Demonstrated in the scratch copy:

```
created by rollback_init_manifest : <install_dir>/.rollback-manifest.YnfJRX7Igz
path setup.sh:72 / :95 look for   : <install_dir>/.rollback-manifest
RESULT: setup.sh would NOT find the manifest -> rollback never offered
```

Consequences, both in `setup.sh`, which has **0 of 110 lines covered**:
- `trap_handler` (`setup.sh:62`, `trap ... ERR`): the `[[ -f "$manifest" ]]`
  guard at `:73` is never true, so on any failure the tool neither offers
  rollback nor prints the `sudo bash setup.sh --rollback` recovery hint. It
  prints the error and exits, leaving the box half-configured with no signal
  that a manifest exists.
- `trap_sigint` (`setup.sh:91`, Ctrl+C): same guard at `:95`, same outcome.

**Behaviour, second half.** `setup.sh --rollback` (`setup.sh:111-115`) calls
`rollback_execute_all` in a fresh process where `MANIFEST_FILE=""`
(`lib/25_rollback.sh:7`) and `rollback_init_manifest` has not run. Demonstrated:

```
--- simulating a fresh 'setup.sh --rollback' process ---
[WARN] No rollback manifest found
```

`rollback_execute_all` returns 1, and `setup.sh:17` is `set -Eeuo pipefail`, so
the script dies there and never reaches `log_success "Rollback completed."`.
No code path anywhere *discovers* an existing manifest on disk - the only writer
of `MANIFEST_FILE` is `rollback_init_manifest`, and it always mints a new empty
one. `--rollback` cannot work as written.

**Impact.** The rollback subsystem is well-implemented and well-unit-tested at
the action level (see "What works well"), and is unreachable from all three of
its production entry points. A failed install leaves changes in place with no
recovery route. This is the highest-consequence defect I found after F1.

**Why coverage missed it.** `tests/test_rollback.sh` and
`tests/test_security_regression.sh` both set `MANIFEST_FILE` themselves by
calling `rollback_init_manifest` in-process, so they exercise the library
without ever crossing the `setup.sh` boundary where the path is reconstructed.
This is the classic seam a unit-test-only suite cannot see.

**Fix direction (for whoever owns the code, not a test change):** have
`rollback_init_manifest` write a fixed path, or record the mktemp'd path in a
known location that `setup.sh` and `--rollback` can read back.

**Suggested test.** Assert the round trip: `rollback_init_manifest`, then assert
the file `setup.sh` looks for is the file that was created; and a `--rollback`
test that seeds a manifest on disk and asserts `rollback_execute_all` finds it.

- **Files:** `lib/25_rollback.sh:12-15`, `setup.sh:72,95,112`
- **Effort:** S to test, S to fix
- **Confidence: 5** - executed both halves in a scratch copy.

### D2 [MEDIUM - should be used and is not] `network_cloudflare_create_records` is advertised in the shipped config and called from nowhere

`lib/07_network.sh:138-193`. Zero references.
`config/matrix-setup.example.toml:115` documents
`cloudflare_api_token` as *"For automatic DNS record creation + DNS-01 ACME
challenge"*. The DNS-01 half is wired (`lib/13_caddy.sh:85-87` and
`lib/19_compose.sh:139-141` pass `CF_API_TOKEN` through to
`templates/configs/Caddyfile.tpl:9`). The *automatic DNS record creation* half is
this function, and nothing calls it. `network_validate` (`:19`) - the function
`setup.sh:158` actually runs - checks DNS and ports but never offers to create
records.

Not dead weight: a documented feature that silently does not happen. Either wire
it into `network_validate` or remove the claim from the example config.
`network_print_dns_instructions` (`:194`) is the manual-instructions path and is
also uncalled, which suggests the whole DNS-assistance flow was written and
never connected. **Confidence: 5** for uncalled; **3** for intent.

### D3 [MEDIUM - superseded implementation, safe to remove *after* D1] the rollback trap layer

`setup_error_trap` (`lib/25_rollback.sh:201`) and `rollback_cleanup` (`:162`)
have zero references. `setup_error_trap` installs
`trap '_on_error ...' ERR` / `trap '_on_interrupt' INT TERM`, which reach
`rollback_offer` (`:170`) and its four-way menu, including
`rollback_execute_phase` (`:59`) - the *per-phase* rollback that has no other
caller and no test.

Why it is there: it is the original, richer trap layer. `setup.sh:62-104`
reimplements a two-way version of the same thing inline and installs its own
traps at `setup.sh:85,104`, superseding it. So `rollback_offer`, `_on_error`,
`_on_interrupt` and transitively `rollback_execute_phase` are all reachable only
through a function nobody calls.

The removal decision is downstream of D1: the unused version is the one with the
per-phase option and the "abort and keep the manifest" option. If D1 is fixed by
adopting `setup_error_trap`, this code becomes live and valuable; if D1 is fixed
inside `setup.sh`, this becomes ~90 lines to delete. **Do not delete it before
D1 is decided.** `rollback_cleanup` is separate and is a genuine small leak:
nothing removes the manifest on success, so `<install_dir>/.rollback-manifest.*`
accumulates one file per run, each listing paths touched.
**Confidence: 5** for uncalled; **4** for the supersession reading.

### D4 [LOW - unused API surface, keep] parser and config accessors

`toml_get` (`lib/03_toml_parser.sh:36`), `toml_has` (`:42`), `toml_get_array`
(`:48`), `config_get` (`lib/04_config.sh:220`), `config_set` (`:225`). Zero
references.

Why they are there: they are the documented public API of two modules; callers
read `TOML_VALUES[...]` and `CONFIG[...]` directly instead. `toml_get_array` is
the only one with real logic (comma-splitting, `lib/03_toml_parser.sh:48-59`) and
is the only one whose absence of a test costs anything.

Keep. Five thin accessors are not a maintenance burden, and removing a module's
public API to satisfy a coverage number is the wrong trade. Worth one test for
`toml_get_array`'s splitting behaviour if anything ever calls it.
**Confidence: 5** for uncalled; **4** for "keep".

### D5 [LOW - genuinely removable] three unused utils

- `file_backup` (`lib/01_utils.sh:201`) - superseded by
  `rollback_snapshot_file` (`lib/25_rollback.sh:34`), which does the same `cp`
  to a `.pre-matrix.$(date +%s)` name *and* records it for rollback. Strictly
  dominated. Remove.
- `make_temp_dir` (`lib/01_utils.sh:310`) - `make_temp_file` (`:306`) has a
  caller; this one does not. Remove or leave; harmless.
- `validate_regex` (`lib/01_utils.sh:299`) - generic helper, never adopted;
  validation is done inline in `config_validate`. Remove.

**Confidence: 5** for uncalled; **4** for `file_backup` being dominated.

### D6 [LOW] `detect_existing_install` and `print_system_summary`

`lib/02_detect.sh:188` and `:218`. Zero references.
`UNCERTAIN:` `detect_all` (`:201`) is what `setup.sh:132` runs, and it does not call
`detect_existing_install`. Re-run/upgrade detection is instead done by
`upgrade_check` (`lib/26_upgrade.sh:16`) on the `--upgrade` path only. So a
plain re-run over an existing install does not detect that it is a re-run
through this function. Whether that matters depends on whether the phases are
individually idempotent - `secrets_generate_all` (`lib/08_secrets.sh:12-19`)
clearly is, others I did not check.

`print_system_summary` is display-only; low value either way.

**Confidence: 5** for uncalled; **2** for the re-run risk - flagged
`UNCERTAIN:` because I did not audit each phase for idempotence, and that is
what would settle it.

### Not dead, listed to close the question

`bridge_description` and `bridge_requires_synapse` (all six plugins) have
references (`lib/16_bridges.sh`), so they are not dead - they are *called in
production and never called by a test*. That is finding A3, not dead code.
`main` (`setup.sh:107`) is invoked at the bottom of the script; my first pass
mis-flagged it and the corrected count clears it.


## Verified OK / dropped suspicions

Suspicions raised during the pass and then **dropped** because the evidence went
the other way. Recorded so nobody re-opens them.

- **"The two TOML parsers have drifted."** Dropped. Differential run over
  `config/matrix-setup.example.toml`: 28 keys from each backend, `diff` empty.
  Forcing the Bash fallback for the whole suite: 300 passed, 0 failed. The
  remaining concern is CI never *exercising* it (F7), not correctness.
- **"`test_utils.sh` is a test file the runner silently skips."**
  Dropped. `tests/test_runner.sh:77` excludes it, and it is genuinely a shared
  helper - ten of the eleven test files source it
  (`tests/test_*.sh:6-8`). The exclusion is correct.
- **"`test_phase_resolution.sh` shows 0% coverage of `setup.sh`, so it tests
  nothing."** Dropped. It is a deliberate static check over `run_phase` call
  sites; executing `setup.sh` in CI would be wrong. Zero coverage is the
  expected result here.
- **"`assert_file_contains` in `test_secrets.sh` is another key-not-value
  assertion like the bridge tests."** Dropped. It asserts full
  `KEY=value` pairs (`tests/test_secrets.sh:58-61`), and mutation confirmed the
  file can fail.
- **"The Caddy and coturn templates have the same unsupplied-variable defect as
  the Synapse one."** Dropped. Cross-checked placeholders in
  `templates/configs/Caddyfile.tpl` and `turnserver.conf.tpl` against the vars
  assigned in `lib/13_caddy.sh` and `lib/14_coturn.sh`: exact match, both ways,
  no gap. The Dendrite template has only the cosmetic `MATRIX_SETUP_VERSION`
  and renders to valid YAML on all four registration policies.
- **"`setup.sh:main` is dead code."** Dropped - `main "$@"` is the last line of
  `setup.sh`. Artefact of my first reference-count pass; the corrected count
  clears it.
- **"`_rollback_action` is only covered through a mocked writer, so the covered
  actions may not really work."** Dropped. `tests/test_rollback.sh:38-41` pins
  the real `rollback_snapshot` output format independently, and two mutations of
  `_rollback_action` were killed by the suite. The residual concern is narrower
  and is recorded inside F6.

### Verified: the measurement itself

- Suite result identical instrumented and uninstrumented (300/0/0, exit 0), so
  the tool did not perturb what it measured.
- 15,048 xtrace records -> 1,030 distinct `file|line` pairs; denominator
  non-zero across 38 named production files.
- A recommended CI gate was demonstrated to fail, not just to pass: a
  function-coverage ratchet at the current floor of 51 exits 0; the same gate at
  52 prints `GATE FAILED` and exits 1.


## Completion

**Status:** COMPLETE
**Finished:** 2026-09-10

### Tally

| Severity | Count | IDs |
|---|---:|---|
| CRITICAL | 1 | F1 |
| HIGH | 4 | F2, F3, D1, A1 |
| MEDIUM | 7 | F4, F5, F6, A2, A3, D2, D3 |
| LOW | 5 | F7, F8, D4, D5, D6 |
| **Total** | **17** | |

Two findings are demonstrated *defects in production code*, not merely coverage
gaps: **F1** (Synapse `homeserver.yaml` is invalid YAML on all four registration
policies) and **D1** (the rollback manifest path mismatch makes all three
rollback entry points inoperative). Both live in files with **zero** test
coverage, which is the point of the exercise.

Four tests were demonstrated to **pass in both the working and the broken
world** (A1 x3, A2): empty appservice token, duplicated tokens, a namespace
regex claiming every user, and an empty container image - all with 300/300
green.

### Top gaps by risk

1. **F1** - `lib/12_homeserver.sh` 0% covered; ships unparseable config.
2. **D1** - rollback unreachable from `setup.sh`; no recovery after a failed install.
3. **F2** - `lib/22_backup.sh` 0% covered; the generated *restore* script is never even syntax-checked.
4. **A1** - bridge registration assertions match key names, not values.
5. **F3** - `lib/07_network.sh` 0% covered, including a live third-party DNS writer.

### Recommended next steps

- **Cheapest high-value test first:** `bash -n` on every generated script
  (`lib/22_backup.sh:21,159`, `lib/23_media_retention.sh:6`,
  `lib/20_quadlet.sh:40,99`). Render into `$TEST_TMP`, syntax-check, assert no
  residual `{{`. Small effort, covers the worst silent-failure surface.
- **One test that would have caught F1:** render every real template through its
  production variable-builder for every relevant CONFIG combination; assert no
  `{{` survives and the output parses. Extend to compose fragments and this also
  covers F5.
- **Agents:** `qa-agent` for F4, F6, A1-A3 (unit-level, existing patterns fit).
  `integration-test` for F1, F2, F5 - these need the render-then-validate shape
  that crosses module boundaries. `mutation-test` over
  `tests/test_bridge_loader.sh` and `tests/test_compose_assembly.sh`; both are
  high-assertion-count files whose assertions I found weak, and there will be
  more than the four I demonstrated.
- **CI ratchet, set at today's floor, not an aspiration:** 51 covered functions
  / 411 covered lines, gated per the demonstrated script. Ratchet upward as
  tests land. Gate on function coverage rather than line coverage - the line
  denominator is approximate for Bash, the function count is exact.
- **Two renames that would stop the suite overstating itself:**
  `tests/test_network.sh` -> `test_domain_validation.sh` (it tests
  `lib/04_config.sh`), and `tests/test_compose_assembly.sh` ->
  `test_compose_templates.sh` (it never calls `compose_assemble`).

### Not checked, and why

- **`lib/27_wizard.sh` (267 lines, 19 functions, 0% covered)** - I measured it
  and ranked it in F2, but did not analyse individual wizard steps. It is
  interactive and driving it needs stdin fixtures I did not build within budget.
  It is the largest single uncovered file and the sole interactive entry point;
  it deserves its own pass.
- **`lib/05_prerequisites.sh`, `lib/06_user.sh`, `lib/09_proxy_detect.sh`,
  `lib/11_postgres.sh`, `lib/18_monitoring.sh`, `lib/20_quadlet.sh`,
  `lib/21_deploy.sh`, `lib/23_media_retention.sh`, `lib/24_report.sh`,
  `scripts/*.sh`** - measured (all 0%) and ranked, but not read function by
  function. Their functions install packages, create users and start
  containers; per the brief I ran nothing against the live system, so any
  deeper claim would have been inference rather than evidence.
- **Whether each phase is individually idempotent on a re-run** - bears on D6
  and I did not audit it. Marked UNCERTAIN there.
- **Branch/condition coverage** - xtrace gives executed lines, not taken
  branches. Where I claim an untested branch (F4, F7) it is because the enclosing
  function has zero executed lines, which is stronger; I have not claimed
  partial-branch coverage anywhere.

### Reproducing

Scratch copy, instrumentation and raw trace are under
`/tmp/claude-1000/-media-owner-Workspace-Matrix-Setup/429f2141-39f7-456b-8a49-bbc886347ac0/scratchpad/`
(`covinit.sh`, `mutate.sh`, `fncov.sh`, `gate.sh`, `cov/raw.trace`,
`cov/covered.txt`, `cov/fncov.txt`). The repository working tree was not
modified; every mutation was applied to the copy and reverted.

