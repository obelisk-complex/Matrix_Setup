# dependency-auditor report

**Target:** `/media/owner/Workspace/Matrix_Setup` @ `qa/fleet-loop-20260910` - external artefact inventory, pinning, verification, and `docs/SUPPLY_CHAIN.md` claim conformance
**Started:** 2026-09-10T00:00:00Z
**Status:** COMPLETE (see `## Completion`)

## What works well

- **Every container image is digest-pinned.** All 17 `*_IMAGE` constants in
  `lib/00_constants.sh:31-49` use `registry/repo:tag@sha256:<64hex>`. No `latest`,
  no bare tag, no floating major. Podman treats a `@sha256` reference as
  content-addressed, so a re-pushed tag cannot change what is deployed.
- **The pinning survives the whole path to runtime.** `lib/19_compose.sh:119-151`
  substitutes the constants into `templates/compose/*.yml` placeholders; the
  templates carry no literal image refs of their own. Bridge plugins
  (`bridges/*.sh:7-8`) echo the constant rather than a literal. `lib/20_quadlet.sh:115`
  interpolates `${COTURN_IMAGE}`. There is no path by which an unpinned ref reaches
  a compose file or Quadlet unit.
- **No `curl | bash`, no `wget | sh`, no plain-HTTP downloads.** Verified by grep
  across `*.sh`, `*.yml`. Every outbound `http://` is a localhost or
  container-network health check / proxy backend, not a fetch of executable content.
- **Both workflows SHA-pin their actions.** `.github/workflows/ci.yml:14` and
  `.github/workflows/release.yml:18,27,33,50` all use 40-hex commit SHAs with a
  `# vX` comment. This closes the finding recorded in the 2026-06-13 audit, and it
  matters here because `release.yml` holds `id-token: write` and
  `attestations: write`.
- **`persist-credentials: false`** on the release checkout (`release.yml:20`) keeps
  the `GITHUB_TOKEN` out of `.git/config` for the subsequent steps that run
  third-party binaries (syft, cosign).
- **Digest drift is a release gate.** `release.yml:23-24` runs
  `scripts/pin-digests.sh --check` before anything is signed, so a stale pin fails
  the release rather than shipping.
- **The AUR path is consent-gated and never builds as root.**
  `lib/05_prerequisites.sh:96-113` refuses in `HEADLESS` unless `MATRIX_ALLOW_AUR=true`;
  `_aur_build_user` (`:71-81`) resolves `SUDO_USER` and fails closed if it is absent
  or root; `_install_aur_helper` builds in an `mktemp -d` directory, not a
  predictable `/tmp` path, and prints the PKGBUILD for approval before running it.
  This is a materially better posture than the typical `yay -S` one-liner.
- **`pin-digests.sh` refuses a non-HTTPS token realm** (`scripts/pin-digests.sh:53`),
  which is the right call: the realm comes from an attacker-influenceable
  `WWW-Authenticate` header.
- **`pin-digests.sh` writes atomically** (temp file in the same directory, then `mv`,
  `:117-134`) and validates the digest shape against `^sha256:[0-9a-f]{64}$` before
  accepting it (`:67`), so a malformed response cannot corrupt the constants file.
- **Licence is MIT** (`LICENSE`), consistent with README and with every dependency
  being a separately-distributed container image rather than linked code. No
  copyleft exposure.

## External artefact inventory

Every artefact the suite pulls onto the target machine, its reference form, and
what is verified before use.

### Container images (17) - `lib/00_constants.sh:31-49`

| Var | Registry | Reference form | Verified before use |
|---|---|---|---|
| `SYNAPSE_IMAGE` | docker.io/matrixdotorg | `v1.127.1@sha256:c3c4a9de…` | digest (content-addressed) |
| `DENDRITE_IMAGE` | ghcr.io/element-hq | `v0.14.1@sha256:a0212bbb…` | digest |
| `POSTGRES_IMAGE` | docker.io (official) | `16.14-alpine@sha256:16bc17c6…` | digest |
| `CADDY_IMAGE` | docker.io/library | `2.11.4-alpine@sha256:77c07d5e…` | digest |
| `COTURN_IMAGE` | docker.io/coturn | `4.9.0-alpine@sha256:229f87ef…` | digest |
| `ELEMENT_IMAGE` | docker.io/vectorim | `v1.11.96@sha256:13d0ea68…` | digest |
| `CINNY_IMAGE` | ghcr.io/cinnyapp | `v4.12.2@sha256:985daecc…` | digest |
| `SCHILDICHAT_IMAGE` | ghcr.io/etkecc | `1.11.36-sc.3@sha256:859e14d1…` | digest |
| `SYNAPSE_ADMIN_IMAGE` | ghcr.io/etkecc | `v0.11.4-etke54@sha256:668552a2…` | digest |
| `PROMETHEUS_IMAGE` | docker.io/prom | `v3.2.1@sha256:6927e091…` | digest |
| `GRAFANA_IMAGE` | docker.io/grafana | `11.5.2@sha256:8b37a2f0…` | digest |
| `BRIDGE_TELEGRAM_IMAGE` | **dock.mau.dev**/mautrix | `v0.15.2@sha256:ac6dc408…` | digest |
| `BRIDGE_DISCORD_IMAGE` | **dock.mau.dev**/mautrix | `v0.7.2@sha256:6d44d267…` | digest |
| `BRIDGE_WHATSAPP_IMAGE` | **dock.mau.dev**/mautrix | `v0.11.3@sha256:ef4b91c1…` | digest |
| `BRIDGE_SIGNAL_IMAGE` | **dock.mau.dev**/mautrix | `v0.7.4@sha256:0185c6e4…` | digest |
| `BRIDGE_SLACK_IMAGE` | **dock.mau.dev**/mautrix | `v0.1.3@sha256:5afa6996…` | digest |
| `BRIDGE_IRC_IMAGE` | docker.io/hif1 | `1.9.0@sha256:eed68de5…` | digest |

No image signature (cosign/sigstore) or `containers-policy.json` verification is
performed at pull time - digest pinning only. See DEP-005.

### Host packages

| Source | Where | Reference form | Verified |
|---|---|---|---|
| `apt-get install podman podman-compose uidmap slirp4netns` | `lib/05_prerequisites.sh:229-231` | unversioned, distro repo | apt GPG (distro default) |
| `dnf`/`yum install …` | `:233-238` | unversioned, distro repo | dnf GPG (distro default) |
| `pacman -Sy … podman fuse-overlayfs slirp4netns` | `:241` | unversioned, distro repo | pacman sig level (distro default) |
| `zypper install …` | `:246` | unversioned, distro repo | zypper GPG (distro default) |
| `pip3 install "podman-compose==1.3.0"` | `:318` | **version-pinned**, no hash | TLS only (no `--require-hashes`) |
| `pip3 install podman-compose` | `:243`, `:294` | **UNPINNED**, failure swallowed | TLS only. See DEP-001 |
| AUR `podman-compose` via `yay` | `:243`, `:293` | unversioned AUR PKGBUILD | user consent + PKGBUILD display |
| AUR helper `yay`/`aura` source clone | `:172` | `git clone --depth 1`, **no commit pin** | user consent + PKGBUILD display. See DEP-002 |
| `pacman -S --needed shadow` | `:245` | unversioned, distro repo | distro default |
| `curl openssl jq` | `:324-338` | unversioned, distro repo | distro default |

### CI-fetched artefacts

| Artefact | Where | Reference form | Verified |
|---|---|---|---|
| `actions/checkout` | `ci.yml:14`, `release.yml:18` | SHA `df4cb1c0…` (v6.0.3) | commit SHA |
| `anchore/sbom-action/download-syft` | `release.yml:27` | SHA `e22c3899…` (`# v0`) | commit SHA |
| `sigstore/cosign-installer` | `release.yml:33` | SHA `398d4b0e…` (`# v3`) | commit SHA |
| `actions/attest-build-provenance` | `release.yml:50` | SHA `a2bbfa25…` (v4.1.0) | commit SHA |
| `shellcheck` (apt) | `ci.yml:16-17` | unversioned, ubuntu repo | apt GPG |
| syft binary | downloaded by `sbom-action` | whatever the action resolves | delegated to action. See DEP-007 |

### Runtime network calls (not artefact fetches, listed for completeness)

- `lib/02_detect.sh:153,156` - `curl https://ifconfig.me` for public IP discovery.
  HTTPS, third-party, result used only for display/DNS suggestion; failure yields
  empty string.
- `lib/07_network.sh:151-179` - Cloudflare API over HTTPS with a user-supplied token.
- `lib/21_deploy.sh`, `lib/23_media_retention.sh` - localhost Synapse admin API.

None of these fetch executable content.

## Findings

### DEP-001 - HIGH - Unpinned `pip3 install podman-compose` on the Arch path, contradicting the documented posture

**Confidence: 5** (traced both call sites and the caller that consumes the result)

**Situation.** `lib/05_prerequisites.sh:318` defines `_pip_install_compose`, which pins
`podman-compose==1.3.0` and checks for `pip3` and Python >= 3.8 first. Its own comment
says it "pins the version for reproducibility instead of pulling whatever is latest on
PyPI at install time". `docs/SUPPLY_CHAIN.md:11-12` states this as the project's
posture: *"The only network-fetched package is `podman-compose` (pip fallback), which is
version-pinned and guarded by pip3/Python presence checks."*

**Behaviour.** The two Arch branches do not call it. They inline an unpinned install:

- `lib/05_prerequisites.sh:243` (in `_install_podman`, arch case)
- `lib/05_prerequisites.sh:294` (in `_install_compose`, arch case)

```bash
pip3 install podman-compose 2>/dev/null || true
```

No version pin, no `--require-hashes`, no pip3/Python guard, run as root (setup.sh runs
as root, and this branch is not privilege-dropped). The debian/rhel/suse branches
(`:257-278`) correctly route through `_pip_install_compose`.

**Impact.** On Arch, if the AUR route fails, the machine installs whatever
`podman-compose` PyPI currently serves - a different artefact on every run, and the one
package in this suite that is not covered by digest pinning, distro GPG, or the
documented version pin. It is installed system-wide as root. If PyPI's
`podman-compose` were ever compromised or yanked-and-replaced, this is the entry point,
and it is the exact scenario the pinned helper 25 lines below exists to prevent.

The `|| true` is *not* the severe part: `_check_compose` (`:283-...`) re-runs
`detect_compose_command` and exits `E_PREREQ` if nothing is found, so a swallowed
failure surfaces. The severity is entirely in the missing pin.

**Fix.** Replace both call sites with `_pip_install_compose`. Consider
`pip3 install --require-hashes -r` with a small pinned requirements file so the pin is
integrity-checked, not just version-selected.

---

### DEP-002 - HIGH - `docs/SUPPLY_CHAIN.md` omits the AUR path entirely, understating what the installer executes

**Confidence: 5** (claimed text and actual code path both read in full)

**Situation.** `docs/SUPPLY_CHAIN.md:5-13` is the "Current posture" section - the
document a user or downstream packager reads to decide whether to trust this installer.
It lists three things: digest-pinned images, no `curl | bash`, and *"the only
network-fetched package is podman-compose"*.

**Behaviour.** On Arch, `lib/05_prerequisites.sh:120-207` can:

1. `git clone --depth 1 https://aur.archlinux.org/yay.git` (`:172`) - **unpinned**, no
   commit SHA, no tag, no signature. Whatever is at AUR HEAD at that moment.
2. Run `makepkg --noconfirm` on the cloned PKGBUILD (`:190`) - arbitrary shell,
   arbitrary network fetches, executed as the invoking user.
3. `pacman -U --noconfirm "$pkg"` (`:201`) - install the resulting package **as root**,
   with `--noconfirm` so no signature or install-script prompt intervenes.
4. Then `yay -S podman-compose` (`:143`) - a second unvetted PKGBUILD, whose own
   sources are never shown to the user.

None of this appears in `SUPPLY_CHAIN.md`. The document's own framing ("no `curl | bash`")
invites the reader to conclude nothing unvetted is executed; the AUR path is materially
more powerful than a `curl | bash` would be, because it ends in a root `pacman -U`.

**Impact.** The gap between claimed and actual posture is the defect here, not the AUR
support itself - the code is carefully written (consent-gated, `mktemp`, non-root build,
PKGBUILD displayed; see "What works well"). But a reader auditing this project against
`SUPPLY_CHAIN.md` alone would not know that an Arch install can compile and root-install
third-party code, nor that `MATRIX_ALLOW_AUR=true` in a headless deployment silently
enables it with the PKGBUILD review step skipped (`:180`, the display is inside
`if [[ "$HEADLESS" != "true" ]]`).

**Fix.** Add an "AUR / Arch" subsection to `SUPPLY_CHAIN.md` stating: which packages can
come from the AUR, that the clone is unpinned, that `MATRIX_ALLOW_AUR=true` skips the
PKGBUILD review, and that the resulting package is installed by root. Correct the "only
network-fetched package" sentence. Separately, consider pinning the AUR helper clone to
a known commit and verifying it, so the reviewed PKGBUILD and the built PKGBUILD are
provably the same artefact across runs.

---

### DEP-003 - HIGH - Pinned Synapse `v1.127.1` carries three published advisories, one HIGH

**Confidence: 5** (advisory version ranges compared directly against the pin)

**Situation.** `lib/00_constants.sh:31` pins
`docker.io/matrixdotorg/synapse:v1.127.1@sha256:c3c4a9de…`. Synapse is the
federation-facing homeserver - the most exposed component in the stack. Upstream latest
is `v1.160.0` (2026-09-02), 33 minor versions ahead.

**Behaviour.** Against the GitHub Advisory Database (queried 2026-09-10):

| Advisory | Severity | Range | v1.127.1 |
|---|---|---|---|
| [GHSA-8q93-326v-3m7g](https://github.com/advisories/GHSA-8q93-326v-3m7g) | **high** | `< 1.152.1` | **affected** - CPU starvation DoS |
| [GHSA-6qf2-7x63-mm6v](https://github.com/advisories/GHSA-6qf2-7x63-mm6v) | medium | `< 1.152.1` | **affected** - pagination DoS |
| [GHSA-fh66-fcv5-jjfr](https://github.com/advisories/GHSA-fh66-fcv5-jjfr) | medium | `< 1.138.3` | **affected** - invalid device keys degrade federation |
| [GHSA-v56r-hwv5-mxg6](https://github.com/advisories/GHSA-v56r-hwv5-mxg6) | high | `< 1.127.1` | not affected (this pin *is* the fix) |

The last row is informative: `v1.127.1` was chosen as a security bump in March 2025 and
has not moved since.

**Impact.** All three are remotely reachable over federation, which this suite enables by
default (`lib/21_deploy.sh:213` health-checks the federation endpoint). Availability, not
confidentiality - but an unauthenticated remote DoS on a self-hosted homeserver is the
failure mode this project's users are least equipped to diagnose.

Digest pinning is working exactly as designed here, and that is the point: pinning
freezes the artefact, so without a bump process the pin ages into a liability. This is a
*currency* defect, not a pinning defect.

**Fix.** Bump `SYNAPSE_IMAGE` to `v1.152.1` at minimum (clears all three), preferably
current `v1.160.0`, then re-run `scripts/pin-digests.sh`. See DEP-009 for the process
gap that let this drift.

---

### DEP-004 - MEDIUM - `pin-digests.sh` trusts the registry's `Docker-Content-Digest` header instead of computing the digest

**Confidence: 5** (the script uses `curl -sI`, a HEAD request, so it cannot compute)

**Situation.** `scripts/pin-digests.sh:62-67` is where the repo's entire chain of trust is
established. Every image's `@sha256:` comes from here.

**Behaviour.**

```bash
digest=$(curl -sI "${auth[@]}" -H "Accept: $ACCEPT" "$murl" \
    | grep -i '^docker-content-digest:' | head -1 | awk '{print $2}' | tr -d '\r')
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
```

`curl -sI` issues a HEAD, so no manifest body is retrieved and the digest is never
verified against content. The value is whatever the server asserts in a response header.
The regex validates the *shape* of the digest, not its correctness.

**Impact.** Pinning is trust-on-first-use against whatever answered at pin time. A
compromised registry, a hostile TLS-terminating proxy, or a registry-side bug could hand
back a digest that does not correspond to the manifest a client would fetch for that tag.
Podman *does* verify the digest at pull time, so the failure mode is not "wrong content
runs" - it is "the pin is for content that either never existed or is not what the tag
served", which surfaces as an unexplained pull failure, or as a pin to attacker-chosen
content if the same actor controls both pin time and pull time.

The exposure is narrow (maintainer's machine or CI, HTTPS, brief window) which is why
this is MEDIUM not HIGH. But `--check` inherits the same weakness: it compares one
server-asserted header against another, so it detects upstream re-tagging and nothing else.

**Fix.** Fetch the manifest body and compute the digest locally, then compare it to the
header:

```bash
body=$(curl -s "${auth[@]}" -H "Accept: $ACCEPT" "$murl")
digest="sha256:$(printf '%s' "$body" | sha256sum | cut -d' ' -f1)"
```

This is how the digest is *defined* (sha256 over the manifest bytes), so it needs no
extra trust. Keep the header comparison as a cross-check and warn on mismatch.

---

### DEP-005 - MEDIUM - No image signature or provenance verification at pull time

**Confidence: 5** (grepped for `--tls-verify`, `policy.json`, `cosign verify`, `--signature-policy` across `lib/`, `scripts/`, `setup.sh`, `templates/`; nothing)

**Situation.** The project signs and attests *its own* release artefacts thoroughly
(`release.yml:32-54`), and `README.md:17` advertises "pinned, digest-verified container
images".

**Behaviour.** For the 17 third-party images, verification stops at the digest. There is
no `containers-policy.json` written, no `podman image trust` configuration, no
`cosign verify` of an image signature, and no verification of upstream SLSA provenance.
Several of these images *are* signed upstream - Grafana and Prometheus publish cosign
signatures, and GHCR images from `element-hq` and `cinnyapp` carry GitHub-generated
provenance attestations.

**Impact.** Digest pinning answers "is this the bytes I recorded?" It does not answer
"did the project I trust produce these bytes?" If a maintainer's pin run resolved a
malicious digest (DEP-004), or if a namespace were taken over between version bumps,
digest pinning would faithfully and permanently reproduce the compromise. Signature
verification is the control that catches this class; it is absent.

Note the asymmetry worth stating plainly: this project holds its own artefacts to a
higher standard (keyless cosign + SLSA provenance) than the 17 images it installs on the
user's machine.

**Fix.** Write a `containers-policy.json` for the deployment user requiring sigstore
signatures for the registries that publish them, with an explicit, documented
`insecureAcceptAnything` for those that do not, so the gap is visible rather than
implicit. At minimum, add a release-time `cosign verify` step for the images that are
signed upstream, alongside the existing `--check`.

---

### DEP-006 - MEDIUM - `pin-digests.sh --check` runs only at release; nothing verifies a version bump was re-pinned

**Confidence: 5** (both workflows read in full)

**Situation.** `docs/SUPPLY_CHAIN.md:29-33` documents the bump procedure as: edit the tag,
run `pin-digests.sh`, commit - and asserts *"CI/`--check` will fail a release if a pinned
digest ever drifts."*

**Behaviour.** `.github/workflows/ci.yml` (every push and PR) runs shellcheck and the test
suite. It does **not** run `pin-digests.sh --check`. The only invocation is
`release.yml:24`, on a `v*` tag.

**Impact.** Step 2 of the documented procedure is unenforced. A PR that bumps a tag in
`lib/00_constants.sh` and forgets to re-pin merges cleanly; the tag/digest pair is then
internally inconsistent - the tag says one version, the digest pulls another - and this
is invisible until someone cuts a release, potentially many commits later. Because the
digest wins at pull time, the deployed version silently disagrees with what the constants
file appears to say, and with what `lib/24_report.sh:69` prints to the user.

There is no test asserting tag/digest consistency either: `tests/` has 300 passing tests
(verified locally, `300 passed, 0 failed`), none touching `lib/00_constants.sh` pins.

**Fix.** Add `bash scripts/pin-digests.sh --check` to `ci.yml`. It needs no credentials
(all images public) and no runtime. If outbound registry calls on every PR are unwanted,
add a cheaper offline test asserting every `*_IMAGE` matches
`^[a-z0-9./-]+:[^@]+@sha256:[0-9a-f]{64}$`, and schedule the full `--check` nightly.

---

### DEP-007 - MEDIUM - `_enable_podman_socket` enables the **root** Podman API socket, while the comment claims it is for rootless

**Confidence: 5** (code traced; premise checked against Podman's official Quadlet documentation)

**Situation.** `lib/05_prerequisites.sh:207-220`, called unconditionally from
`_check_podman:60` on every run, as root:

```bash
# Auto-enable podman.socket for rootless Podman systemd integration
_enable_podman_socket() {
    if systemctl list-unit-files podman.socket &>/dev/null; then
        if ! systemctl is-enabled --quiet podman.socket 2>/dev/null; then
            systemctl enable --now podman.socket
```

**Behaviour.** Two things are wrong with the stated rationale.

1. `systemctl enable` without `--user` enables the **system** unit. The rootless socket
   is `systemctl --user enable podman.socket`, run as the target user. This suite's
   rootless machinery is elsewhere and is correct: `lib/06_user.sh:75` enables
   `loginctl` lingering and `lib/20_quadlet.sh:16,30` writes to
   `${user_home}/.config/containers/systemd` and runs `systemctl --user daemon-reload`.
   The socket enabled here belongs to root and is not used by any of that.
2. Quadlet does not need the socket at all. Per Podman's `podman-systemd.unit(5)`,
   Quadlet is a **systemd generator**: it reads `.container`/`.volume`/`.network` files
   at boot and on `daemon-reload` and emits ordinary `.service` units. It does not speak
   to a Podman API socket.
   Source: <https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html>

**Impact.** Every install activates a root-owned, Docker-compatible REST API at
`/run/podman/podman.sock` that nothing in this project uses. Access to that socket is
equivalent to root on the host. The socket is root-owned mode 0660, so this is an
attack-surface expansion rather than an immediate exposure - but it is a permanent,
enabled-at-boot expansion granted for a benefit that does not exist, on a host whose
whole purpose is to face the internet.

The failure path is also silent-by-design: `:217` swallows the error into a `log_warn`,
so the install proceeds identically whether or not the socket was enabled - which is
itself evidence nothing depends on it.

**Fix.** Delete `_enable_podman_socket` and its call at `:60`. If a Docker-compatible API
turns out to be needed by a compose backend, enable the **user** socket for the matrix
user in `lib/06_user.sh`, next to the lingering setup, and say so in the comment.

---

### DEP-008 - MEDIUM - `pacman -Sy` without `-u` sets up a partial upgrade

**Confidence: 4** (read the code path; the failure is a well-documented Arch behaviour, not something I can trigger here)

**Situation.** `lib/05_prerequisites.sh:241`:

```bash
pacman -Sy --noconfirm podman fuse-overlayfs slirp4netns
```

**Behaviour.** `-Sy` refreshes the package databases and then installs against the *new*
databases while leaving every already-installed package at its *old* version. Arch is a
rolling distribution with no partial-upgrade support: the newly fetched `podman` links
against whatever `glibc`, `libseccomp`, `gpgme` etc. are current in the refreshed
database, which may be newer than what is installed.

**Impact.** The documented outcome is unresolvable dependency errors, or a successful
install that fails at runtime with missing-symbol errors in shared libraries. On a host
being provisioned as a Matrix server this can leave the machine in a state where podman
is installed but non-functional, and the recovery (`pacman -Syu`) is not obvious to
someone who did not know the installer did this.

Supply-chain relevance: a partial upgrade means the *set of packages actually installed*
is not the set any Arch maintainer ever tested together, so no upstream integrity
assumption holds for the resulting system.

**Fix.** `pacman -Syu --noconfirm --needed podman fuse-overlayfs slirp4netns`, and warn
the user that a full system upgrade is about to happen - which is the honest cost of
installing anything on Arch. Note `:245` already uses `--needed` correctly.

---

### DEP-009 - MEDIUM - Broad image currency gap; several pins carry applicable advisories

**Confidence: 5** for versions and for advisories whose ranges are stated in release-version terms; **4** for the Prometheus entries that required Go-module version mapping (noted inline)

**Situation.** No automated dependency-update mechanism exists in the repo - no
Dependabot config, no Renovate config, no scheduled workflow. `pin-digests.sh` refreshes
the *digest for the tag you already have*; it never proposes a newer tag. Bumping is
entirely manual and entirely undocumented as to cadence.

**Behaviour.** Pinned versus upstream latest, checked 2026-09-10:

| Image | Pinned | Latest | Gap | Applicable advisories |
|---|---|---|---|---|
| synapse | v1.127.1 | v1.160.0 | 33 minor | see DEP-003 |
| element-web | v1.11.96 | v1.12.27 | 1 minor+ | see below |
| grafana | 11.5.2 | 13.2.1 | 2 major | [GHSA-3q27-7qjq-p9c5](https://github.com/advisories/GHSA-3q27-7qjq-p9c5) medium, range `>= 9.3.0, < 11.6.14` - **affected** |
| prometheus | v3.2.1 | v3.14.0 | 12 minor | [GHSA-vffh-x6r8-xx99](https://github.com/advisories/GHSA-vffh-x6r8-xx99) medium, range `>= 3.0.0, <= 3.5.1` - **affected** (stored XSS in web UI). Also likely [GHSA-8rm2-7qqf-34qm](https://github.com/advisories/GHSA-8rm2-7qqf-34qm) high and [GHSA-wg65-39gg-5wfj](https://github.com/advisories/GHSA-wg65-39gg-5wfj) high - see mapping note |
| dendrite | v0.14.1 | v0.15.2 | 1 minor | none applicable (all Dendrite advisories are `< 0.9.8`) |
| postgres | 16.14-alpine | 16.15 | 1 patch | none identified |
| coturn | 4.9.0-alpine | 4.18.0 | 9 minor | none in GHSA; upstream release cadence is high |
| cinny | v4.12.2 | v4.12.6 | 4 patch | none identified |
| caddy | 2.11.4-alpine | v2.11.4 | **current** | none - `<= 2.11.3` and `< 2.11.4` ranges both exclude it |
| bridge-telegram | v0.15.2 | v0.2608.0 | scheme change | none identified |
| bridge-whatsapp | v0.11.3 | v0.2608.0 | scheme change | none identified |
| bridge-signal | v0.7.4 | v0.2608.0 | scheme change | none identified |
| bridge-slack | v0.1.3 | v0.2608.0 | scheme change | none identified |
| bridge-discord | v0.7.2 | v0.7.7 | 5 patch | none identified |
| bridge-irc | 1.9.0 | v1.15.4 | 6 minor | none identified |

**element-web v1.11.96** pins `matrix-js-sdk: "37.2.0"` (exact, not a range - read from
`package.json` at tag `v1.11.96`). [GHSA-mp7c-m3rh-r56v](https://github.com/advisories/GHSA-mp7c-m3rh-r56v)
(medium, 2025-09-16) covers `matrix-js-sdk < 38.2.0`: **affected**. Insufficient
validation of room-upgrade predecessors.

**Prometheus mapping note.** Prometheus publishes Go-module tags (`v0.3xx.y`) alongside
release tags (`v3.x.y`), and GHSA records some advisories only in module terms.
`v3.2.1` maps to module `v0.302.1` on the observed `v0.30x` scheme (verified `v0.305.x`
through `v0.309.x` exist in the tag list). On that mapping, `< 0.305.2`
(GHSA-8rm2-7qqf-34qm, remote-read DoS) and `>= 0.45.2, < 0.311.3`
(GHSA-wg65-39gg-5wfj, Azure AD OAuth secret exposure via config API) both include the
pinned version. I did not confirm the mapping against an upstream statement, hence
confidence 4 on these two rows. GHSA-wg65-39gg-5wfj additionally requires Azure AD
remote-write to be configured, which this deployment does not do
(`lib/18_monitoring.sh` configures a local scrape only) - so it is inapplicable in
practice regardless.

**Impact.** Grafana and Prometheus are behind Caddy and not exposed by default, so their
XSS findings need an authenticated operator to be reachable; they are real but low-reach.
The Element Web and Synapse gaps are the ones that reach unauthenticated remote parties.
The bridges being 6-24 months behind matters less for CVEs than for protocol breakage:
WhatsApp and Signal bridges routinely stop working when their upstream protocols move,
and `v0.11.3`/`v0.7.4` predate several such moves.

**Fix.** Add Renovate or Dependabot. Neither natively understands `readonly X="ref@sha256:…"`
in a shell file, so either (a) move image refs to a `.env`-style file with
`# renovate: datasource=docker` annotations that Renovate's regex manager can read, or
(b) add a scheduled workflow that queries each registry for newer tags and opens an issue.
Option (b) is the smaller change and does not restructure the constants file. Either way
the bump itself must still run `pin-digests.sh`.

Prioritise: synapse -> element-web -> grafana/prometheus -> bridges.

---

### DEP-010 - LOW - PKGBUILD review displays untrusted content with `cat` and does not cover fetched sources

**Confidence: 4** (code path clear; the terminal-escape consequence depends on the user's terminal emulator)

**Situation.** `lib/05_prerequisites.sh:179-186`. The PKGBUILD display is the security
control that justifies the whole AUR path - the comment at `:179` says so: *"Show what we
are about to execute. This is the whole point of the exercise."*

**Behaviour.**

```bash
log_info "PKGBUILD for $helper (this is the code that will run on your machine):"
cat "$tmp_dir/$helper/PKGBUILD"
confirm_prompt "Proceed with building $helper from the PKGBUILD above?" "n" || {
```

Two limits:

1. `cat` writes attacker-controlled bytes straight to the terminal. A PKGBUILD
   containing ANSI escapes can scroll the real content out of view, overwrite already
   printed lines, or recolour text to hide a payload before the prompt is answered.
2. A PKGBUILD is a manifest, not the code. `yay`'s PKGBUILD names a `source=()` that
   `makepkg` downloads at `:190`, plus `prepare()`/`build()` hooks that run `go build`
   against a module graph. None of that is shown. Reviewing the PKGBUILD is necessary
   but does not establish what will execute.

**Impact.** The control is weaker than the comment claims. It defends against an
obviously malicious PKGBUILD read by an attentive user, which is real value, but a user
who reads it and approves has not seen the code that runs.

**Fix.** Use `cat -v` (or `less -R` is worse here; `cat -v` renders escapes inert and
visible). Adjust the prompt text to say what was and was not reviewed - "this manifest
also downloads and compiles sources not shown here" - so consent is informed. Preferring
`aura` over `yay` does not change this; both are AUR helpers.

---

### DEP-011 - LOW - The release workflow does not gate on tests or lint

**Confidence: 5** (both workflows read in full)

**Situation.** `.github/workflows/release.yml:5-7` triggers on `push: tags: ['v*']` and
proceeds directly to digest check, SBOM, signing, provenance, publish.

**Behaviour.** No `needs:` on the CI job, no `workflow_run` gate, no re-run of
`tests/test_runner.sh` or shellcheck. `ci.yml` triggers on `push: branches: [main]` and
`pull_request` only - a tag push does not trigger it.

**Impact.** A tag placed on a commit that never passed CI (a hotfix tagged directly, or a
tag pushed to a stale ref) produces a fully signed, SLSA-attested release. The signature
and provenance are then *true statements about an unvalidated artefact*: they attest
origin, which is what they claim, but users reasonably read a cosign-verified release as
having passed the project's own gate. Attesting untested code weakens the meaning of the
attestation.

**Fix.** Add a `test` job to `release.yml` running the same shellcheck and
`tests/test_runner.sh` steps, and make the `release` job `needs: test`. The suite runs in
seconds (300 tests, no containers), so the cost is negligible.

---

### DEP-012 - LOW - `cosign-installer` pinned to v3.9.1 (June 2025), two majors behind

**Confidence: 5** (SHA resolved to a tag via the GitHub API; installed cosign version read from the action's `action.yml` at that SHA; flag support confirmed in cosign's own docs at that version)

**Situation.** `.github/workflows/release.yml:33` pins
`sigstore/cosign-installer@398d4b0eeef1380460a10c8013a76f728fb906ac # v3`.

**Behaviour.** Verified via `gh api`:

- The SHA resolves to tag **v3.9.1**, committed 2025-06-23. The `# v3` comment is
  therefore accurate but imprecise - it reads as "latest v3" while pinning a specific,
  now-old v3 point release.
- That action's `action.yml` defaults `cosign-release: 'v2.5.2'`, and the workflow does
  not override it. So releases are signed by **cosign v2.5.2**.
- Latest installer is **v4.1.2** (2026-05-07).

I confirmed the workflow is *correct* at this version rather than assuming it:
`--new-bundle-format` exists on both `sign-blob` and `verify-blob` in cosign v2.5.2
(`doc/cosign_sign-blob.md` and `doc/cosign_verify-blob.md` at tag `v2.5.2`), and the
`--certificate-identity` / `--certificate-oidc-issuer` flags used in the
`SUPPLY_CHAIN.md:55-64` verification instructions are present. The documented user-facing
verification commands work as written.

**Impact.** No known vulnerability; signing is functionally correct. The cost is missing
14 months of Sigstore client fixes, and being on a client generation older than the
trust-root and bundle-format work in cosign v3/v4. Bundles produced now remain
verifiable, so this is maintenance debt rather than risk.

**Fix.** Bump to `sigstore/cosign-installer@<v4.1.2 SHA>` and re-verify that
`--new-bundle-format` output still validates with the commands in `SUPPLY_CHAIN.md`
before committing. Also worth pinning `cosign-release` explicitly rather than inheriting
the action's default, so the signing tool's version is visible in the workflow. Same
imprecision applies to `anchore/sbom-action/download-syft@… # v0`, which resolves to
**v0.24.0** (latest v0.24.2) - replace the `# v0` comment with `# v0.24.0`.

---

### DEP-013 - LOW - The digest drift gate turns a routine upstream event into a release failure

**Confidence: 5** (read `--check` logic at `scripts/pin-digests.sh:88-101`)

**Situation.** `release.yml:22-24` runs `pin-digests.sh --check` as the first release
step, and `SUPPLY_CHAIN.md:39-40` describes it as failing the release "if any pinned
digest no longer matches upstream".

**Behaviour.** `--check` resolves each tag *now* and compares to the recorded digest.
Alpine-based images (`postgres:16.14-alpine`, `caddy:2.11.4-alpine`,
`coturn:4.9.0-alpine`) are routinely rebuilt and re-pushed under the same tag when the
Alpine base gets a security update. When that happens - through no action by this project
- `--check` reports `DRIFT` and exits 1, blocking the release.

**Impact.** A security rebuild upstream blocks this project from cutting a release,
including a release intended to ship that very fix. The gate is correct in intent
(detecting an unexpected tag move is exactly what you want) but it cannot distinguish
"upstream re-pushed a patched base" from "someone moved a tag maliciously", and it fails
closed on both. The likely operator response under release pressure is to re-run
`pin-digests.sh` and accept the new digest without inspecting it, which quietly converts
the gate into a rubber stamp.

**Fix.** Keep the failure, but make the intended response explicit and safe: have
`--check` print the old and new digest and the command to inspect the difference
(`syft`/`diff` of the two SBOMs, which this repo can already generate), and document in
`SUPPLY_CHAIN.md` that accepting drift requires diffing the SBOMs, not just re-pinning.
Running `--check` nightly rather than only at release time (see DEP-006) also decouples
detection from release pressure.

---

### DEP-014 - LOW - UNVERIFIED: the claimed `ghcr.io/mautrix/<bridge>` mirrors could not be confirmed

**Confidence: 3** (probed the registry once; the response is ambiguous rather than negative)

**Situation.** `docs/SUPPLY_CHAIN.md:72-75` states: *"`ghcr.io/mautrix/<bridge>` mirrors
exist; do **not** swap registries without confirming digest equivalence."*

**Behaviour.** An anonymous manifest request for `ghcr.io/mautrix/telegram:v0.15.2`
(anonymous pull token, `Accept:` set to the OCI index and Docker manifest-list types)
returned **HTTP 403**, not 200 and not 404. GHCR returns 403 for both "package does not
exist" and "package exists but is not public", so this neither confirms nor refutes the
claim.

**Impact.** Low on its own. It matters because the sentence is offered as a fallback
option: an operator who loses access to `dock.mau.dev` (a single-operator registry, five
of the seventeen images) may follow this advice under pressure and find the fallback does
not exist, or is not anonymously pullable. The *"confirm digest equivalence"* caveat is
sound advice regardless.

**Fix.** Either verify the mirrors and record the exact registry path that works, or mark
the sentence as unconfirmed. If no anonymous mirror exists, that is worth stating
plainly, because it makes `dock.mau.dev` a single point of failure for the bridge
feature rather than a preference.

---

### DEP-015 - LOW - SBOM coverage stops at container images; the installer's own host-package surface is unrecorded

**Confidence: 5** (read `scripts/gen-sbom.sh` in full)

**Situation.** `scripts/gen-sbom.sh` iterates `*_IMAGE` constants and emits one
CycloneDX document per image via `syft registry:<ref>`.

**Behaviour.** What is *not* in any SBOM:

- The host packages the installer causes to be installed - `podman`, `podman-compose`,
  `slirp4netns`, `fuse-overlayfs`, `uidmap`, `curl`, `openssl`, `jq` - which are
  genuinely part of what this suite puts on the machine.
- `podman-compose==1.3.0` from PyPI.
- Anything from the AUR path.
- The repo itself. `setup.sh` is signed and attested but has no SBOM describing the
  `lib/*.sh`, `bridges/*.sh` and template files it carries.

Each image's SBOM is complete for that image's contents (syft's registry scan resolves
the pinned digest, so transitive OS and language packages with purl identifiers are
captured properly).

**Impact.** A consumer asking "what did this installer put on my machine?" gets an answer
covering the container contents and nothing about the host. For EU CRA purposes, an SBOM
is expected to cover the product as distributed; the product here is the installer, and
the installer's own composition is absent. CycloneDX 1.x output from syft is a suitable
format, so this is a scope gap, not a format gap.

**Fix.** Add a repo-level CycloneDX document listing `setup.sh`, the `lib/`, `bridges/`
and `templates/` files, the pinned `podman-compose==1.3.0`, and the host packages the
installer requests per distro family, then sign and attest it alongside the image SBOMs.
An `sbom/matrix-setup.cdx.json` assembled from `lib/00_constants.sh` and the package
lists in `lib/05_prerequisites.sh` covers it.

---

### DEP-016 - INFO - `ifconfig.me` is a third-party dependency in the install path

**Confidence: 5** (read `lib/02_detect.sh:150-160` and its failure handling)

**Situation.** `lib/02_detect.sh:153,156`:

```bash
ip=$(curl -4 -sf --connect-timeout 5 https://ifconfig.me 2>/dev/null || echo "")
```

**Behaviour.** HTTPS, 5-second timeout, failure yields an empty string rather than
aborting. The result is used for DNS guidance and display. Not an executable fetch.

**Impact.** Minimal, and correctly handled - listed for inventory completeness rather
than as a defect. Worth noting only that every install of this suite makes a request to a
third-party service that thereby learns the public IP of a new Matrix homeserver. That is
a privacy footnote for an operator who chose self-hosting partly to avoid third parties,
not a security finding.

**Fix.** None required. If desired, prefer a DNS-based lookup against the resolver
already in use (`dig +short myip.opendns.com @resolver1.opendns.com`) or make the source
configurable, and mention the lookup in the docs.

## Claimed vs actual posture (docs/SUPPLY_CHAIN.md)

Each assertion in the document, checked against the code.

| # | Claim | Location | Verdict |
|---|---|---|---|
| 1 | "All 17 images are pinned by immutable digest" | `:7-9` | **TRUE.** All 17 verified, `tag@sha256:<64hex>`, and the pinning survives to compose and Quadlet. |
| 2 | "A re-pushed tag cannot change what is deployed" | `:9` | **TRUE.** Podman resolves the digest, not the tag. |
| 3 | "No `curl \| bash` / `wget \| sh` patterns anywhere" | `:10` | **TRUE**, literally. But see #4 - the sentence implies a stronger property than holds. |
| 4 | "The only network-fetched package is `podman-compose` (pip fallback), which is version-pinned and guarded by pip3/Python presence checks" | `:11-12` | **FALSE, two ways.** (a) Two Arch call sites install it unpinned and unguarded - **DEP-001**. (b) The AUR path fetches and compiles unvetted third-party code and root-installs it - **DEP-002**. Distro packages via apt/dnf/pacman/zypper are also network-fetched, though GPG-verified by the package manager. |
| 5 | "Licence: MIT, consistent with the README" | `:13` | **TRUE.** |
| 6 | Tooling table: "Verify digests vs upstream (drift gate) - release CI" | `:20` | **TRUE** as stated (release CI only). |
| 7 | "CI/`--check` will fail a release if a pinned digest ever drifts" | `:33` | **MISLEADING.** True at release; the "CI/" prefix implies `ci.yml`, which does not run it. The documented bump procedure's step 2 is unenforced on PRs - **DEP-006**. |
| 8 | "no container runtime or daemon is required, and all images are public so no credentials are needed" | `:25-27` | **TRUE.** `pin-digests.sh` uses the registry HTTP API; `gen-sbom.sh` uses `syft registry:`. Anonymous token flow is implemented at `pin-digests.sh:45-59`. |
| 9 | Release pipeline steps 1-5 | `:37-47` | **TRUE.** Each step matches `release.yml:23-64`, in the stated order. |
| 10 | "keyless cosign … emitting one self-contained `*.cosign.bundle` per artifact (certificate + signature + Rekor entry in a single file)" | `:43-45` | **TRUE, verified against upstream.** `--new-bundle-format` is documented in cosign v2.5.2 (the version the pinned installer provides) as "output bundle in new format that contains all verification material". Source: `sigstore/cosign` `doc/cosign_sign-blob.md` @ `v2.5.2`. |
| 11 | User verification commands | `:55-64` | **TRUE.** Flags all exist in cosign v2.5.2 `verify-blob`. The `--certificate-identity` URL matches `git remote` (`github.com/obelisk-complex/Matrix_Setup`) and the workflow file and tag-push trigger. `gh release create` flattens `sbom/` paths to basenames, so the documented filenames are right. |
| 12 | "SLSA build provenance can additionally be verified with `cosign verify-blob-attestation`" | `:67-68` | **UNVERIFIED.** Not checked against upstream docs; the bundle referenced comes from the GitHub attestations API rather than a release asset, and I did not confirm the exact invocation. Plausible but not established here. |
| 13 | "`dock.mau.dev` (the canonical mautrix registry, run by the mautrix maintainer)" | `:72-73` | **TRUE** to the extent checkable - it is the registry referenced by mautrix's own documentation. Single-operator registry remains a concentration risk for 5 of 17 images. |
| 14 | "`ghcr.io/mautrix/<bridge>` mirrors exist" | `:74` | **UNVERIFIED** - anonymous probe returned HTTP 403 (ambiguous). **DEP-014**. |
| 15 | "**GitHub Actions are SHA-pinned** (with `# vX` comments) in both workflows" | `:83-84` | **TRUE.** All five `uses:` verified: `actions/checkout@df4cb1c0` = v6.0.3, `anchore/sbom-action@e22c3899` = v0.24.0, `sigstore/cosign-installer@398d4b0e` = v3.9.1, `actions/attest-build-provenance@a2bbfa25` = v4.1.0. Every SHA resolves to a real tag. Two comments are imprecise (`# v0`, `# v3` name majors, not the pinned point release) - **DEP-012**. |
| 16 | synapse-admin -> ketesa rename tracking note | `:79-82` | **TRUE and current.** Still accurate as of this audit. |

**What the document does not claim but should.** It does not mention: that no image
signature is verified at pull time (**DEP-005**); that the digests were obtained from a
server-asserted header rather than computed (**DEP-004**); that there is no
dependency-update mechanism and several pins carry live advisories (**DEP-003**,
**DEP-009**); or that releases are signed without a test gate (**DEP-011**).

## Verified OK

- All 17 `*_IMAGE` constants match `^[a-z0-9./-]+:[^@]+@sha256:[0-9a-f]{64}$`. No `latest`,
  no floating tag, no unpinned ref.
- No literal image reference anywhere in `templates/compose/*.yml` - all nine are
  `{{VAR}}` placeholders fed from `lib/19_compose.sh:119-151`.
- All six `bridges/*.sh` `bridge_image()` functions echo a constant, not a literal.
- `lib/20_quadlet.sh:115` interpolates `${COTURN_IMAGE}`; no hardcoded ref.
- No `curl | bash`, `wget | sh`, `curl … | sudo`, or equivalent anywhere in the repo.
- No plain-HTTP fetch of executable content. All `http://` occurrences are localhost or
  container-network endpoints (health checks, proxy backends, Synapse admin API).
- Every GitHub Actions `uses:` in both workflows is a 40-hex commit SHA, and all five
  resolve to real upstream tags (verified via the GitHub API).
- `release.yml:20` sets `persist-credentials: false`.
- `release.yml` permissions are minimal for the work done: `contents: write`,
  `id-token: write`, `attestations: write`. `ci.yml` is `contents: read`.
- `pin-digests.sh:53` refuses a non-HTTPS token realm.
- `pin-digests.sh:67` validates digest shape before use.
- `pin-digests.sh:117-134` writes via temp-file-plus-`mv` in the same directory, with
  `chmod --reference`, so a crash cannot truncate the constants file.
- `pin-digests.sh` fails closed on unresolvable images (`:103-109`, exit 1, no changes
  written).
- `_aur_build_user` (`lib/05_prerequisites.sh:71-81`) fails closed when `SUDO_USER` is
  unset or root.
- `_install_aur_helper` uses `mktemp -d`, not a predictable path, with a `RETURN` trap
  cleanup, and rejects any helper other than `yay`/`aura` (`:151-158`).
- `_aur_consent` refuses by default in `HEADLESS` (`:99-108`).
- `_pip_install_compose` (`:311-319`) pins `podman-compose==1.3.0` and guards on pip3 and
  Python >= 3.8 - correct, just not called from the Arch branches.
- Compose-install failures are swallowed with `|| true`, but `_check_compose` re-detects
  and exits `E_PREREQ` if no compose tool is present - the swallow does not hide a
  missing dependency.
- `sbom/` is gitignored, consistent with the doc's "not committed" claim.
- Test suite: **300 passed, 0 failed, 0 skipped** (`bash tests/test_runner.sh`, run
  locally).
- Licence MIT, no copyleft or UNLICENSED dependency in the tree. All 17 images are
  separately-distributed artefacts, not linked code, so no licence propagation applies.
- Namespace legitimacy re-confirmed for `matrixdotorg`, `element-hq`, `cinnyapp`,
  `etkecc`, `hif1` (Docker Hub handle of `github.com/hifi/heisenbridge`), `mautrix`.

## Completion

**Status: COMPLETE**

**Tally:** 16 findings - 0 critical, 3 high, 6 medium, 6 low, 1 info.

| Severity | IDs |
|---|---|
| HIGH | DEP-001 (unpinned pip on Arch), DEP-002 (SUPPLY_CHAIN.md omits AUR), DEP-003 (Synapse advisories) |
| MEDIUM | DEP-004 (digest from header), DEP-005 (no signature verification), DEP-006 (`--check` not in CI), DEP-007 (root podman.socket), DEP-008 (`pacman -Sy`), DEP-009 (image currency) |
| LOW | DEP-010 (PKGBUILD display), DEP-011 (no test gate on release), DEP-012 (old cosign-installer), DEP-013 (drift gate brittleness), DEP-014 (UNVERIFIED ghcr mirrors), DEP-015 (SBOM scope) |
| INFO | DEP-016 (ifconfig.me) |

**The headline.** The mechanical controls are in good shape - digest pinning is complete
and survives to runtime, actions are genuinely SHA-pinned, signing and provenance work as
documented. The two things that need attention are that `docs/SUPPLY_CHAIN.md` describes
a narrower attack surface than the code has (DEP-001, DEP-002), and that pinning without
an update mechanism has aged several images into published advisories (DEP-003, DEP-009).

**Could not check, and why:**

- Whether `ghcr.io/mautrix/<bridge>` mirrors exist - GHCR returned an ambiguous 403
  (DEP-014).
- Whether the `cosign verify-blob-attestation` invocation in `SUPPLY_CHAIN.md:67-68` is
  correct - not verified against upstream documentation (claims table row 12).
- The Prometheus Go-module-to-release version mapping used for two advisory rows in
  DEP-009 is inferred from the tag list, not from an upstream statement (confidence 4).
- No image was pulled, no container launched, no package installed, and nothing was run
  against the live session, per the brief. Findings are from source reading, the GitHub
  API, public registry metadata, upstream documentation, and `tests/test_runner.sh`.
- Contents of the AUR `yay`/`aura` PKGBUILDs were not fetched or reviewed; DEP-010
  concerns the review mechanism, not any specific PKGBUILD.
