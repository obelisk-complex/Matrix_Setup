#!/usr/bin/env bash
# Tests for the version floors in lib/00_constants.sh that are coupled to the
# pinned homeserver image.
#
# Synapse v1.143.0 dropped PostgreSQL 13
# (https://github.com/element-hq/synapse/blob/v1.160.0/docs/upgrade.md#dropping-support-for-postgresql-13),
# so MIN_PG_VERSION and SYNAPSE_IMAGE cannot be bumped independently: a Synapse
# bump past 1.143 with MIN_PG_VERSION still at 13 lets _postgres_auto_detect
# hand Synapse a host PostgreSQL it will refuse to start against, and the
# failure surfaces as a container that will not come up rather than as a
# prerequisite error. Nothing else in the repo ties the two together.
# Runs entirely offline: the constants file is read as text, never a registry.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"

setup_test_tmp
trap teardown_test_tmp EXIT

CONSTANTS="$PROJECT_DIR/lib/00_constants.sh"

# Read one `readonly NAME="value"` out of a constants file without sourcing it
# (sourcing the real file marks the names readonly for the rest of this shell,
# which the synthetic-fixture cases below then could not shadow).
_const() {
    sed -n "s/^readonly $2=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$1" | head -1
}

# Minor version from a Synapse image tag: v1.160.0 -> 160. Empty if the tag is
# not a vX.Y.Z, so an unexpected tag shape fails loudly below rather than
# silently skipping the floor check.
_synapse_minor() {
    local ref="${1%%@*}" tag
    tag="${ref##*:}"
    [[ "$tag" =~ ^v1\.([0-9]+)\. ]] && printf '%s' "${BASH_REMATCH[1]}"
}

_pg_major_from_image() {
    local ref="${1%%@*}" tag
    tag="${ref##*:}"
    printf '%s' "${tag%%[!0-9]*}"
}

# Print one line per violated floor; silence means the combination is coherent.
_floor_violations() {
    local file="$1" synapse pg_floor pg_image minor pg_major
    synapse=$(_const "$file" SYNAPSE_IMAGE)
    pg_floor=$(_const "$file" MIN_PG_VERSION)
    pg_image=$(_const "$file" POSTGRES_IMAGE)
    minor=$(_synapse_minor "$synapse")
    pg_major=$(_pg_major_from_image "$pg_image")

    [[ -n "$minor" ]] || { echo "SYNAPSE_IMAGE tag is not a v1.Y.Z release: $synapse"; return; }
    [[ -n "$pg_floor" ]] || { echo "MIN_PG_VERSION is unset"; return; }
    [[ -n "$pg_major" ]] || { echo "POSTGRES_IMAGE tag carries no major version: $pg_image"; return; }

    if (( minor >= 143 )) && (( pg_floor < 14 )); then
        echo "Synapse 1.$minor requires PostgreSQL 14+ but MIN_PG_VERSION is $pg_floor"
    fi
    if (( pg_major < pg_floor )); then
        echo "POSTGRES_IMAGE is major $pg_major, below MIN_PG_VERSION $pg_floor"
    fi
}

_fixture() {
    local path="$TEST_TMP/$1.sh"
    printf '%s\n' "$2" > "$path"
    printf '%s' "$path"
}

# --- Test: the shipped constants are coherent ---
assert_eq "" "$(_floor_violations "$CONSTANTS")" \
    "shipped SYNAPSE_IMAGE, MIN_PG_VERSION and POSTGRES_IMAGE agree"

# --- Test: the floor the bump actually moved is asserted, not assumed ---
assert_eq "14" "$(_const "$CONSTANTS" MIN_PG_VERSION)" \
    "MIN_PG_VERSION is 14 (Synapse v1.143.0 dropped PostgreSQL 13)"

# --- Negative control: Synapse past 1.143 with the old PostgreSQL 13 floor ---
# This is the exact state a future Synapse bump would leave behind, and the
# state the gate exists to catch.
stale=$(_fixture stale 'readonly MIN_PG_VERSION="13"
readonly SYNAPSE_IMAGE="docker.io/matrixdotorg/synapse:v1.160.0@sha256:aa"
readonly POSTGRES_IMAGE="docker.io/postgres:16.14-alpine@sha256:bb"')
assert_match "requires PostgreSQL 14\+ but MIN_PG_VERSION is 13" "$(_floor_violations "$stale")" \
    "a Synapse 1.160 pin against a PostgreSQL 13 floor is reported"

# --- Negative control: the shipped PostgreSQL image below its own floor ---
below=$(_fixture below 'readonly MIN_PG_VERSION="14"
readonly SYNAPSE_IMAGE="docker.io/matrixdotorg/synapse:v1.160.0@sha256:aa"
readonly POSTGRES_IMAGE="docker.io/postgres:13.20-alpine@sha256:bb"')
assert_match "below MIN_PG_VERSION 14" "$(_floor_violations "$below")" \
    "a POSTGRES_IMAGE older than the floor it is meant to satisfy is reported"

# --- Control: a pre-1.143 Synapse may legitimately keep the 13 floor ---
old=$(_fixture old 'readonly MIN_PG_VERSION="13"
readonly SYNAPSE_IMAGE="docker.io/matrixdotorg/synapse:v1.127.1@sha256:aa"
readonly POSTGRES_IMAGE="docker.io/postgres:16.14-alpine@sha256:bb"')
assert_eq "" "$(_floor_violations "$old")" \
    "the floor is tied to the pinned Synapse version, not applied unconditionally"

# --- Negative control: an unparseable tag is a failure, not a silent pass ---
opaque=$(_fixture opaque 'readonly MIN_PG_VERSION="13"
readonly SYNAPSE_IMAGE="docker.io/matrixdotorg/synapse:latest"
readonly POSTGRES_IMAGE="docker.io/postgres:16.14-alpine@sha256:bb"')
assert_match "not a v1.Y.Z release" "$(_floor_violations "$opaque")" \
    "a Synapse tag the floor check cannot read is reported rather than skipped"

test_report
