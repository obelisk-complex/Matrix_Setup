# Supply-chain hardening

How container images and release artifacts are pinned, verified and attested.

## Current posture

- **All 17 images are pinned by immutable digest** (`registry/repo:tag@sha256:…`)
  in `lib/00_constants.sh`. The tag is kept for readability; the digest is the
  source of truth. A re-pushed tag cannot change what is deployed.
- No `curl | bash` / `wget | sh` patterns anywhere.
- Two code paths fetch and execute software from outside the distribution's own
  repositories:
  - `podman-compose` via pip (`_pip_install_compose`, `lib/05_prerequisites.sh`),
    pinned to `PODMAN_COMPOSE_VERSION` and installed into its own virtualenv.
  - On Arch, an AUR helper bootstrap (`_install_aur_helper`): a shallow
    `git clone` of `https://aur.archlinux.org/yay.git`, `makepkg` as an
    unprivileged user, then `pacman -U --noconfirm` on the result. This is
    **not pinned**: it builds whatever is at the AUR package's HEAD, and a
    PKGBUILD is arbitrary shell executed at build time. Pinning it would mean
    pinning an AUR commit, which the AUR does not make discoverable.
    Compensating controls: it is reached only on Arch and only when the official
    repositories have no `podman-compose`; `_aur_consent` gates it behind an
    explicit prompt defaulting to *no*, and refuses outright in `HEADLESS` mode
    unless `MATRIX_ALLOW_AUR=true`; declining falls through to the pinned pip
    path. Arch is nonetheless the least-hardened platform here.
- Licence: MIT (`LICENSE`), consistent with the README. The images deployed
  carry their own licences. Synapse is copyleft: the `v1.127.1` image declared
  `AGPL-3.0-or-later`, and `v1.160.0` declares
  `AGPL-3.0-or-later OR LicenseRef-Element-Commercial`, a widening rather than a
  new obligation. Deploying an unmodified image is not derivation, so this does not
  reach the installer's own licence.

## Tooling

| Task | Tool | When |
|------|------|------|
| Resolve / pin digests | `bash scripts/pin-digests.sh` | after any version bump |
| Verify digests vs upstream (drift gate) | `bash scripts/pin-digests.sh --check` | push to `main`, weekly, and before every release |
| Generate CycloneDX SBOMs | `bash scripts/gen-sbom.sh` (syft, registry scan) | release CI |
| Lint + tests | `.github/workflows/ci.yml` | every push / PR, and before every release |
| Sign + attest + publish | `.github/workflows/release.yml` | on `v*` tag |
| Propose newer versions | Renovate (`renovate.json`) | weekly, as PRs |

The drift gate does not run on pull requests: the pins are tag+digest against
floating tags, so an upstream retag would turn unrelated PRs red. A PR that adds
an unpinned `*_IMAGE` is therefore only caught once it reaches `main`.

`pin-digests.sh` and `gen-sbom.sh` use the registry HTTP API / `syft registry:`
directly — **no container runtime or daemon** is required, and all images are
public so no credentials are needed.

### Bumping an image

1. Edit the tag in `lib/00_constants.sh`.
2. Run `bash scripts/pin-digests.sh` to refresh the `@sha256` digest.
3. Commit. `--check` runs on `main`, weekly, and as part of the release's
   `verify` job, so drift fails CI as well as the release.

For Synapse, read
[`docs/upgrade.md`](https://github.com/element-hq/synapse/blob/develop/docs/upgrade.md)
between the old and new version first. Breaking changes live there, not in the
release title, and they have already included a PostgreSQL floor change
(v1.143.0 dropped PostgreSQL 13). `tests/test_version_floors.sh` asserts that
`MIN_PG_VERSION` and `POSTGRES_IMAGE` stay coherent with the pinned Synapse, and
`tests/test_templates.sh` re-renders `homeserver.yaml` for every registration
policy. Neither can tell you that a key changed meaning, though, so the upgrade
notes are still a manual read.

## Automated dependency updates

`renovate.json` configures [Renovate](https://docs.renovatebot.com/) to open PRs
for newer versions. It is **not** self-executing: it takes effect only once the
Renovate GitHub App is installed on the repository, or a self-hosted Renovate
runs against it. Until then the file is inert.

What it covers, and what it does not:

| Dependency | Covered | How |
|---|---|---|
| GitHub Actions in `.github/workflows/` | yes | native `github-actions` manager, `pinDigests` keeps the SHA-with-comment form |
| The 17 `*_IMAGE` pins in `lib/00_constants.sh` | yes | a `customManagers` regex. This is why the repo uses Renovate rather than Dependabot: Dependabot has no mechanism for reading dependencies out of a shell script, and these pins are the dependencies that matter most |
| `PODMAN_COMPOSE_VERSION` (pip) | no | not a manifest Renovate recognises, and the regex manager is deliberately scoped to image pins; check it by hand |
| The AUR helper bootstrap | no | unpinned by construction (see **Current posture**) |

Renovate proposes *versions*; `scripts/pin-digests.sh --check` verifies
*digests*. They are not substitutes. `--check` re-resolves the digest for the tag
already pinned and can never suggest a newer tag, which is how `SYNAPSE_IMAGE`
sat 45 releases behind upstream, carrying GHSA-8q93-326v-3m7g (high),
GHSA-6qf2-7x63-mm6v and GHSA-fh66-fcv5-jjfr, while the drift gate stayed green.

Two gaps to be aware of:

- The `image-pins` job does not run on pull requests, so a Renovate PR that
  bumps a tag and digest is not digest-verified until it lands on `main`.
- Renovate's `docker` versioning will rank vendor-suffixed tags
  (`1.11.36-sc.3`, `v0.11.4-etke54`) on a best-effort basis; if it proposes
  something odd for SchildiChat or synapse-admin, add a per-package `versioning`
  rule rather than disabling the manager.

Validate changes to the config with
`renovate-config-validator --strict` before committing.

## Release pipeline (`.github/workflows/release.yml`)

On a `v*` tag, GitHub Actions:

1. Runs the whole of `ci.yml` as a `verify` job that everything else `needs:`
   — shellcheck, the full test suite, and `pin-digests.sh --check`. A tag is
   not a branch, so `ci.yml`'s own `push` trigger never fires for `v*`; without
   this the release would sign and attest a commit that had never been linted or
   tested. **A cosign bundle attests provenance, not quality** — it says which
   workflow produced the file, not that the file passed anything.
2. Generates a CycloneDX SBOM per image with `syft` (uploaded as release assets,
   not committed — see `.gitignore`).
3. Signs `setup.sh` and **every SBOM** with **keyless cosign** (Sigstore, via the
   workflow's OIDC `id-token`), emitting one self-contained `*.cosign.bundle`
   per artifact (certificate + signature + Rekor entry in a single file).
4. Attaches **SLSA build provenance** via `actions/attest-build-provenance`.
5. Publishes the release with each artifact **and** its `.cosign.bundle`.

### Verifying a release (for users)

Each artifact ships with a `<name>.cosign.bundle`. Verify the installer (and any
SBOM) like so, pinning the expected tag in the identity:

```bash
cosign verify-blob setup.sh \
  --bundle setup.sh.cosign.bundle --new-bundle-format \
  --certificate-identity "https://github.com/obelisk-complex/Matrix_Setup/.github/workflows/release.yml@refs/tags/v0.1.1" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# An SBOM (same bundle pattern):
cosign verify-blob POSTGRES_IMAGE.cdx.json \
  --bundle POSTGRES_IMAGE.cdx.json.cosign.bundle --new-bundle-format \
  --certificate-identity "https://github.com/obelisk-complex/Matrix_Setup/.github/workflows/release.yml@refs/tags/v0.1.1" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

SLSA build provenance can additionally be verified with
`cosign verify-blob-attestation <file> --type slsaprovenance1 --bundle <bundle-from-attestations-API>`.

## Registry trust note

Bridge images come from `dock.mau.dev` (the canonical mautrix registry, run by
the mautrix maintainer). Digest pinning makes the exact content immutable
regardless of registry. `ghcr.io/mautrix/<bridge>` mirrors exist; do **not** swap
registries without confirming digest equivalence.

## Tracking

- **synapse-admin → ketesa rename.** `etkecc/synapse-admin` is being rebranded to
  `ketesa`; the canonical image will move to `ghcr.io/etkecc/ketesa`. The current
  `synapse-admin` tag is still published and digest-pinned (no immediate risk).
  Migrate `SYNAPSE_ADMIN_IMAGE` once a stable `ketesa` release is available.
- **GitHub Actions are SHA-pinned** (with `# vX` comments) in both workflows.
  Renovate refreshes both the SHA and the comment once it is installed; until
  then this is manual.
- **Synapse schema version.** v1.160.0 is at `SCHEMA_VERSION = 94` against
  v1.127.1's 89, so upgrading runs migrations and background updates on first
  start. `SCHEMA_COMPAT_VERSION` is unchanged at 84 in both, so rolling the
  image back to the previous pin still works against a migrated database. That
  holds for this bump only; check it again on the next one.
