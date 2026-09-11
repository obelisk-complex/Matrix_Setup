# compat-auditor report

**Target:** Matrix_Setup cross-distribution compatibility (Bash provisioning suite, rootless Podman Matrix homeserver)
**Started:** 2026-09-10T00:00:00Z
**Status:** COMPLETE

## What works well

Portability that is handled correctly, and should not be regressed:

- **No PCRE, no `date -Iseconds`, no `xxd`.** Earlier GNU-only constructs have been
  replaced with POSIX equivalents and the replacements carry comments saying why
  (`lib/02_detect.sh:192`, `lib/07_network.sh:106`, `lib/12_homeserver.sh:219`).
  `df -k` + awk integer arithmetic (`lib/02_detect.sh:78`) instead of `df -BG` is the
  right call.
- **bash floor is checked before any library is sourced** (`setup.sh:23-27`), so the
  nameref/`${var,,}` usage in `lib/01_utils.sh:216`, `lib/12_homeserver.sh:161`,
  `lib/19_compose.sh:110,165` cannot produce a syntax error on an older bash. The
  guard sits above the `source` loop, which is the only place it works.
- **`#!/usr/bin/env bash` everywhere**, never `#!/bin/sh` — so the Ubuntu/Debian
  `dash` default `/bin/sh` never sees bashisms.
- **DNS resolution degrades gracefully** through `dig` -> `host` -> `getent`
  (`lib/07_network.sh:66-79`). `bind-utils`/`dnsutils` is not a hard dependency, which
  is correct: it is not installed by default on any of the claimed distros.
- **Firewall backend is detected, not assumed** (`lib/10_hardening.sh:82-92`):
  ufw -> firewall-cmd -> nft covers Debian/Ubuntu, RHEL/Fedora/openSUSE and Arch
  respectively, and each backend's failure is surfaced rather than swallowed.
- **`opensuse*` glob** in `lib/02_detect.sh:51` correctly catches both
  `opensuse-leap` and `opensuse-tumbleweed`, which are distinct `ID=` values.
- **`get_user_home` uses `getent`** rather than `eval ~$user`, so it works for system
  users whose home is not under `/home` (openSUSE and RHEL place system users
  differently) and cannot be injected into.
- **Images are pinned to `tag@sha256:digest`**, including `SYNAPSE_ADMIN_IMAGE`
  (`lib/00_constants.sh:37`), which was a floating `:latest-etke` tag at the previous
  audit. Digest pinning removes registry-side drift as a cross-host variable.
- **TOML parsing has a pure-bash fallback** for hosts without a modern Python
  (`lib/03_toml_parser.sh:31`). The design is right; see F-06 for the reason it does
  not currently fire.


## Supported matrix

### Claimed

`README.md:42` — "Ubuntu 22.04+, Debian 12+, Fedora 39+, CentOS Stream 9+, Arch, openSUSE".

`lib/02_detect.sh:44-53` maps a wider set to four families:

| family  | `ID=` values accepted |
|---------|-----------------------|
| debian  | ubuntu, debian, linuxmint, pop |
| rhel    | fedora, centos, rhel, rocky, alma, ol |
| arch    | arch, manjaro, endeavouros |
| suse    | opensuse*, sles |

So the code silently accepts six distros the README never promises (Mint, Pop!_OS,
Rocky, Alma, Oracle, Manjaro, EndeavourOS, SLES) and every one of them takes an
untested package-install path.

### Actually exercised

`tests/distro/Vagrantfile` boots five boxes: `ubuntu2404`, `debian12`, `fedora40`,
`centos9`, `arch`.

### The gap

| distro | README | Vagrant | note |
|--------|--------|---------|------|
| Ubuntu 24.04 | yes | yes | |
| **Ubuntu 22.04** | **yes (floor)** | **no** | the oldest claimed release is untested — and F-01 says it cannot work |
| Debian 12 | yes | yes | F-01 |
| Fedora 39/40 | yes | yes (40) | |
| CentOS Stream 9 | yes | yes | F-02, F-03 |
| Arch | yes | yes | F-04, F-05, F-08 |
| **openSUSE** | **yes** | **no box at all** | entire `suse` branch of every case statement is unexercised |
| Rocky/Alma/Oracle | no | no | accepted by code |
| Mint/Pop/Manjaro/EndeavourOS/SLES | no | no | accepted by code |

Two of the claimed platforms — the Ubuntu LTS floor and openSUSE — have no harness
coverage at all, and the harness itself installs `podman podman-compose curl openssl
jq` by hand before running, so it never exercises `_install_podman`,
`_install_compose` or `_check_tools`: the exact functions where the per-distro
divergence lives.


## Findings
<!-- appended one at a time, as found -->

## Verified OK

Checked against a specific platform difference and found sound. Future audits can skip
these unless the code changes.

- **`version_gte` (`lib/01_utils.sh:316-320`)** — uses `sort -V`, which is GNU
  coreutils. Every distro in the claimed matrix is glibc/GNU coreutils, and the
  limitation is documented in a comment at the function. Correct as written; only a
  BusyBox/musl target (not claimed) would break it.
- **`tac` (`lib/25_rollback.sh:71,87`)** — same reasoning: GNU-only, but no claimed
  distro lacks it.
- **Missing `VERSION_ID` in `/etc/os-release`** — Arch does not set `VERSION_ID`
  (it sets `BUILD_ID=rolling`). `lib/02_detect.sh:36` defaults it to `"unknown"`, and
  `OS_VERSION` is only ever *printed* (`lib/02_detect.sh:37`, `lib/27_wizard.sh:38`) —
  never compared or gated on. Cosmetic at worst. Same for missing `PRETTY_NAME`, which
  has a composed fallback.
- **`chown "$user:"` with a trailing colon (`lib/20_quadlet.sh:97`)** — GNU coreutils
  reads this as "the user's login group", which is the intent, and it is the same on
  every claimed distro.
- **`systemctl list-unit-files <unit>` as an existence guard
  (`lib/05_prerequisites.sh:219`)** — returns exit 1 for a unit that does not exist
  (verified on systemd 255 here), so the guard behaves. The problem with that function
  is what it enables, not whether the guard works — see F-15.
- **`ExecStart=` without an absolute path (`lib/20_quadlet.sh:87-88`)** — modern
  systemd resolves a bare command name against a compiled-in list that includes
  `/usr/local/bin`, `/usr/bin` and `/bin`, so `podman compose ...` and a distro-packaged
  `podman-compose` both resolve. Worth noting for the F-05 fix: a venv install at
  `/opt/matrix/venv/bin/podman-compose` is an absolute path and fine, but a
  `pip --user` install into `~/.local/bin` would **not** resolve. Use an absolute path
  there.
- **`ss` filter syntax (`lib/07_network.sh:105,113`)** — `sport = :80` is standard
  iproute2 and `iproute2` is a dependency of Arch's `base` and installed by default on
  every other claimed distro. `ss` is not in `_check_tools`, so a host without it would
  silently report "ports 80/443 free" — but there is no claimed distro where that
  happens.
- **`mktemp -d -t "...-XXXXXXXX"` (`lib/05_prerequisites.sh:167`)** — GNU `mktemp`
  accepts `-t` with a template; entropy is adequate; the comment correctly explains why
  a predictable `/tmp/...-$$` path was rejected.
- **Firewall detection order (`lib/10_hardening.sh:82-92`)** — ufw, firewall-cmd, nft
  is the right precedence for the claimed matrix. (The nftables *ruleset* has problems;
  the *detection* does not — see F-13.)
- **SSH service name (`lib/10_hardening.sh:71`)** — `systemctl reload sshd ||
  systemctl reload ssh` covers both the RHEL/Arch/SUSE name and the Debian/Ubuntu name.

### Test-coverage gaps found while auditing

- `tests/test_toml_parser.sh` calls only `toml_parse_file`, so on any machine with
  Python 3.11+ all 13 of its assertions exercise the Python path. `_toml_parse_bash`
  has never been tested by CI, which is why F-04 survived.
- `tests/test_detect.sh:12-16` asserts `detect_os` against *the current host*, so it
  proves nothing about any other distro. The `OS_ID` -> `OS_FAMILY` mapping at
  `lib/02_detect.sh:44-53` is pure string logic and is the one part of detection that
  can be tested portably, by setting `OS_ID` and calling the case statement — it is
  not tested.
- `tests/distro/Vagrantfile` pre-installs `podman podman-compose curl openssl jq` in
  every box before running the harness, so `_install_podman`, `_install_compose` and
  `_check_tools` — where all of F-01, F-02, F-05, F-06, F-07 and F-08 live — are never
  executed by the cross-distro harness that exists to test them.


## Completion

**Status:** COMPLETE
**Finished:** 2026-09-10

### Tally

| severity | count | findings |
|----------|-------|----------|
| will-crash | 8 | F-01, F-02, F-03, F-04, F-08, F-09, F-11, F-12 |
| silent-corruption | 2 | F-06, F-10 |
| degraded | 7 | F-05, F-07, F-13, F-14, F-15, F-16, F-17 |
| cosmetic | 0 | |
| **total** | **17** | |

### Coverage

Walked the install path for: Ubuntu 22.04, Ubuntu 24.04, Debian 12, Fedora 39/40,
CentOS Stream 9 / RHEL 9, Arch Linux. openSUSE was audited by reading its branches
only; its package names could not be verified against a citable source and F-16 is
marked accordingly.

### Confidence distribution

- Confidence 5 (verified against a citable source, or reproduced here): F-01, F-02,
  F-03, F-04, F-05, F-06, F-07, F-08, F-09, F-11, F-12, F-13
- Confidence 4: F-10, F-14, F-15
- Confidence 3 / `UNVERIFIED:`: F-16 (openSUSE package names)
- Confidence 2 / `UNCERTAIN:`: F-17 (distro attribution only; the structural gap is 5)

### Not checked, and why

- No distro was booted. `vagrant up`, package installs and daemon changes were all
  out of scope per the brief. Every platform claim above rests on a cited source or on
  a repro run in the scratchpad against the repo's own library code.
- Bridge container images on `aarch64` — `lib/00_constants.sh:43-49` pins
  `dock.mau.dev/mautrix/*` by digest, and a single-arch digest would fail to pull on
  ARM. Confirming which of those digests are multi-arch needs registry queries against
  each image; not done.
- PostgreSQL (`lib/11_postgres.sh`) and the proxy detection (`lib/09_proxy_detect.sh`)
  were read but not audited in depth; the `sudo -u postgres` guard at
  `lib/11_postgres.sh:101` was the only thing checked there.
- The commit message on `c65227f` claims the AUR bootstrap "could never have worked as
  written". Checked, and it is accurate — but F-08 records that it is still accurate
  after the fix, for reasons the commit did not address.


### F-01 [will-crash] Ubuntu 22.04 and Debian 12 ship Podman below the enforced 4.4.0 floor, and the installer's own remedy reinstalls the same version

- **Situation:** `lib/00_constants.sh:22` sets `MIN_PODMAN_VERSION="4.4.0"`.
  `lib/05_prerequisites.sh:41-53` treats that as hard-fail, and on failure offers
  `_install_podman`, which for `OS_FAMILY=debian` runs
  `apt-get install -y -qq podman ...` (`lib/05_prerequisites.sh:227-229`).
- **Behaviour:** Ubuntu 22.04 jammy ships podman `3.4.4+ds1-1ubuntu1.22.04.x` and
  Debian 12 bookworm ships `4.3.1+ds1-8+deb12u1`. Both are `< 4.4.0`. `apt-get
  install` is therefore a no-op re-resolve to the same version, `version_gte` fails a
  second time, and `lib/05_prerequisites.sh:47-48` exits with
  "Still too old after install attempt."
- **Impact:** The oldest release the README claims (`README.md:42`, "Ubuntu 22.04+,
  Debian 12+") cannot install at all, and Debian 12 — the current stable — cannot
  either. The user sees a version error and a dead end, having already had a system
  user created and `/etc/subuid` modified. This is not a soft floor: Quadlet itself
  landed in Podman 4.4, so lowering the constant is not the fix; the fix is to add
  the upstream repo (Kubic/OBS) or to correct the README to Ubuntu 24.04+ /
  Debian 13+.
- **Where:** `lib/00_constants.sh:22`, `lib/05_prerequisites.sh:41-53`,
  `lib/05_prerequisites.sh:225-230`, `README.md:42`
- **Distro/version:** Ubuntu 22.04 LTS, Debian 12
- **Confidence: 5** — [packages.ubuntu.com/jammy/podman](https://packages.ubuntu.com/jammy/podman) (3.4.4),
  [packages.debian.org/bookworm/podman](https://packages.debian.org/bookworm/podman) (4.3.1+ds1-8+deb12u1).
- **Fix:** Either (a) drop 22.04/Debian 12 from `README.md:42`, or (b) in
  `_install_podman`, when the distro package is known-old, configure the upstream
  repository before installing and re-check. Silently accepting 3.4.4 is not an
  option — `quadlet_setup` would produce units nothing reads.

### F-02 [will-crash] `_install_podman` asks dnf for a `uidmap` package that does not exist on RHEL-family distros

- **Situation:** `lib/05_prerequisites.sh:231-236` runs
  `dnf install -y podman podman-compose uidmap slirp4netns` for `OS_FAMILY=rhel`.
- **Behaviour:** `uidmap` is a Debian/Ubuntu package name. On RHEL 9, CentOS Stream 9,
  Fedora and derivatives `newuidmap`/`newgidmap` ship in `shadow-utils`; there is no
  `uidmap` package. `dnf install` fails the whole transaction with
  "No match for argument: uidmap". `podman-compose` on CentOS Stream 9 / RHEL 9 is
  also EPEL-only, so that argument fails on a stock box too. With `set -euo pipefail`
  at `lib/05_prerequisites.sh:4` and no `|| true`, the installer aborts.
- **Impact:** On CentOS Stream 9 or RHEL 9 without Podman preinstalled, answering "y"
  to "Install Podman now?" kills the run. Note the same file gets it *right* 100 lines
  later: `_check_tools` uses `dnf install -y shadow-utils` for `rhel`
  (`lib/05_prerequisites.sh:349`). The two paths disagree.
- **Where:** `lib/05_prerequisites.sh:231-236`
- **Distro/version:** CentOS Stream 9, RHEL 9, Rocky/Alma 9, Oracle Linux 9; the
  `podman-compose` half also affects Fedora only if EPEL semantics change (Fedora
  carries it in main).
- **Confidence: 5** — `newuidmap`/`newgidmap` are shipped by
  [shadow-utils-4.9-12.el9](https://www.rpmfind.net/linux/RPM/centos-stream/9/baseos/x86_64/shadow-utils-4.9-12.el9.x86_64.html);
  no `uidmap` package exists in el9. EPEL is documented as carrying what BaseOS/AppStream do not.
- **Fix:** `dnf install -y podman shadow-utils slirp4netns`, and move
  `podman-compose` to a separate best-effort install that falls through to
  `_install_compose` (which already handles the failure) rather than being part of the
  same transaction.

### F-03 [will-crash] `harden_fail2ban` runs a bare `dnf install fail2ban`, which fails on CentOS Stream 9 / RHEL 9 without EPEL

- **Situation:** `lib/10_hardening.sh:236-243` installs fail2ban with a per-family
  case statement and no error suppression, inside a phase reached by every default
  run (`CONFIG[hardening.fail2ban]` defaults to `true`, `lib/10_hardening.sh:13`).
- **Behaviour:** `fail2ban` is not in CentOS Stream 9 / RHEL 9 BaseOS or AppStream; it
  is an EPEL package. `dnf install -y fail2ban` on a stock host returns "No match for
  argument: fail2ban" and exits non-zero. `harden_fail2ban` is invoked from
  `harden_all` as the last command of an `&&` list (`lib/10_hardening.sh:13`), so
  `set -e` is *not* suppressed and the installer dies mid-hardening.
- **Impact:** Every default CentOS Stream 9 / RHEL 9 run aborts after SSH and firewall
  changes have already been applied. The user is left with a hardened SSH config, an
  active firewall, and no Matrix server. `sudo bash setup.sh --rollback` is offered by
  the ERR trap, so it is recoverable, but the run cannot complete.
- **Where:** `lib/10_hardening.sh:236-243`
- **Distro/version:** CentOS Stream 9, RHEL 9, Rocky/Alma 9, Oracle Linux 9
- **Confidence: 5** — EPEL exists precisely to carry packages absent from CentOS
  Stream BaseOS/AppStream; fail2ban is one of them. See
  [fail2ban#3480](https://github.com/fail2ban/fail2ban/issues/3480), which is a thread
  of RHEL9/OL9 users unable to find it in base repos.
- **Fix:** For `rhel`, install `epel-release` first (or detect EPEL and skip fail2ban
  with a warning if absent). Whatever the choice, the install must not be able to kill
  the run: wrap it so a missing fail2ban degrades to `log_warn` and the phase
  continues, since fail2ban is an optional hardening extra, not a dependency of the
  homeserver.

### F-04 [will-crash] The TOML parser crashes the whole installer when Python lacks `tomllib`, and the pure-Bash fallback it has for exactly this case is unreachable

- **Situation:** `lib/03_toml_parser.sh:25-31` is written to try Python `tomllib` and
  fall back to `_toml_parse_bash` if that fails. `tomllib` is Python 3.11+.
- **Behaviour:** When `python3 -c` fails (module missing, or `python3` not installed
  at all), `set -e` is suppressed because `_toml_parse_python` was called from an `if`
  condition, so execution does **not** return — it falls through to the read loop at
  `lib/03_toml_parser.sh:92-97` with an empty `$output`. The herestring `<<< ""`
  yields one empty line, so `key=""` and the loop executes
  `TOML_VALUES["$key"]="$val"` with an empty subscript. That is a fatal bash
  expansion error, which exits the shell immediately — from inside the `if` condition,
  before the fallback at `lib/03_toml_parser.sh:31` can ever run.
- **Reproduced** (scratchpad, no system changes): with a `python3` stub that exits 1,
  sourcing the module and calling `toml_parse_file` gives
  `lib/03_toml_parser.sh: line 95: TOML_VALUES["$key"]: bad array subscript` and
  shell exit status 1. `_toml_parse_bash` is never reached.
- **Impact:** `config_load` (`lib/04_config.sh:12-16`) calls `toml_parse_file`
  whenever `--config` is passed, and `--config` is *mandatory* in headless mode
  (`setup.sh:96-99`). So on any affected distro, `sudo bash setup.sh --headless
  --config x.toml` dies with a bash internal error before the banner, and the
  documented graceful degradation for old Pythons does not exist.
- **Where:** `lib/03_toml_parser.sh:25-31`, `lib/03_toml_parser.sh:88-97`,
  `lib/04_config.sh:12-16`
- **Distro/version:** Ubuntu 22.04 (Python 3.10), CentOS Stream 9 / RHEL 9 /
  Rocky 9 / Alma 9 / Oracle 9 (Python 3.9 default), openSUSE Leap 15.x, and any host
  with no `python3` at all. Debian 12 (3.11), Ubuntu 24.04 (3.12), Fedora 39+ and
  Arch are unaffected.
- **Confidence: 5** — `tomllib` is
  [Added in version 3.11](https://docs.python.org/3/library/tomllib.html);
  [RHEL 9 ships Python 3.9 as the default `python3`](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/installing_and_using_dynamic_programming_languages/assembly_introduction-to-python_installing-and-using-dynamic-programming-languages);
  [Ubuntu jammy is Python 3.10](https://packages.ubuntu.com/jammy/python3). The crash
  itself is reproduced, not inferred.
- **Fix:** Two changes, both needed. In `_toml_parse_python`, make the python failure
  return early: `output=$(python3 -c "$py_script" "$file") || return 1`. And guard the
  loop body: `[[ -n "$key" ]] || continue`. The first restores the fallback; the
  second stops any blank line in future output from killing the shell.
- **Why CI does not catch it:** `tests/distro/test_integration.sh:66` asserts
  `setup.sh --headless --config ...` by grepping the combined output for
  `error\|fail`. A crash and a correct validation rejection both match, so the
  `centos9` box — the one machine in the harness that has Python 3.9 — reports
  "PASS: invalid config rejected" while actually crashing.

### F-05 [degraded] Every `pip3 install` fallback is dead on all currently-supported distros (PEP 668)

- **Situation:** Three call sites fall back to pip when the distro package for
  `podman-compose` is unavailable: `lib/05_prerequisites.sh:243` (Arch, inside
  `_install_podman`), `lib/05_prerequisites.sh:294` (Arch, inside `_install_compose`),
  and `_pip_install_compose` at `lib/05_prerequisites.sh:309-319` (debian, rhel, suse).
- **Behaviour:** PEP 668 marks the system interpreter externally managed via
  `/usr/lib/python3.X/EXTERNALLY-MANAGED`, and pip refuses to install into it. The
  marker is shipped by default on Debian 12+, Ubuntu 23.04+, Fedora 36+ and Arch.
  `pip3 install "podman-compose==1.3.0"` therefore fails with
  `error: externally-managed-environment` on every distro the README claims except
  Ubuntu 22.04 — which F-01 already rules out.
- **Impact:** The two Arch call sites are `2>/dev/null || true`, so the user sees
  nothing and the run continues to `_check_compose`, which then exits with "A compose
  tool is required." — a correct outcome reached by an opaque route.
  `_pip_install_compose` at least logs, but its two precondition checks (pip3 present,
  Python >= 3.8) both pass and then the install fails anyway, so the careful error
  messages point at the wrong cause.
- **Where:** `lib/05_prerequisites.sh:243`, `lib/05_prerequisites.sh:294`,
  `lib/05_prerequisites.sh:309-319`
- **Distro/version:** Debian 12+, Ubuntu 24.04, Fedora 39+, Arch, openSUSE Tumbleweed
- **Confidence: 5** — [PEP 668 / "Externally managed environments"](https://pythonspeed.com/articles/externally-managed-environment-pep-668/)
  documents the marker file and the affected distro set.
- **Fix:** Use `pipx install podman-compose==1.3.0` when `pipx` is present, and
  otherwise install into a dedicated venv (`python3 -m venv /opt/matrix/venv &&
  /opt/matrix/venv/bin/pip install podman-compose==1.3.0`) and set `COMPOSE_CMD` to
  the venv path. Do **not** reach for `--break-system-packages`: that is exactly the
  cross-distro breakage this audit exists to prevent, and it would silently modify the
  distro's Python.

### F-06 [silent-corruption] `pacman -Sy` performs an unsupported partial upgrade on Arch

- **Situation:** `lib/05_prerequisites.sh:238` runs
  `pacman -Sy --noconfirm podman fuse-overlayfs slirp4netns`.
- **Behaviour:** `-Sy` refreshes the package database and then installs named packages
  against it *without* upgrading the rest of the system. Arch is a rolling release
  where packages are rebuilt against current library versions; installing a
  freshly-built podman against an older in-place glibc/systemd is the textbook
  partial-upgrade scenario Arch explicitly does not support.
- **Impact:** On an Arch box that has not been updated recently — the common case for
  a server someone is about to repurpose — this can pull in a podman built against a
  newer libc/libseccomp than the installed one, leaving podman (or, worse, an
  unrelated system package dragged in as a dependency) broken. The failure surfaces
  later and looks nothing like a package-manager problem.
- **Where:** `lib/05_prerequisites.sh:238` (the other Arch `pacman -S` calls at
  `:245`, `:292`, `:341`, `:351` and `lib/10_hardening.sh:240` use plain `-S`, which
  is correct)
- **Distro/version:** Arch Linux, Manjaro, EndeavourOS
- **Confidence: 5** — [ArchWiki, System maintenance / Partial upgrades are unsupported](https://wiki.archlinux.org/title/System_maintenance#Partial_upgrades_are_unsupported):
  "Synchronizing the pacman database and only upgrading selected packages ... can
  cause applications to become unstable or completely stop working."
- **Fix:** `pacman -Syu --noconfirm podman fuse-overlayfs slirp4netns`. This does mean
  a full system upgrade, which is a big side effect for an installer — so tell the
  user first. The alternative (`-S` without `-y`, against a possibly stale db) is
  worse, because it will simply fail to find current package versions.

### F-07 [degraded] On Arch, `_install_podman` never tries the official repo for `podman-compose` and jumps straight to the AUR — for a package that has been in `extra` all along

- **Situation:** `lib/05_prerequisites.sh:239-244`, comment reads "Try official repo
  first, fall back to AUR for podman-compose". The code that follows is
  `if ! pacman -Qq podman-compose &>/dev/null; then _install_aur_package ...`.
- **Behaviour:** `pacman -Qq` queries the *local* database — it answers "is this
  installed", not "is this available". On a host that does not already have
  podman-compose (the only case that reaches this code) it always returns non-zero,
  so the AUR bootstrap always runs. `pacman -S podman-compose` is never attempted.
  `podman-compose` is an official `extra` package (currently 1.6.0-1).
- **Impact:** A one-line `pacman -S podman-compose` is replaced by: clone yay from the
  AUR, show the user a PKGBUILD, compile it, install it, then use it to install a
  package that was in `extra`. In HEADLESS mode `_aur_consent`
  (`lib/05_prerequisites.sh:100-113`) refuses outright unless `MATRIX_ALLOW_AUR=true`,
  so the chain falls to `pip3 install podman-compose 2>/dev/null || true` — which
  fails silently under PEP 668 (F-05) — and the run dies at `_check_compose` with
  "A compose tool is required." on a machine where the package was one command away.
  Note `_install_compose` (`lib/05_prerequisites.sh:289-295`) gets this right; the two
  Arch paths disagree.
- **Where:** `lib/05_prerequisites.sh:239-244`
- **Distro/version:** Arch Linux, EndeavourOS, Manjaro
- **Confidence: 5** — [archlinux.org/packages/extra/any/podman-compose](https://archlinux.org/packages/extra/any/podman-compose/);
  `pacman -Q` is the local-database query operation per `pacman(8)`.
- **Fix:** Replace the `-Qq` test with an actual install attempt, matching
  `_install_compose`: `pacman -S --noconfirm --needed podman-compose || { AUR; }`.
  Given F-08, the honest option is to delete the AUR machinery from this path
  entirely.

### F-08 [will-crash] The AUR helper bootstrap cannot succeed on a minimal Arch host: `git` and `sudo` are not in `base`, and `makepkg` is called without `--syncdeps`

- **Situation:** `_install_aur_helper` (`lib/05_prerequisites.sh:141-215`) clones the
  helper with `git clone`, then builds it with
  `_as_user "$build_user" bash -c "cd ... && makepkg --noconfirm"`
  (`lib/05_prerequisites.sh:196`).
- **Behaviour:** Three independent blockers, all on a stock Arch install:
  1. `git` is not a dependency of `base`, and `_check_tools`
     (`lib/05_prerequisites.sh:325-360`) only requires curl/openssl/jq. The clone at
     `lib/05_prerequisites.sh:181` fails with "git: command not found" and the
     function reports "Failed to clone yay from the AUR".
  2. `makepkg` is invoked without `-s`/`--syncdeps`. yay is written in Go, so `go`
     is a `makedepends`. Without `-s`, makepkg performs the dependency check and
     halts with "Missing dependencies", never building.
  3. `_as_user` (`lib/05_prerequisites.sh:84-93`) correctly prefers `runuser` over
     `sudo` because "Arch installs do not always ship sudo" — which is true, `sudo`
     is not in `base` either. But `makepkg -s` (the fix for #2) shells out to
     `sudo pacman` itself, so adding `-s` reintroduces the sudo dependency the
     function was written to avoid.
- **Impact:** The commit message on `c65227f` says the AUR bootstrap "could never have
  worked as written". That claim is correct, and it is *still* correct after the
  commit: the hardening fixed the privilege-dropping and the temp-dir race, but not
  the reason the build cannot run. On a minimal Arch host the path fails at the clone;
  on a host with git it fails at makepkg. Combined with F-07, a headless Arch install
  cannot obtain a compose tool at all.
- **Where:** `lib/05_prerequisites.sh:181`, `lib/05_prerequisites.sh:196`,
  `lib/05_prerequisites.sh:84-93`, `lib/05_prerequisites.sh:325-333`
- **Distro/version:** Arch Linux (minimal / `base`-only install). The
  `archlinux/archlinux` Vagrant box in `tests/distro/Vagrantfile:69` ships git and
  sudo because Vagrant needs them, so the harness would not reproduce blocker 1 or 3.
- **Confidence: 5** — [`base` dependency list](https://archlinux.org/packages/core/any/base/)
  contains neither git nor sudo; [makepkg(8)](https://man.archlinux.org/man/makepkg.8.en)
  documents `-s` as "Install missing dependencies using pacman" and lists
  "User attempted to run makepkg as root" as a fatal error code.
- **Fix:** Delete the AUR path (see F-07 — the package is in `extra`). If it is kept
  for some future AUR-only dependency, it needs `git` added to `_check_tools` for
  `OS_FAMILY=arch`, `makepkg -s`, and an explicit precondition check that `sudo` is
  installed and the build user can use it, failing early with that message rather than
  after a clone.

### F-09 [will-crash] The generated `matrix-stack.container` Quadlet has no `Image=`, so the Quadlet generator rejects it on every distro

- **Situation:** `lib/20_quadlet.sh:47-67` writes a `.container` Quadlet whose
  `[Container]` section contains only `ContainerName=` and
  `PodmanArgs=--userns=keep-id`.
- **Behaviour:** `Image=` is the one mandatory key in a `[Container]` section
  ("There is only one required key, `Image`, which defines the container image the
  service runs"); the sole alternative is `Rootfs=`. A `.container` file with neither
  is not turned into a `.service` at all — the generator logs the error and skips the
  file.
- **Impact:** `matrix-stack.container` never becomes a unit. Nothing depends on it
  (the actual work is done by the separate `matrix-compose.service` written at
  `lib/20_quadlet.sh:76-95`), so the only visible symptom is a Quadlet generator
  error in the journal on every boot, forever. This is dead output rather than a
  broken deployment — but it is dead output that logs an error on a supported path.
- **Where:** `lib/20_quadlet.sh:47-67`
- **Distro/version:** all — this is not distro-specific, but it lands in the
  version-sensitive Quadlet surface the brief asked about, and it is noise that will
  mask a real Quadlet error later.
- **Confidence: 5** — [podman-systemd.unit(5)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html).
- **Fix:** Delete `matrix-stack.container`. The stack is deployed by compose via
  `matrix-compose.service`; a contentless placeholder Quadlet adds nothing. If the
  intent is to migrate to per-service Quadlets later, that is a separate change and
  should not leave a broken stub behind in the meantime.

### F-10 [silent-corruption] `run_as_user systemctl --user` cannot work: `sudo -u` sets no `XDG_RUNTIME_DIR`, and every call site swallows the failure

- **Situation:** `run_as_user` (`lib/01_utils.sh:274-277`) is
  `sudo -u "$matrix_user" -- "$@"`. Four call sites use it to drive the user manager:
  `lib/20_quadlet.sh:30` (`systemctl --user daemon-reload`),
  `lib/22_backup.sh:343` (`systemctl --user enable matrix-backup.timer`),
  `lib/23_media_retention.sh:78` (`systemctl --user enable
  matrix-media-cleanup.timer`), plus `lib/06_user.sh:67`.
- **Behaviour:** `systemctl --user` locates the user bus through `XDG_RUNTIME_DIR`
  (`/run/user/<uid>/bus`) or an explicit `DBUS_SESSION_BUS_ADDRESS`. `sudo -u` does
  not create a login session and sets neither, so the command fails with
  "Failed to connect to bus: $DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not
  defined". `loginctl enable-linger` (`lib/06_user.sh:75`) creates `/run/user/<uid>`
  but does not put its path into a `sudo` child's environment.
- **Impact:** Every one of those four calls ends in `2>/dev/null || true`, so the
  installer reports success. The user is told "Quadlet units installed"
  (`lib/20_quadlet.sh:36`) and gets a post-install report claiming backup and media
  retention timers are scheduled, when in fact: systemd never re-scanned the Quadlet
  directory, and neither timer is enabled. The stack comes up because `deploy_run`
  invokes compose directly — and then does not come back after a reboot, and backups
  never run. This is the worst failure mode in the report: everything reports green.
- **Where:** `lib/01_utils.sh:274-277`; call sites `lib/20_quadlet.sh:30`,
  `lib/22_backup.sh:343`, `lib/23_media_retention.sh:78`
- **Distro/version:** all systemd distros. Not distro-specific in cause, but it is
  distro-visible: the symptom (no autostart after reboot) is what a user reports as
  "works on your machine, not on mine".
- **Confidence: 4** — the `XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` requirement is
  documented behaviour of `systemctl --user`
  ([systemd bug tracker / Ask Ubuntu 1374347](https://askubuntu.com/questions/1374347/));
  4 rather than 5 because I have not run it here (doing so needs root and would touch
  the live session).
- **Fix:** Set the environment explicitly in `run_as_user`:
  `local uid; uid=$(id -u "$matrix_user"); sudo -u "$matrix_user"
  XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" -- "$@"`.
  Separately, drop the `|| true` from the three `systemctl --user` call sites — a
  failure to enable the backup timer must not be reported as success.

### F-11 [will-crash] `run_as_user` hard-requires `sudo`, which the same codebase already knows Arch may not have

- **Situation:** `lib/01_utils.sh:274-277` calls `sudo` unconditionally.
  `lib/05_prerequisites.sh:84-93` was written specifically because "Arch installs do
  not always ship sudo" and prefers `runuser`.
- **Behaviour:** `sudo` is not a dependency of Arch's `base` metapackage. On a host
  that uses `doas`, or where the admin escalates via `su`/`machinectl`, `run_as_user`
  fails with "sudo: command not found". The two paths that matter are not guarded:
  `lib/21_deploy.sh:52` (`run_as_user $COMPOSE_CMD ... up -d`, the actual deployment)
  and `lib/08_secrets.sh:110,114` (`podman secret create` under `--podman-secrets`).
- **Impact:** On a sudo-less Arch host the run gets all the way to the deploy phase —
  system user created, firewall reconfigured, SSH hardened, configs written — and then
  fails to start anything. `lib/11_postgres.sh:101` shows the right instinct
  (`check_command sudo && ...`) but that guard is local to postgres.
- **Where:** `lib/01_utils.sh:274-277`, used by `lib/21_deploy.sh:52`,
  `lib/08_secrets.sh:110,114`
- **Distro/version:** Arch Linux and derivatives on a minimal install; any host using
  doas instead of sudo.
- **Confidence: 5** — [`base` package dependencies](https://archlinux.org/packages/core/any/base/)
  do not include sudo.
- **Fix:** Give `run_as_user` the same `runuser`-first fallback `_as_user` already
  has, and pass the XDG variables from F-10 through it. `runuser` is in `util-linux`,
  which *is* in `base` and is present on every supported distro, so preferring it
  removes the dependency rather than papering over it.

### F-12 [will-crash] `harden_sysctl` aborts the installer on any host with IPv6 disabled, and every hardening sub-step can kill the run the same way

- **Situation:** `lib/10_hardening.sh:294-296` writes `net.ipv6.conf.all.accept_redirects=0`
  and `net.ipv6.conf.default.accept_redirects=0` into `/etc/sysctl.d/99-matrix.conf`,
  then runs `sysctl --system &>/dev/null` (`lib/10_hardening.sh:303`).
- **Behaviour:** On a host booted with `ipv6.disable=1` (common on VPS images and
  hardened builds) `/proc/sys/net/ipv6/` does not exist, so `sysctl` reports
  "cannot stat /proc/sys/net/ipv6/conf/all/accept_redirects" and exits 1. `--system`
  does **not** imply `-e`/`--ignore`, so the failure is real, and `&>/dev/null` hides
  the message but not the status.
- **Verified locally** (read-only, no key was written): a sysctl file naming a
  nonexistent key gives `sysctl -p` exit status 1; `man sysctl` confirms `-e,
  --ignore` is a separate opt-in and `--system` does not set it.
- **Impact:** `harden_all` (`lib/10_hardening.sh:12-17`) invokes each step as
  `[[ cond ]] && step`. A function that is the *last* element of an `&&` list is not
  exempt from `set -e` — confirmed:
  `bash -c 'set -e; f(){ return 1; }; g(){ [[ 1 == 1 ]] && f; }; g; echo SURVIVED'`
  prints nothing and exits 1. So the installer dies mid-hardening with only the ERR
  trap's generic message. The same structural problem means an explicit `return 1`
  from `_harden_ufw` (`lib/10_hardening.sh:97`), `_harden_firewalld`
  (`lib/10_hardening.sh:123,147,154`) or `_harden_nftables`
  (`lib/10_hardening.sh:187`) — all of which were deliberately written to surface
  failure rather than swallow it — kills the run rather than being reported.
- **Where:** `lib/10_hardening.sh:293-303`, structural issue at `lib/10_hardening.sh:12-17`
- **Distro/version:** any distro, whenever IPv6 is disabled at boot; also any host
  where the firewall step legitimately fails.
- **Confidence: 5** — sysctl exit status and `set -e` semantics both reproduced here.
- **Fix:** Two parts. Guard the IPv6 keys:
  `[[ -d /proc/sys/net/ipv6 ]]` before writing them, or split them into a second file
  written only when IPv6 is present (`HAS_IPV6` is already detected at
  `lib/02_detect.sh:120-130`). And change `harden_all` to `if [[ cond ]]; then step;
  fi` so a failing step is caught by `run_phase`'s error handling instead of the ERR
  trap — the `&&` form was never intended to make these fatal.

### F-13 [degraded] The nftables fallback ruleset breaks IPv6 and does not survive a reboot

- **Situation:** `_harden_nftables` (`lib/10_hardening.sh:157-193`) is the firewall
  backend used whenever neither `ufw` nor `firewall-cmd` is present — the default
  situation on Arch, and on minimal Debian/Ubuntu images.
- **Behaviour:** Two problems.
  1. The chain is `type filter hook input priority 0; policy drop` and the only ICMP
     rule is `icmp type echo-request limit rate 5/second accept`
     (`lib/10_hardening.sh:174`). `icmp` matches IPv4 ICMP only. All ICMPv6 is
     dropped, including Neighbour Discovery — NDP is the IPv6 equivalent of ARP and
     is carried entirely over ICMPv6, so dropping it breaks address resolution,
     router advertisement and duplicate address detection.
  2. Persistence is attempted by copying into `/etc/nftables.d/`
     (`lib/10_hardening.sh:187-189`) but only `if [[ -d /etc/nftables.d ]]`. That
     directory does not exist by default on Debian, Ubuntu or Arch, whose
     `nftables.service` reads `/etc/nftables.conf`. The copy is skipped silently, and
     `systemctl enable nftables` then enables a service that loads a file which knows
     nothing about the matrix rules.
- **Impact:** On an IPv6-enabled Arch or minimal Debian host, applying the ruleset
  drops the box off IPv6 — which for a Matrix homeserver means federation over IPv6
  and AAAA-based Let's Encrypt validation stop working, while IPv4 keeps working, so
  it presents as intermittent federation failures rather than as a firewall problem.
  On reboot the ruleset vanishes entirely and the host is unfirewalled, which is the
  opposite failure and equally silent.
- **Where:** `lib/10_hardening.sh:164-176` (ruleset), `lib/10_hardening.sh:186-190`
  (persistence)
- **Distro/version:** Arch Linux (no ufw/firewalld by default), minimal
  Debian/Ubuntu without ufw. Fedora/CentOS/openSUSE default to firewalld and take the
  other branch.
- **Confidence: 5** — [nftables wiki, "Simple ruleset for a server"](https://wiki.nftables.org/wiki-nftables/index.php/Simple_ruleset_for_a_server)
  includes `icmpv6 type { nd-neighbor-solicit, nd-router-advert, nd-neighbor-advert }
  accept` for exactly this reason;
  [Neighbor Discovery Protocol](https://en.wikipedia.org/wiki/Neighbor_Discovery_Protocol)
  for the NDP-over-ICMPv6 dependency.
- **Fix:** Add
  `icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert, echo-request } accept`
  to the input chain, and write the ruleset to `/etc/nftables.conf` via an `include`
  line (or install a small `matrix-nftables.service` that runs `nft -f` on the file)
  rather than relying on a `/etc/nftables.d` convention that only some distros have.
  Add `flush table inet matrix_filter` at the top so re-runs are idempotent.

### F-14 [degraded] The fail2ban jail relies on `backend = auto` finding `/var/log/auth.log`, which Ubuntu 24.04 no longer produces

- **Situation:** `lib/10_hardening.sh:255-268` writes a jail file with
  `backend = auto` for `[matrix-synapse]` and a bare `[sshd]` jail with no `backend`
  or `logpath`.
- **Behaviour:** Ubuntu 24.04 does not install `rsyslog` by default, so nothing writes
  `/var/log/auth.log`; authentication events live only in the journal. fail2ban's
  file-watching backends then find no log for the `sshd` jail and the jail fails to
  start — in fail2ban 1.x this is fatal to the whole service, not just the one jail.
- **Impact:** `systemctl enable --now fail2ban` and `systemctl restart fail2ban`
  (`lib/10_hardening.sh:277-278`) are both `2>/dev/null || true`, so the installer
  prints "Configuring fail2ban" and moves on. The user believes SSH brute-force
  protection is active; it is not, and neither is the Matrix login jail, because the
  service as a whole is down.
- **Where:** `lib/10_hardening.sh:255-268`, `lib/10_hardening.sh:277-278`
- **Distro/version:** Ubuntu 24.04+ and any host without rsyslog (increasingly the
  default on minimal cloud images across distros).
- **Confidence: 4** — Ubuntu 24.04 dropping rsyslog from the default install and the
  resulting fail2ban breakage are both widely reported
  ([fail2ban#3245](https://github.com/fail2ban/fail2ban/issues/3245),
  [fail2ban#3567](https://github.com/fail2ban/fail2ban/issues/3567), and the original
  [Debian#770171](https://groups.google.com/g/linux.debian.bugs.dist/c/6ag6r1jSCqg)
  "sshd jail fails when system solely relies on systemd journal for logging").
  4 rather than 5 because the exact default package set varies between Ubuntu's
  server, minimal and cloud images.
- **Fix:** Set `backend = systemd` on the `[sshd]` jail (and omit `logpath` there);
  keep `backend = auto` for `[matrix-synapse]`, whose logpath is a real file the
  installer creates. Better still, detect: if `/var/log/auth.log` is absent, use the
  systemd backend. And drop the `|| true` from the `systemctl restart fail2ban` so a
  dead service is reported rather than hidden.

### F-15 [degraded] `_enable_podman_socket` enables the *root* podman socket in an otherwise rootless deployment

- **Situation:** `lib/05_prerequisites.sh:218-229`, called from `_check_podman`, runs
  `systemctl enable --now podman.socket` as root, with the comment "Enable
  podman.socket for rootless Podman systemd integration (Quadlet)".
- **Behaviour:** The installer runs as root, so this enables the *system* unit and
  exposes the root Podman API at `/run/podman/podman.sock`. The deployment runs as
  the unprivileged `matrix` user; its rootless socket would be
  `systemctl --user enable podman.socket` in that user's manager, which is a different
  unit. Separately, Quadlet is a systemd generator that invokes `podman` directly — it
  does not consume the API socket at all, so neither socket is needed for the stated
  purpose.
- **Impact:** A root-privileged container API socket is enabled on every install for
  no functional benefit. It is not a remote exposure (unix socket, root-owned), but it
  is a privilege surface the deployment explicitly set out not to have, and it is
  enabled `--now` and persists across reboots. The unit-existence guard at
  `lib/05_prerequisites.sh:219` is correct — verified here that `systemctl
  list-unit-files <missing>.socket` exits 1 on systemd 255 — so this fires on every
  distro that ships the unit, which is all of them.
- **Where:** `lib/05_prerequisites.sh:60-61`, `lib/05_prerequisites.sh:218-229`
- **Distro/version:** all
- **Confidence: 4** — Quadlet's independence from `podman.socket` follows from it
  being a generator producing units that exec `podman` ([podman-systemd.unit(5)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html));
  the rootful/rootless unit distinction is standard systemd. 4 because I have not
  exercised a Quadlet-managed stack with the socket masked to prove it is unnecessary.
- **Fix:** Remove `_enable_podman_socket` and its call site. If something in the stack
  is later found to need the API socket, enable it in the matrix user's manager via
  the fixed `run_as_user` from F-10/F-11, not as root.

### F-16 [degraded] openSUSE is a claimed platform with no test coverage and an unverified package list

- **Situation:** `README.md:42` lists openSUSE. `lib/02_detect.sh:50-51` maps
  `opensuse*` and `sles` to `OS_FAMILY=suse`, and five separate case statements have a
  `suse` branch: `lib/05_prerequisites.sh:249-251`, `:297-299`, `:337`, `:352`;
  `lib/10_hardening.sh:241`, `:319`.
- **Behaviour:** `tests/distro/Vagrantfile` has no openSUSE box, so not one of those
  branches has ever run. Two are visibly wrong on inspection:
  - `zypper install -y podman podman-compose uidmap slirp4netns`
    (`lib/05_prerequisites.sh:250`) uses `uidmap`, which is a Debian/Ubuntu package
    name. The same file's `_check_tools` uses `zypper install -y shadow` for `suse`
    (`lib/05_prerequisites.sh:352`), so the two paths disagree — the same
    disagreement as F-02 on the RHEL side, where the equivalent name was
    demonstrably wrong.
  - `harden_auto_updates` runs
    `zypper install -y yast2-online-update-configuration` (`lib/10_hardening.sh:319`),
    which installs a YaST configuration *module*. It does not schedule or enable any
    automatic update. The step logs "Enabling automatic security updates" and enables
    nothing. It is `|| true`, so it cannot fail loudly either.
- **Impact:** An openSUSE user gets a run that either dies on an unknown package name
  (if the `uidmap` name is wrong, as it is on RHEL) or completes while silently not
  doing what it reported. Note F-04 additionally makes `--config` crash on
  openSUSE Leap 15.x, whose default `python3` is well below 3.11.
- **Where:** `lib/05_prerequisites.sh:249-251`, `lib/10_hardening.sh:317-320`,
  `tests/distro/Vagrantfile`
- **Distro/version:** openSUSE Leap 15.x, openSUSE Tumbleweed, SLES 15
- **Confidence: 3** — `UNVERIFIED:` I could not find a citable openSUSE package listing
  either confirming or denying a `uidmap` package; `newuidmap` is packaged as `shadow`
  on Arch and `shadow-utils` on Fedora per
  [command-not-found.com/newuidmap](https://command-not-found.com/newuidmap), which
  lists no openSUSE row. The claim that the branch is *untested* is confidence 5 (no
  box in the Vagrantfile); the claim that `uidmap` is the wrong name there is
  confidence 3 and should be checked on a real openSUSE host before the fix is
  written. The `yast2-online-update-configuration` observation is confidence 4 — it is
  a YaST UI module by name and description, not a scheduler.
- **Fix:** Either add an `opensuse15` box to `tests/distro/Vagrantfile` and make the
  branches pass, or remove openSUSE from `README.md:42`. Shipping five untested
  per-distro branches for a platform nobody has booted is worse than not claiming it.

### F-17 [degraded] The SSH hardening drop-in is written without checking that `sshd_config` includes the drop-in directory

- **Situation:** `harden_ssh` (`lib/10_hardening.sh:41-75`) writes
  `/etc/ssh/sshd_config.d/99-matrix-hardening.conf`, validates with `sshd -t`, and
  reloads.
- **Behaviour:** `sshd -t` parses the *effective* configuration. If
  `/etc/ssh/sshd_config` has no `Include /etc/ssh/sshd_config.d/*.conf` line, the
  drop-in is never read, `sshd -t` passes because nothing changed, the reload
  succeeds, and the function returns 0 having applied nothing. There is no positive
  confirmation anywhere that the settings took effect.
- **Impact:** Fail-open on a security control the operator explicitly requested, with
  a success path indistinguishable from the working case. The user believes password
  authentication and root login are disabled.
- **Where:** `lib/10_hardening.sh:56-74`
- **Distro/version:** `UNCERTAIN:` Ubuntu 22.04/24.04, Debian 12, Fedora and RHEL 9
  all ship the `Include` line, so they are fine. I could not verify Arch's or
  openSUSE Leap's stock `sshd_config` from a citable source within budget — the
  ArchWiki OpenSSH page recommends drop-ins, which suggests Arch does include it, but
  I did not confirm the shipped file. Treat the distro list as unknown; the
  *structural* gap (no verification that the drop-in is read) is confidence 5 and
  holds regardless.
- **Confidence: 2** for the distro attribution, **5** for the missing verification.
- **Fix:** After writing the drop-in and passing `sshd -t`, confirm it took effect
  with `sshd -T | grep -qi '^passwordauthentication no'`. If it did not, log a warning
  naming the missing `Include` line and tell the user to add it — do not silently
  report success. This is cheap, distro-independent, and removes the need to know
  which distros ship the include.
