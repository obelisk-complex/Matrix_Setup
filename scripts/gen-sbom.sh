#!/usr/bin/env bash
# Generate a CycloneDX SBOM for every pinned image into sbom/.
#
# Requires syft (https://github.com/anchore/syft). syft scans the REGISTRY image
# directly (`registry:` source) — no container runtime or daemon is needed, and
# public images need no credentials. Intended to run at release time (CI); the
# SBOMs are release artifacts and are not committed (see .gitignore).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONSTANTS="$REPO_ROOT/lib/00_constants.sh"
OUT="$REPO_ROOT/sbom"

if ! command -v syft >/dev/null 2>&1; then
    echo "syft not found. Install it first:" >&2
    echo "  https://github.com/anchore/syft#installation" >&2
    echo "  (or in CI: anchore/sbom-action/download-syft@v0)" >&2
    exit 1
fi

mkdir -p "$OUT"
count=0
while IFS= read -r line; do
    [[ "$line" =~ ^readonly[[:space:]]+([A-Z_]+_IMAGE)=\"([^\"]+)\" ]] || continue
    name="${BASH_REMATCH[1]}"
    ref="${BASH_REMATCH[2]}"
    out="$OUT/${name}.cdx.json"
    echo "SBOM: $ref"
    syft "registry:$ref" -o "cyclonedx-json=$out" -q
    count=$((count + 1))
done < "$CONSTANTS"
echo "Wrote $count CycloneDX SBOM(s) to $OUT/"
