#!/usr/bin/env bash
# Resolve and pin every *_IMAGE in lib/00_constants.sh to
# "registry/repo:tag@sha256:<digest>" using the OCI / Docker Registry v2 API.
#
# Uses curl + python3 only — no container runtime, no daemon. All target images
# are public, so no credentials are required. Re-run after every version bump.
#
# Usage:
#   scripts/pin-digests.sh           # resolve and rewrite lib/00_constants.sh
#   scripts/pin-digests.sh --check   # verify pinned digests still match upstream
#                                     # (exit 1 on drift) — for CI
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONSTANTS="$REPO_ROOT/lib/00_constants.sh"
MODE="${1:-apply}"
case "$MODE" in
    apply|--check) ;;
    *) echo "Usage: $(basename "$0") [--check]" >&2; exit 2 ;;
esac

ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json'

# Extract a quoted parameter (realm/service) from a WWW-Authenticate header.
_wwwauth_param() { sed -n "s/.*$1=\"\([^\"]*\)\".*/\1/p" <<<"$2"; }

# resolve_digest "registry/repo:tag" -> prints "sha256:..."
resolve_digest() {
    local ref="${1%@*}"                 # drop any existing @sha256:...
    local nametag="$ref" tag name registry repo api
    tag="${nametag##*:}"
    name="${nametag%:*}"
    registry="${name%%/*}"
    repo="${name#*/}"

    if [[ "$registry" == "docker.io" ]]; then
        api="registry-1.docker.io"
        [[ "$repo" == */* ]] || repo="library/$repo"   # official images
    else
        api="$registry"
    fi

    local murl="https://$api/v2/$repo/manifests/$tag"

    # Probe for an auth challenge.
    local www token=""
    www=$(curl -sI -H "Accept: $ACCEPT" "$murl" | grep -i '^www-authenticate:' || true)
    if [[ -n "$www" ]]; then
        local realm service
        realm=$(_wwwauth_param realm "$www")
        service=$(_wwwauth_param service "$www")
        # Only follow an HTTPS token realm (a compromised/MITM registry could
        # otherwise redirect the token fetch to an arbitrary endpoint).
        [[ "$realm" == https://* ]] || { echo "refusing non-https token realm: $realm" >&2; return 1; }
        token=$(curl -s "${realm}?service=${service}&scope=repository:${repo}:pull" \
            | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("token") or d.get("access_token") or "")' 2>/dev/null || true)
    fi

    local auth=()
    [[ -n "$token" ]] && auth=(-H "Authorization: Bearer $token")

    local digest
    digest=$(curl -sI "${auth[@]}" -H "Accept: $ACCEPT" "$murl" \
        | grep -i '^docker-content-digest:' | head -1 | awk '{print $2}' | tr -d '\r')
    # Must be a well-formed sha256 digest — guards against duplicate headers or
    # an unexpected body corrupting the rewritten constants file.
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}

# Build NAME -> current ref map from the constants file.
declare -A CURRENT=()
while IFS= read -r line; do
    if [[ "$line" =~ ^readonly[[:space:]]+([A-Z_]+_IMAGE)=\"([^\"]+)\" ]]; then
        CURRENT["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
done < "$CONSTANTS"

declare -A RESOLVED=()
declare -a FAILED=()
drift=0
printf '%-26s %s\n' "IMAGE VAR" "DIGEST"
printf '%-26s %s\n' "---------" "------"
for name in $(printf '%s\n' "${!CURRENT[@]}" | sort); do
    ref="${CURRENT[$name]}"
    base="${ref%@*}"
    if ! digest=$(resolve_digest "$ref"); then
        FAILED+=("$name ($ref)")
        printf '%-26s %s\n' "$name" "UNRESOLVED"
        continue
    fi
    RESOLVED["$name"]="${base}@${digest}"
    printf '%-26s %s\n' "$name" "$digest"

    if [[ "$MODE" == "--check" ]]; then
        have="${ref##*@}"
        if [[ "$ref" != *@* ]]; then
            echo "  DRIFT: $name is not digest-pinned" >&2; drift=1
        elif [[ "$have" != "$digest" ]]; then
            echo "  DRIFT: $name pinned $have but upstream is $digest" >&2; drift=1
        fi
    fi
done

if (( ${#FAILED[@]} > 0 )); then
    echo "" >&2
    echo "ERROR: could not resolve ${#FAILED[@]} image(s) (tag missing/renamed upstream):" >&2
    printf '  - %s\n' "${FAILED[@]}" >&2
    echo "Fix the tag in lib/00_constants.sh and re-run. No changes written." >&2
    exit 1
fi

if [[ "$MODE" == "--check" ]]; then
    (( drift == 0 )) && echo "OK: all image digests match upstream." || exit 1
    exit 0
fi

# Rewrite constants without sed (image refs contain '/' and ':'); pass values
# through verbatim via a read loop. Write to a temp file in the SAME directory
# then atomically mv into place, so a crash mid-write cannot truncate the
# original constants file.
tmp="$(mktemp "$(dirname "$CONSTANTS")/.constants.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
while IFS= read -r line; do
    if [[ "$line" =~ ^readonly[[:space:]]+([A-Z_]+_IMAGE)=\" ]]; then
        n="${BASH_REMATCH[1]}"
        if [[ -n "${RESOLVED[$n]:-}" ]]; then
            printf 'readonly %s="%s"\n' "$n" "${RESOLVED[$n]}"
            continue
        fi
    fi
    printf '%s\n' "$line"
done < "$CONSTANTS" > "$tmp"
chmod --reference="$CONSTANTS" "$tmp" 2>/dev/null || true
mv "$tmp" "$CONSTANTS"
echo "Pinned ${#RESOLVED[@]} images in $CONSTANTS"
