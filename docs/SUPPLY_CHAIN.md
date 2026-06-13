# Supply-chain hardening

How container images and release artifacts are pinned, verified and attested.

## Current posture

- **All 17 images are pinned by immutable digest** (`registry/repo:tag@sha256:…`)
  in `lib/00_constants.sh`. The tag is kept for readability; the digest is the
  source of truth. A re-pushed tag cannot change what is deployed.
- No `curl | bash` / `wget | sh` patterns anywhere.
- The only network-fetched package is `podman-compose` (pip fallback), which is
  version-pinned and guarded by pip3/Python presence checks.
- Licence: MIT (`LICENSE`), consistent with the README.

## Tooling

| Task | Tool | When |
|------|------|------|
| Resolve / pin digests | `scripts/pin-digests.sh` | after any version bump |
| Verify digests vs upstream (drift gate) | `scripts/pin-digests.sh --check` | release CI |
| Generate CycloneDX SBOMs | `scripts/gen-sbom.sh` (syft, registry scan) | release CI |
| Lint + tests | `.github/workflows/ci.yml` | every push / PR |
| Sign + attest + publish | `.github/workflows/release.yml` | on `v*` tag |

`pin-digests.sh` and `gen-sbom.sh` use the registry HTTP API / `syft registry:`
directly — **no container runtime or daemon** is required, and all images are
public so no credentials are needed.

### Bumping an image

1. Edit the tag in `lib/00_constants.sh`.
2. Run `scripts/pin-digests.sh` to refresh the `@sha256` digest.
3. Commit. CI/`--check` will fail a release if a pinned digest ever drifts.

## Release pipeline (`.github/workflows/release.yml`)

On a `v*` tag, GitHub Actions:

1. Runs `pin-digests.sh --check` — fails the release if any pinned digest no
   longer matches upstream.
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
- **GitHub Actions are SHA-pinned** (with `# vX` comments) in both workflows;
  refresh the SHAs when intentionally upgrading an action.
