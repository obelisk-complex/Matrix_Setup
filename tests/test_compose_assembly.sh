#!/usr/bin/env bash
# Tests for compose fragment templates (structure and content validation)
# CONFIG is `declare -A` in lib/00_constants.sh, which ShellCheck does not follow
# from here, so it reads CONFIG[monitoring.enabled] as an indexed subscript and
# warns that `monitoring` is unassigned. BRIDGES_ENABLED, CONFIG and COMPOSE_CMD
# are consumed inside run_assemble via the sourced lib functions, not in this file.
# shellcheck disable=SC2154,SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"

setup_test_tmp

TEMPLATES_DIR="$PROJECT_DIR/templates/compose"

# --- Test: all compose templates exist ---
expected_templates=("base.yml" "postgres.yml" "synapse.yml" "dendrite.yml" "caddy.yml" "coturn.yml" "webclient.yml" "admin.yml" "monitoring.yml")

for tpl in "${expected_templates[@]}"; do
    assert_file_exists "$TEMPLATES_DIR/$tpl" "compose template: $tpl"
done

# --- Test: base.yml carries the shared network and volumes ---
assert_file_contains "$TEMPLATES_DIR/base.yml" "matrix-net:" "base.yml defines matrix-net"
assert_file_contains "$TEMPLATES_DIR/base.yml" "postgres-data:" "base.yml defines postgres-data volume"
assert_file_contains "$TEMPLATES_DIR/base.yml" "caddy-data:" "base.yml defines caddy-data volume"

# --- Test: postgres.yml has healthcheck ---
assert_file_contains "$TEMPLATES_DIR/postgres.yml" "healthcheck:" "postgres has healthcheck"
assert_file_contains "$TEMPLATES_DIR/postgres.yml" "pg_isready" "postgres healthcheck uses pg_isready"

# --- Test: synapse.yml has required config ---
assert_file_contains "$TEMPLATES_DIR/synapse.yml" "homeserver.yaml" "synapse mounts homeserver.yaml"
assert_file_contains "$TEMPLATES_DIR/synapse.yml" "depends_on:" "synapse depends on postgres"
assert_file_contains "$TEMPLATES_DIR/synapse.yml" "healthcheck:" "synapse has healthcheck"

# --- Test: dendrite.yml has required config ---
assert_file_contains "$TEMPLATES_DIR/dendrite.yml" "dendrite.yaml" "dendrite mounts dendrite.yaml"
assert_file_contains "$TEMPLATES_DIR/dendrite.yml" "depends_on:" "dendrite depends on postgres"

# --- Test: caddy.yml has port mappings ---
assert_file_contains "$TEMPLATES_DIR/caddy.yml" "ports:" "caddy has ports"
assert_file_contains "$TEMPLATES_DIR/caddy.yml" "Caddyfile" "caddy mounts Caddyfile"
assert_file_contains "$TEMPLATES_DIR/caddy.yml" "depends_on:" "caddy depends on homeserver"

# --- Test: coturn.yml uses host networking ---
assert_file_contains "$TEMPLATES_DIR/coturn.yml" "network_mode: host" "coturn uses host network"
assert_file_contains "$TEMPLATES_DIR/coturn.yml" "turnserver.conf" "coturn mounts config"

# --- Test: monitoring.yml has prometheus and grafana ---
assert_file_contains "$TEMPLATES_DIR/monitoring.yml" "prometheus:" "monitoring has prometheus"
assert_file_contains "$TEMPLATES_DIR/monitoring.yml" "grafana:" "monitoring has grafana"
assert_file_contains "$TEMPLATES_DIR/monitoring.yml" "prometheus-data:" "monitoring has prometheus volume"
assert_file_contains "$TEMPLATES_DIR/monitoring.yml" "grafana-data:" "monitoring has grafana volume"

# --- Test: admin.yml connects to homeserver ---
assert_file_contains "$TEMPLATES_DIR/admin.yml" "REACT_APP_SERVER" "admin has server env var"
assert_file_contains "$TEMPLATES_DIR/admin.yml" "depends_on:" "admin depends on homeserver"

# --- Test: webclient.yml has healthcheck ---
assert_file_contains "$TEMPLATES_DIR/webclient.yml" "healthcheck:" "webclient has healthcheck"
assert_file_contains "$TEMPLATES_DIR/webclient.yml" "config.json" "webclient mounts config.json"

# --- Test: no fragment declares a top-level key of its own ---
# Fragments are concatenated into one file, so a column-0 mapping key in a
# fragment becomes a duplicate top-level key in the assembled output. Fragments
# declare which top-level section they belong to with a '# @section' marker and
# the assembler emits each key exactly once.
for tpl in "${expected_templates[@]}"; do
    assert_false "$tpl declares no top-level key" \
        grep -qE '^[A-Za-z_][A-Za-z0-9_.-]*:' "$TEMPLATES_DIR/$tpl"
done

# --- Test: every service fragment declares a services section ---
for tpl in "${expected_templates[@]}"; do
    [[ "$tpl" == "base.yml" ]] && continue  # base only has networks/volumes
    assert_file_contains "$TEMPLATES_DIR/$tpl" "^# @section services" \
        "$tpl declares a services section"
done

# --- Test: base.yml declares the shared networks and volumes sections ---
assert_file_contains "$TEMPLATES_DIR/base.yml" "^# @section networks" "base.yml declares a networks section"
assert_file_contains "$TEMPLATES_DIR/base.yml" "^# @section volumes" "base.yml declares a volumes section"

# --- Test: monitoring.yml declares its extra volumes as a section ---
assert_file_contains "$TEMPLATES_DIR/monitoring.yml" "^# @section volumes" "monitoring.yml declares a volumes section"

# --- Test: template variables use {{VARIABLE}} syntax ---
for tpl in postgres.yml synapse.yml caddy.yml coturn.yml; do
    if grep -q '{{' "$TEMPLATES_DIR/$tpl"; then
        _TEST_NUM=$((_TEST_NUM + 1))
        echo "ok $_TEST_NUM - $tpl uses template variables"
    else
        _TEST_NUM=$((_TEST_NUM + 1))
        echo "not ok $_TEST_NUM - $tpl has no template variables"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
done


# --- Renderer: values containing sed metacharacters ---
# _compose_render_fragment feeds every value into a sed 's|...|...|g' script,
# so any character with meaning to sed must survive rendering intact.
source "$LIB_DIR/19_compose.sh"

RENDER_TPL="$TEST_TMP/render-fragment.yml"
printf '%s\n' "    value: {{TESTVAR}}" > "$RENDER_TPL"

render_fragment_value() {
    declare -A _rv=([TESTVAR]="$1")
    _compose_render_fragment "$RENDER_TPL" _rv
}

render_out=""
render_fragment_value 'graf|ana' > "$TEST_TMP/render.out" 2>/dev/null || true
render_out=$(<"$TEST_TMP/render.out")
assert_eq "    value: graf|ana" "$render_out" "compose renderer preserves '|' in a value"

render_fragment_value 'a&b/c\d' > "$TEST_TMP/render.out" 2>/dev/null || true
render_out=$(<"$TEST_TMP/render.out")
assert_eq '    value: a&b/c\d' "$render_out" "compose renderer preserves & / \\ in a value"

# A value sed genuinely cannot handle (embedded newline) must be reported, not
# silently rendered as an empty fragment.
render_rc=0
render_fragment_value $'multi\nline' > "$TEST_TMP/render.out" 2>/dev/null || render_rc=$?
assert_ne "0" "$render_rc" "compose renderer returns non-zero when substitution fails"

# --- template_render: same guarantees as the compose renderer ---
TR_OUT="$TEST_TMP/render-template.out"

render_template_value() {
    declare -A _tv=([TESTVAR]="$1")
    template_render "$RENDER_TPL" "$TR_OUT" _tv
}

render_template_value 'graf|ana' 2>/dev/null || true
assert_eq "    value: graf|ana" "$(<"$TR_OUT")" "template_render preserves '|' in a value"

printf '%s\n' "SENTINEL" > "$TR_OUT"
render_rc=0
render_template_value $'multi\nline' 2>/dev/null || render_rc=$?
assert_ne "0" "$render_rc" "template_render returns non-zero when substitution fails"
assert_eq "SENTINEL" "$(<"$TR_OUT")" "template_render leaves output untouched when substitution fails"

# --- Renderer: conditional block whose key is absent from the vars array ---
# An unset key is falsy. The renderer used to loop over the vars array, so a
# block nobody set a key for kept its {{#KEY}} markers and broke the YAML.
COND_TPL="$TEST_TMP/render-conditional.yml"
cat > "$COND_TPL" << 'EOF'
# @section services
{{#NEVER_SET}}
  ghost:
    image: nope
{{/NEVER_SET}}
  real:
    image: yes
EOF

declare -A _cv=([OTHER]="true")
cond_out=$(_compose_render_fragment "$COND_TPL" _cv)

assert_no_match '\{\{' "$cond_out" "compose renderer strips markers for an absent key"
assert_no_match 'ghost' "$cond_out" "compose renderer strips the block body for an absent key"
assert_match 'real' "$cond_out" "compose renderer keeps unconditional content"

# --- compose_assemble: the merged file must be valid, parseable compose ---
# Fragments used to be concatenated verbatim, which produced one top-level
# 'services:' key per fragment. PyYAML keeps only the last, so every service but
# the last silently vanished. These tests parse the output; a text grep would
# not have caught that.

if ! python3 -c 'import yaml' 2>/dev/null; then
    skip_test "compose_assemble output parsing (python3 with PyYAML not available)"
else

compose_yaml_query() {
    # $1 = compose file, $2 = query, $3 = dotted path for the queries that take
    # one. Queries:
    #   strict            parse under a duplicate-rejecting loader, print nothing
    #   top|services|networks|volumes|secrets   sorted keys of that top-level key
    #   path <dotted>     the scalar at that path
    #   list <dotted>     sorted members (list) or keys (mapping) at that path
    #   env_files         every env_file entry across all services
    #   bare_vars         every ${VAR} in the raw file that carries no default
    # A parse error is reported as a single line so a failing assertion reads as
    # a reason, not as a traceback.
    _compose_yaml_python "$@" 2>&1
}

_compose_yaml_python() {
    python3 - "$@" <<'PY'
import re
import sys, yaml


class StrictLoader(yaml.SafeLoader):
    """Rejects duplicate mapping keys the way a strict compose parser does."""


def _no_duplicates(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                None, None, "duplicate key: %r" % (key,), key_node.start_mark)
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_duplicates)

path, query = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        doc = yaml.load(fh, Loader=StrictLoader)
except yaml.YAMLError as exc:
    sys.exit("YAML error: %s" % " ".join(str(exc).split()))


def walk(dotted):
    node = doc
    for part in dotted.split("."):
        try:
            node = node[part]
        except (KeyError, IndexError, TypeError):
            # One line, not a traceback: a failing assertion should read as a
            # reason rather than as Python noise.
            sys.exit("missing path: %s" % dotted)
    return node


if query == "strict":
    sys.exit(0)
if query == "path":
    print(walk(sys.argv[3]))
    sys.exit(0)
if query == "list":
    # Sorted members of a sequence, or sorted keys of a mapping. Sorting keeps
    # the assertion independent of the order fragments happen to be merged in.
    print(" ".join(sorted(walk(sys.argv[3]))))
    sys.exit(0)
if query == "env_files":
    found = []
    for service in (doc.get("services") or {}).values():
        entry = service.get("env_file")
        if entry is None:
            continue
        found.extend([entry] if isinstance(entry, str) else entry)
    print(" ".join(sorted(found)))
    sys.exit(0)
if query == "undeclared_secrets":
    # podman-compose raises "ERROR: undeclared secret" for a service reference
    # with no matching top-level entry, which only shows up at start time.
    declared = set(doc.get("secrets") or {})
    dangling = set()
    for service in (doc.get("services") or {}).values():
        for ref in service.get("secrets") or []:
            name = ref if isinstance(ref, str) else ref.get("source")
            if name not in declared:
                dangling.add(name)
    print(" ".join(sorted(dangling)))
    sys.exit(0)
if query == "published":
    # Every host address the file publishes, as "IP:PORT" (or "PORT" where no
    # IP is given), with the container port dropped: what a proxy on this host
    # would have to connect to.
    found = set()
    for service in (doc.get("services") or {}).values():
        for entry in service.get("ports") or []:
            if not isinstance(entry, str):
                continue
            found.add(entry.rsplit(":", 1)[0])
    print(" ".join(sorted(found)))
    sys.exit(0)
if query == "bare_vars":
    # ${NAME} with nothing between the name and the brace has no default, so
    # compose can only resolve it from a .env file or the caller's environment.
    with open(path) as fh:
        raw = fh.read()
    print(" ".join(sorted(set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", raw)))))
    sys.exit(0)
section = doc if query == "top" else (doc.get(query) or {})
print(" ".join(sorted(section)))
PY
}

compose_yaml_strict() {
    # Reports pass/fail only; the parse error would pollute TAP output.
    compose_yaml_query "$1" strict > /dev/null
}

ASSEMBLE_DIR="$TEST_TMP/install"
mkdir -p "$ASSEMBLE_DIR"
COMPOSE_FILE="$ASSEMBLE_DIR/podman-compose.yml"
COTURN_FILE="$ASSEMBLE_DIR/coturn-compose.yml"

# compose_assemble snapshots for rollback and shells out to the compose binary.
rollback_snapshot() { :; }
stub_compose_ok() { return 0; }
stub_compose_fail() { echo 'stub: mapping key "services" already defined' >&2; return 1; }

declare -a BRIDGES_ENABLED=()

reset_compose_config() {
    CONFIG=(
        [install_dir]="$ASSEMBLE_DIR"
        [domain.name]="example.test"
        [homeserver.type]="synapse"
        [webclient.type]="element"
        [coturn.enabled]="false"
    )
    BRIDGES_ENABLED=()
    COMPOSE_CMD="stub_compose_ok"
    rm -f "$ASSEMBLE_DIR"/*.yml
}

assemble_rc=0
run_assemble() {
    assemble_rc=0
    compose_assemble > "$TEST_TMP/assemble.out" 2> "$TEST_TMP/assemble.err" || assemble_rc=$?
}

# --- Default install: postgres + synapse + caddy + webclient ---
reset_compose_config
run_assemble
assert_eq "0" "$assemble_rc" "compose_assemble succeeds for a default install"
assert_eq "caddy homeserver postgres webclient" \
    "$(compose_yaml_query "$COMPOSE_FILE" services)" \
    "default install keeps every service in the parsed output"
assert_eq "$SYNAPSE_IMAGE" \
    "$(compose_yaml_query "$COMPOSE_FILE" path services.homeserver.image)" \
    "homeserver service carries the rendered synapse image"
assert_eq "1" "$(grep -c '^services:' "$COMPOSE_FILE")" \
    "assembled file has exactly one top-level services key"
assert_true "assembled file loads under a duplicate-rejecting loader" \
    compose_yaml_strict "$COMPOSE_FILE"

# --- Dendrite homeserver ---
reset_compose_config
CONFIG[homeserver.type]="dendrite"
run_assemble
assert_eq "$DENDRITE_IMAGE" \
    "$(compose_yaml_query "$COMPOSE_FILE" path services.homeserver.image)" \
    "dendrite install keeps the homeserver service"

# --- Monitoring: base and monitoring volumes must merge, not collide ---
reset_compose_config
CONFIG[monitoring.enabled]="true"
CONFIG[admin_ui.enabled]="true"
run_assemble
assert_eq "0" "$assemble_rc" "compose_assemble succeeds with monitoring and admin enabled"
assert_eq "caddy grafana homeserver postgres prometheus synapse-admin webclient" \
    "$(compose_yaml_query "$COMPOSE_FILE" services)" \
    "monitoring install keeps every service in the parsed output"
assert_eq "matrix-net" "$(compose_yaml_query "$COMPOSE_FILE" networks)" \
    "base networks survive assembly"
assert_eq "caddy-config caddy-data grafana-data postgres-data prometheus-data" \
    "$(compose_yaml_query "$COMPOSE_FILE" volumes)" \
    "base and monitoring volumes merge under one volumes key"
assert_true "monitoring install loads under a duplicate-rejecting loader" \
    compose_yaml_strict "$COMPOSE_FILE"

# --- Bridge stanzas must land under services, not under the last top-level key ---
reset_compose_config
CONFIG[monitoring.enabled]="true"
BRIDGES_ENABLED=(whatsapp)
run_assemble
assert_eq "bridge-whatsapp caddy grafana homeserver postgres prometheus webclient" \
    "$(compose_yaml_query "$COMPOSE_FILE" services)" \
    "bridge stanza lands under services"
assert_eq "matrix-net" "$(compose_yaml_query "$COMPOSE_FILE" networks)" \
    "bridge stanza does not disturb the networks key"

# --- Coturn is a separate rootful compose file, not part of the merged stack ---
reset_compose_config
CONFIG[coturn.enabled]="true"
run_assemble
assert_file_exists "$COTURN_FILE" "coturn compose file written when coturn is enabled"
assert_eq "coturn" "$(compose_yaml_query "$COTURN_FILE" services)" \
    "coturn compose file declares the coturn service"
assert_eq "host" "$(compose_yaml_query "$COTURN_FILE" path services.coturn.network_mode)" \
    "coturn keeps host networking"
assert_eq "caddy homeserver postgres webclient" \
    "$(compose_yaml_query "$COMPOSE_FILE" services)" \
    "coturn stays out of the rootless stack"

reset_compose_config
run_assemble
assert_false "no coturn compose file when coturn is disabled" test -f "$COTURN_FILE"

# --- A Cloudflare token must not reach the Caddy container ---
# DNS-01 was dropped: the pinned stock Caddy image carries no DNS provider
# module, so nothing inside that container can use CF_API_TOKEN. Handing it one
# puts a zone-editing credential in a container with no use for it. Asserted on
# the whole environment mapping rather than on the absence of one key, so an
# environment block that disappears entirely still reads as a failure.
reset_compose_config
CONFIG[dns.cloudflare_api_token]="cf-token-value"
run_assemble
assert_eq "0" "$assemble_rc" "compose_assemble succeeds with a Cloudflare token configured"
assert_eq "DOMAIN" \
    "$(compose_yaml_query "$COMPOSE_FILE" list services.caddy.environment)" \
    "the caddy container is handed no CF_API_TOKEN"
assert_false "the Cloudflare token appears nowhere in the assembled compose file" \
    grep -q 'cf-token-value' "$COMPOSE_FILE"

# --- Secret delivery, default mode: compose interpolates from .env ---
reset_compose_config
run_assemble
assert_eq "" "$(compose_yaml_query "$COMPOSE_FILE" secrets)" \
    "env mode declares no compose secrets"
assert_eq "POSTGRES_DB POSTGRES_INITDB_ARGS POSTGRES_PASSWORD POSTGRES_USER" \
    "$(compose_yaml_query "$COMPOSE_FILE" list services.postgres.environment)" \
    "env mode passes the postgres password as an environment variable"
assert_eq "$ASSEMBLE_DIR/.env" "$(compose_yaml_query "$COMPOSE_FILE" env_files)" \
    "env mode keeps the homeserver env_file pointing at .env"
assert_eq "POSTGRES_PASSWORD" "$(compose_yaml_query "$COMPOSE_FILE" bare_vars)" \
    "env mode resolves the postgres password from .env"

# --- Secret delivery, podman mode: the stack must be startable without .env ---
# A podman secret is exposed to the container as a file under /run/secrets/,
# never as an environment variable, and podman mode writes no .env for compose
# to interpolate from. Both halves have to be wired or nothing starts.
reset_compose_config
CONFIG["secrets.mode"]="podman"
run_assemble
assert_eq "0" "$assemble_rc" "compose_assemble succeeds with secrets.mode=podman"
assert_eq "matrix-postgres-password" "$(compose_yaml_query "$COMPOSE_FILE" secrets)" \
    "podman mode declares the postgres secret at the top level"
assert_eq "True" \
    "$(compose_yaml_query "$COMPOSE_FILE" path secrets.matrix-postgres-password.external)" \
    "the declared secret is external, i.e. created by podman secret create"
assert_eq "matrix-postgres-password" \
    "$(compose_yaml_query "$COMPOSE_FILE" list services.postgres.secrets)" \
    "the postgres service references the secret"
assert_eq "/run/secrets/matrix-postgres-password" \
    "$(compose_yaml_query "$COMPOSE_FILE" path services.postgres.environment.POSTGRES_PASSWORD_FILE)" \
    "postgres reads its password from the mounted secret file"
# The image aborts when both forms are set, so the _FILE form must replace the
# plain variable rather than sit alongside it.
assert_eq "POSTGRES_DB POSTGRES_INITDB_ARGS POSTGRES_PASSWORD_FILE POSTGRES_USER" \
    "$(compose_yaml_query "$COMPOSE_FILE" list services.postgres.environment)" \
    "podman mode sets no POSTGRES_PASSWORD alongside the _FILE form"
assert_eq "" "$(compose_yaml_query "$COMPOSE_FILE" env_files)" \
    "podman mode references no env_file, since no .env is written"
assert_eq "" "$(compose_yaml_query "$COMPOSE_FILE" bare_vars)" \
    "podman mode leaves no variable that only a .env could resolve"
assert_true "podman mode output loads under a duplicate-rejecting loader" \
    compose_yaml_strict "$COMPOSE_FILE"

# --- Grafana must never ship with the built-in admin/admin ---
# Grafana is served on a public TLS subdomain, and admin_password is "set once
# on first-run", so a placeholder that survives the first start is permanent.
reset_compose_config
CONFIG[monitoring.enabled]="true"
run_assemble
assert_ne "admin" \
    "$(compose_yaml_query "$COMPOSE_FILE" path services.grafana.environment.GF_SECURITY_ADMIN_PASSWORD)" \
    "env mode does not leave Grafana on the built-in password"
assert_eq '${GRAFANA_ADMIN_PASSWORD}' \
    "$(compose_yaml_query "$COMPOSE_FILE" path services.grafana.environment.GF_SECURITY_ADMIN_PASSWORD)" \
    "env mode takes the Grafana password from .env with no fallback default"
assert_eq "GRAFANA_ADMIN_PASSWORD POSTGRES_PASSWORD" \
    "$(compose_yaml_query "$COMPOSE_FILE" bare_vars)" \
    "env mode requires .env to supply the Grafana password"

reset_compose_config
CONFIG["secrets.mode"]="podman"
CONFIG[monitoring.enabled]="true"
run_assemble
assert_eq "0" "$assemble_rc" "compose_assemble succeeds with podman secrets and monitoring"
assert_eq "/run/secrets/matrix-grafana-password" \
    "$(compose_yaml_query "$COMPOSE_FILE" path services.grafana.environment.GF_SECURITY_ADMIN_PASSWORD__FILE)" \
    "podman mode points Grafana at the mounted secret file"
# The Grafana entrypoint exits when both forms are set, the same rule as the
# postgres image.
assert_eq "GF_SECURITY_ADMIN_PASSWORD__FILE GF_SECURITY_ADMIN_USER GF_SERVER_ROOT_URL GF_USERS_ALLOW_SIGN_UP" \
    "$(compose_yaml_query "$COMPOSE_FILE" list services.grafana.environment)" \
    "podman mode sets no GF_SECURITY_ADMIN_PASSWORD alongside the __FILE form"
assert_eq "matrix-grafana-password" \
    "$(compose_yaml_query "$COMPOSE_FILE" list services.grafana.secrets)" \
    "the grafana service references its secret"
assert_eq "matrix-grafana-password matrix-postgres-password" \
    "$(compose_yaml_query "$COMPOSE_FILE" secrets)" \
    "both secrets are declared under one top-level secrets key"
assert_true "podman mode with monitoring loads under a duplicate-rejecting loader" \
    compose_yaml_strict "$COMPOSE_FILE"

# --- Mode invariance: podman delivery must hold for every stack shape ---
# secrets.mode=podman claims to replace .env delivery outright, so the invariant
# has to survive every combination of the settings it overrides. Checking only
# the default shape would leave a bypass invisible.
for inv_hs in synapse dendrite; do
    for inv_extra in none monitoring admin; do
        for inv_webclient in element none; do
            reset_compose_config
            CONFIG["secrets.mode"]="podman"
            CONFIG[homeserver.type]="$inv_hs"
            CONFIG[webclient.type]="$inv_webclient"
            case "$inv_extra" in
                monitoring) CONFIG[monitoring.enabled]="true" ;;
                admin)      CONFIG[admin_ui.enabled]="true" ;;
            esac
            run_assemble

            inv_label="hs=$inv_hs, $inv_extra, webclient=$inv_webclient"
            inv_secrets="matrix-postgres-password"
            [[ "$inv_extra" == "monitoring" ]] &&
                inv_secrets="matrix-grafana-password matrix-postgres-password"

            assert_eq "0" "$assemble_rc" "podman mode assembles ($inv_label)"
            assert_eq "" "$(compose_yaml_query "$COMPOSE_FILE" env_files)" \
                "podman mode references no env_file ($inv_label)"
            assert_eq "" "$(compose_yaml_query "$COMPOSE_FILE" bare_vars)" \
                "podman mode leaves no .env-only variable ($inv_label)"
            assert_eq "$inv_secrets" \
                "$(compose_yaml_query "$COMPOSE_FILE" secrets)" \
                "podman mode declares exactly the secrets in use ($inv_label)"
            assert_eq "" "$(compose_yaml_query "$COMPOSE_FILE" undeclared_secrets)" \
                "every service secret reference is declared ($inv_label)"
        done
    done
done

# =====================================================================
# External-proxy mode has to give the admin's proxy something to connect to
#
# With proxy.external=true the Caddy fragment is left out, so nothing on
# matrix-net is published, and the homeserver's `ports: []` meant the generated
# snippets pointed the operator's nginx/apache/traefik at a port no process was
# listening on. The homeserver's client port is published instead, bound to
# proxy.bind_address — loopback by default, so it is reachable from the host and
# from nowhere else. These assertions parse the assembled file and compare it
# with the rendered snippet, so the two cannot drift apart.
# =====================================================================

source "$LIB_DIR/09_proxy_detect.sh"

SNIPPET_DIR="$ASSEMBLE_DIR/proxy-snippets"

# The backend address the generated snippet hands the operator, read back out
# of the rendered file rather than restated here.
generic_snippet_backend() {
    rm -rf "$SNIPPET_DIR"
    DETECTED_PROXY="generic"
    _generate_proxy_snippet >/dev/null 2>&1 || true
    sed -n 's|^Homeserver backend: http://\(.*\)$|\1|p' \
        "$SNIPPET_DIR/matrix-proxy-requirements.txt" 2>/dev/null | paste -sd' ' -
}

# Every backend URL the traefik snippet routes to, as a sorted "host:port" set.
traefik_snippet_backends() {
    rm -rf "$SNIPPET_DIR"
    DETECTED_PROXY="traefik"
    _generate_proxy_snippet >/dev/null 2>&1 || true
    sed -n 's|^ *- url: "http://\(.*\)"$|\1|p' \
        "$SNIPPET_DIR/matrix-traefik.yml" 2>/dev/null | sort -u | paste -sd' ' -
}

# --- Default path: Caddy fronts the homeserver, so nothing is published ---
reset_compose_config
run_assemble
assert_eq "" "$(compose_yaml_query "$COMPOSE_FILE" list services.homeserver.ports)" \
    "default install publishes no homeserver port"
assert_eq "443 80 8448" "$(compose_yaml_query "$COMPOSE_FILE" published)" \
    "default install publishes only Caddy's own ports"

reset_compose_config
CONFIG["proxy.external"]="false"
run_assemble
assert_eq "" "$(compose_yaml_query "$COMPOSE_FILE" list services.homeserver.ports)" \
    "proxy.external=false publishes no homeserver port"

# --- External proxy: the client port is published on loopback ---
reset_compose_config
CONFIG["proxy.external"]="true"
run_assemble
assert_eq "0" "$assemble_rc" "compose_assemble succeeds with an external proxy"
assert_eq "homeserver postgres webclient" \
    "$(compose_yaml_query "$COMPOSE_FILE" services)" \
    "external-proxy mode still leaves Caddy out of the stack"
assert_eq "127.0.0.1:8008:8008" \
    "$(compose_yaml_query "$COMPOSE_FILE" list services.homeserver.ports)" \
    "external-proxy mode publishes the client port on loopback by default"
assert_eq "127.0.0.1:8080:80" \
    "$(compose_yaml_query "$COMPOSE_FILE" list services.webclient.ports)" \
    "external-proxy mode publishes the web client on loopback by default"
assert_true "external-proxy output loads under a duplicate-rejecting loader" \
    compose_yaml_strict "$COMPOSE_FILE"

# The snippets delegate federation to port 443 (.well-known/matrix/server
# answers "{{DOMAIN}}:443") and route /_matrix — federation included — to the
# client port, which Synapse's 8008 listener serves with resources
# [client, federation]. Nothing asks for 8448, so publishing it would open a
# port no generated config refers to.
assert_no_match ':8448' "$(compose_yaml_query "$COMPOSE_FILE" published)" \
    "external-proxy mode does not publish the federation port"

# --- The snippet's target and the published address are the same address ---
reset_compose_config
CONFIG["proxy.external"]="true"
run_assemble
# The query exits non-zero when the key is absent, which is exactly the state
# under test: swallow it so the assertion below reports it rather than errexit
# killing the rest of the file.
published_hs=$(compose_yaml_query "$COMPOSE_FILE" list services.homeserver.ports) || true
assert_eq "${published_hs%:*}" "$(generic_snippet_backend)" \
    "the snippet's backend is the address the compose file publishes"
assert_eq "$(compose_yaml_query "$COMPOSE_FILE" published)" \
    "$(traefik_snippet_backends)" \
    "every traefik snippet backend is an address the compose file publishes"

reset_compose_config
CONFIG["proxy.external"]="true"
CONFIG["homeserver.type"]="dendrite"
run_assemble
# The query exits non-zero when the key is absent, which is exactly the state
# under test: swallow it so the assertion below reports it rather than errexit
# killing the rest of the file.
published_hs=$(compose_yaml_query "$COMPOSE_FILE" list services.homeserver.ports) || true
assert_eq "${published_hs%:*}" "$(generic_snippet_backend)" \
    "dendrite: the snippet's backend is the address the compose file publishes"

# --- The bind address is the operator's to change ---
reset_compose_config
CONFIG["proxy.external"]="true"
CONFIG["proxy.bind_address"]="10.1.2.3"
run_assemble
assert_eq "10.1.2.3:8008:8008" \
    "$(compose_yaml_query "$COMPOSE_FILE" list services.homeserver.ports)" \
    "a configured bind address is what the homeserver port is published on"
# The query exits non-zero when the key is absent, which is exactly the state
# under test: swallow it so the assertion below reports it rather than errexit
# killing the rest of the file.
published_hs=$(compose_yaml_query "$COMPOSE_FILE" list services.homeserver.ports) || true
assert_eq "${published_hs%:*}" "$(generic_snippet_backend)" \
    "a configured bind address reaches the snippet too"

# podman-run(1) gives the mapping as [[ip:][hostPort]:]containerPort, so an
# IPv6 literal has to be bracketed for its own colons not to read as field
# separators.
reset_compose_config
CONFIG["proxy.external"]="true"
CONFIG["proxy.bind_address"]="::1"
run_assemble
assert_eq "[::1]:8008:8008" \
    "$(compose_yaml_query "$COMPOSE_FILE" list services.homeserver.ports)" \
    "an IPv6 bind address is bracketed in the published port"
# The query exits non-zero when the key is absent, which is exactly the state
# under test: swallow it so the assertion below reports it rather than errexit
# killing the rest of the file.
published_hs=$(compose_yaml_query "$COMPOSE_FILE" list services.homeserver.ports) || true
assert_eq "${published_hs%:*}" "$(generic_snippet_backend)" \
    "an IPv6 bind address is bracketed in the snippet backend too"

# --- Mode invariance: external-proxy mode has one job, in every stack shape ---
# The mode claims the operator's own proxy fronts the stack, so the backend it
# needs must exist whatever else is turned on. Checking only the default shape
# would leave a combination that quietly publishes nothing.
for ext_hs in synapse dendrite; do
    for ext_wc in element none; do
        for ext_extra in none monitoring admin; do
            reset_compose_config
            CONFIG["proxy.external"]="true"
            CONFIG["homeserver.type"]="$ext_hs"
            CONFIG["webclient.type"]="$ext_wc"
            case "$ext_extra" in
                monitoring) CONFIG["monitoring.enabled"]="true" ;;
                admin)      CONFIG["admin_ui.enabled"]="true" ;;
            esac
            run_assemble

            ext_label="hs=$ext_hs, $ext_extra, webclient=$ext_wc"
            assert_eq "0" "$assemble_rc" "external-proxy mode assembles ($ext_label)"
            assert_eq "127.0.0.1:8008:8008" \
                "$(compose_yaml_query "$COMPOSE_FILE" list services.homeserver.ports)" \
                "external-proxy mode publishes the client port on loopback ($ext_label)"
            assert_no_match ':8448' "$(compose_yaml_query "$COMPOSE_FILE" published)" \
                "external-proxy mode publishes no federation port ($ext_label)"

            reset_compose_config
            CONFIG["homeserver.type"]="$ext_hs"
            CONFIG["webclient.type"]="$ext_wc"
            case "$ext_extra" in
                monitoring) CONFIG["monitoring.enabled"]="true" ;;
                admin)      CONFIG["admin_ui.enabled"]="true" ;;
            esac
            run_assemble
            assert_eq "" \
                "$(compose_yaml_query "$COMPOSE_FILE" list services.homeserver.ports)" \
                "the default path publishes no homeserver port ($ext_label)"
        done
    done
done

# --- A compose file the compose binary rejects must fail the run, loudly ---
reset_compose_config
COMPOSE_CMD="stub_compose_fail"
run_assemble
assert_ne "0" "$assemble_rc" "compose_assemble fails when validation fails"
assert_file_contains "$TEST_TMP/assemble.err" "already defined" \
    "compose validation output is reported, not swallowed"

fi  # PyYAML available

# =====================================================================
# An unusable fragment is reported, not fatal
#
# _compose_render_fragment read its input with `content=$(<"$input")`. bash(1)
# under COMMAND SUBSTITUTION calls `$(< file)` "the equivalent but faster" form
# of `$(cat file)`, but they differ when the open fails: the redirection form
# exits the shell even from a call in a `||` list, where bash(1) under `set -e`
# otherwise suppresses the exit. Both call sites here happen to wrap the call in
# a command substitution, which confined the death to that subshell and turned
# it into a bare rc=1 with no log line; called any other way it would take
# setup.sh down. The function has to fail on its own terms.
# =====================================================================

# Run in a child shell with a sentinel after the call. Assigning the result of
# the call to a variable would insulate the test from the very failure under
# test, and the assertion would pass while proving nothing.
render_fragment_in_child() {
    local fragment="$1"

    cat > "$TEST_TMP/fragment_child.sh" << CHILD
set -euo pipefail
source "$PROJECT_DIR/tests/test_utils.sh"
source "$LIB_DIR/19_compose.sh"

declare -A frag_vars=([TESTVAR]="value")
rc=0
_compose_render_fragment "$fragment" frag_vars > /dev/null || rc=\$?
printf 'CALLER_SURVIVED rc=%s\n' "\$rc"
CHILD

    bash "$TEST_TMP/fragment_child.sh" 2>&1 || true
}

# --- Test: a missing fragment ---
frag_missing_out=$(render_fragment_in_child "$TEST_TMP/no-such-fragment.yml")

assert_match "CALLER_SURVIVED" "$frag_missing_out" \
    "a missing fragment does not terminate the caller"
assert_match "CALLER_SURVIVED rc=1" "$frag_missing_out" \
    "a missing fragment makes _compose_render_fragment return non-zero"
assert_match "no-such-fragment.yml" "$frag_missing_out" \
    "a missing fragment is named in the error"

# --- Test: an unreadable fragment ---
# Mode 000 is readable by root, so the check would pass vacuously there.
printf '%s\n' "    value: {{TESTVAR}}" > "$TEST_TMP/unreadable-fragment.yml"
chmod 000 "$TEST_TMP/unreadable-fragment.yml"

if [[ $EUID -eq 0 ]]; then
    skip_test "an unreadable fragment does not terminate the caller (running as root)"
    skip_test "an unreadable fragment makes _compose_render_fragment return non-zero (running as root)"
else
    frag_unreadable_out=$(render_fragment_in_child "$TEST_TMP/unreadable-fragment.yml")

    assert_match "CALLER_SURVIVED" "$frag_unreadable_out" \
        "an unreadable fragment does not terminate the caller"
    assert_match "CALLER_SURVIVED rc=1" "$frag_unreadable_out" \
        "an unreadable fragment makes _compose_render_fragment return non-zero"
fi
chmod 644 "$TEST_TMP/unreadable-fragment.yml"

# --- Test: a directory where a fragment was expected ---
# `$(<dir)` opens the directory, reads nothing and reports no error, so this
# returned 0 having rendered the fragment as nothing; the service it was meant
# to contribute vanished from the compose file without a word.
mkdir -p "$TEST_TMP/a-directory.yml"
frag_dir_out=$(render_fragment_in_child "$TEST_TMP/a-directory.yml")

assert_match "CALLER_SURVIVED rc=1" "$frag_dir_out" \
    "a directory in place of a fragment makes _compose_render_fragment return non-zero"

# --- Test: reading a fragment preserves the content byte for byte ---
# Pins the read semantics the fix must not change. Command substitution deletes
# trailing newlines (bash(1), COMMAND SUBSTITUTION).
declare -A frag_pin_vars=([TESTVAR]="x")

printf '    value: {{TESTVAR}}\n\n\n' > "$TEST_TMP/pin-trailing.yml"
printf '    value: {{TESTVAR}}'       > "$TEST_TMP/pin-notrailing.yml"

assert_eq "    value: x" "$(_compose_render_fragment "$TEST_TMP/pin-trailing.yml" frag_pin_vars)" \
    "trailing newlines in a fragment are stripped"
assert_eq "    value: x" "$(_compose_render_fragment "$TEST_TMP/pin-notrailing.yml" frag_pin_vars)" \
    "a fragment with no trailing newline renders unchanged"

# =====================================================================
# proxy.bind_address ends up in a published-port field
#
# The value is the host side of a port mapping and the backend address in every
# generated snippet. A hostname there would be resolved by neither, and anything
# carrying a colon or a space would either shift the other fields of the mapping
# along or be rejected by the compose engine at start time. Only an IP literal
# is accepted.
# =====================================================================
source "$LIB_DIR/04_config.sh"
HEADLESS="false"

check_bind_address() {
    local addr="$1"
    CONFIG=()
    CONFIG["domain.name"]="example.com"
    [[ -n "$addr" ]] && CONFIG["proxy.bind_address"]="$addr"
    _config_apply_defaults
    config_validate 2>/dev/null
}

CONFIG=()
CONFIG["domain.name"]="example.com"
_config_apply_defaults
assert_eq "127.0.0.1" "${CONFIG[proxy.bind_address]:-<unset>}" \
    "proxy.bind_address defaults to loopback"

for good_addr in 127.0.0.1 10.1.2.3 0.0.0.0 ::1 fd00::1; do
    assert_true "proxy.bind_address accepts the IP literal '$good_addr'" \
        check_bind_address "$good_addr"
done

for bad_addr in localhost example.com 127.0.0.1:8008 "127.0.0.1 8008" 999.1.1.1 '$(id)' 1.2.3; do
    assert_false "proxy.bind_address rejects '$bad_addr'" \
        check_bind_address "$bad_addr"
done

teardown_test_tmp
test_report
