# ci-auditor report

**Target:** `/media/owner/Workspace/Matrix_Setup/.github/workflows/` on branch `qa/fleet-loop-20260910`
**Started:** 2026-09-10T13:23:12Z
**Status:** COMPLETE

## What works well

These are verified, not assumed.

1. **Every action is pinned to a full 40-character commit SHA with a version
   comment, and all four SHAs are genuine.** Checked each against the upstream
   API:
   - `actions/checkout@df4cb1c0…` -> `v6.0.3` annotated tag dereferences to
     exactly this commit ("Update changelog for v6.0.3 (#2446)", 2026-06-02).
   - `sigstore/cosign-installer@398d4b0e…` -> the `v3` tag currently
     dereferences to exactly this commit ("default cosign to v2.5.2 (#194)").
   - `anchore/sbom-action@e22c3899…` -> tags `v0`, `v0.24.0`, `latest` all point
     at this commit.
   - `actions/attest-build-provenance@a2bbfa25…` -> tag `v4.1.0` points at this
     commit.
2. **No injection surface.** Neither workflow interpolates `${{ github.event.* }}`,
   `github.head_ref`, or any other attacker-controllable expression into a
   `run:` block. `release.yml:60` uses the shell variable `"${GITHUB_REF_NAME}"`
   rather than `${{ github.ref_name }}` — the injection-safe form, and the
   correct choice even though tag creation already requires write access.
3. **No dangerous triggers.** No `pull_request_target`, no `workflow_run`, no
   `issue_comment`, no `schedule`. There is no path where untrusted code meets a
   write-scoped token, and no artifact is passed across a trust boundary.
4. **Permissions are declared and minimal.** `ci.yml:8-9` is `contents: read`.
   `release.yml:9-12` grants exactly the three scopes the steps need
   (`contents: write` for `gh release create`, `id-token: write` +
   `attestations: write` for keyless signing and provenance) with an inline
   comment explaining each. Repo default workflow token is also `read`
   (`default_workflow_permissions: "read"`,
   `can_approve_pull_request_reviews: false`).
5. **No secrets beyond `GITHUB_TOKEN`.** No `secrets.*` reference in either
   file. `release.yml:20` sets `persist-credentials: false`, so the checkout
   credential is not left in `.git/config` for later steps to reuse.
6. **No caches at all**, so there is no cache-poisoning path from a fork PR into
   a privileged job.
7. **The supply-chain chain itself is unusually complete for a Bash repo**:
   upstream digest drift gate, per-image CycloneDX SBOMs, keyless cosign bundles,
   and SLSA build provenance, with consumer verification instructions in
   `docs/SUPPLY_CHAIN.md` whose `--certificate-identity` string matches what this
   workflow's OIDC token would actually assert.
8. **All 17 `*_IMAGE` constants in `lib/00_constants.sh` are digest-pinned** and
   all 17 match the regex both release scripts rely on.
9. **The most recent CI run is genuinely clean.** Extracted the log for run
   33442245991 (2026-08-31): zero deprecation warnings, zero `##[warning]`
   lines, `Results: 300 passed, 0 failed, 0 skipped`. Runner image
   `ubuntu-24.04` (20260823.283.1). All actions declare `using: node24` or
   `composite`, so nothing faces a Node runtime force-migration.

## Workflow inventory

| | `ci.yml` | `release.yml` |
|---|---|---|
| Triggers | `push` to `main`; `pull_request` (default types) | `push` tags `v*` |
| Runner | `ubuntu-latest` | `ubuntu-latest` |
| Permissions | `contents: read` | `contents: write`, `id-token: write`, `attestations: write` |
| Secrets | none | none (`github.token` only) |
| Third-party actions | `actions/checkout` (SHA) | `actions/checkout`, `anchore/sbom-action/download-syft`, `sigstore/cosign-installer`, `actions/attest-build-provenance` (all SHA) |
| Jobs | `lint-and-test` | `release` |
| Behaviour on a **fork PR** | Checks out the untrusted merge ref and executes `tests/test_runner.sh` with a **read-only** token and **no secrets**. This is the standard, safe `pull_request` model. | Not reachable — forks cannot push tags to this repo. |

Doc citation for the fork-PR claim: "The `GITHUB_TOKEN` has read-only
permissions in pull requests from forked repositories" and "With the exception
of `GITHUB_TOKEN`, secrets are not passed to the runner when a workflow is
triggered from a forked repository."
<https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows>

Repository Actions settings (read via API):
`{"enabled":true,"allowed_actions":"all","sha_pinning_required":false}`.

Run history (all 6 recorded runs): 4x `CI` on `push`, 2x `Release` on tag push.
**Zero `pull_request`-triggered runs.**

## Can each gate actually fail?

This is the section the brief asked to be answered directly. Summary first:

| Gate | Can a broken input turn it red? | How established |
|---|---|---|
| ShellCheck (`ci.yml:20-23`) | **Yes**, within its severity floor | Ran the identical command locally over the same 52 files |
| Test suite (`ci.yml:25-26`) | **Yes for every test file that exists today**; **no** for a future file that omits `test_report` | Demonstrated both directions in a scratch copy |
| `pin-digests.sh --check` (`release.yml:23-24`) | **Yes** for real drift; **no** if the constants regex ever stops matching | Static trace of `scripts/pin-digests.sh:84-115` |
| Signature *validity* (`release.yml:35-47`) | **No such gate exists** | The `cosign verify-blob` command is a comment only |
| Any of the above gating a **merge** | **No** | `main` has no protection and no rulesets |
| Any of the above gating a **release** | **No** | `ci.yml` does not trigger on tags |

Details are in findings F1, F2, F3, F4, F6, F7 below.

Two things I could not settle without running CI, and what would settle them:

- Whether the `pull_request` trigger behaves as written **on a real fork PR**.
  Nothing in the run history exercises it. Only opening a genuine fork PR (or
  running the job under `act` with a fork-shaped event payload) would settle it.
  Static reading says it is correct.
- Whether `--severity=warning` is the version-stable floor. `apt-get install
  shellcheck` is unpinned; the runner currently supplies whatever
  `ubuntu-24.04` ships. Only reading the version out of a CI log (the step
  does not print it) or pinning the version would settle it.

## Findings

---

### [HIGH] The CI job gates nothing — `main` has no branch protection and no rulesets

**Confidence: 5** (queried the API directly)

- **Situation:** `ci.yml` runs `lint-and-test` on every `pull_request` and on
  every push to `main`. `docs/SUPPLY_CHAIN.md:22` presents it as the lint/test
  control for the repo.
- **Behaviour:** `GET /repos/obelisk-complex/Matrix_Setup/branches/main/protection`
  returns `404 {"message":"Branch not protected"}`, and
  `GET /repos/obelisk-complex/Matrix_Setup/rulesets` returns `[]`. There is no
  required status check anywhere. The job's conclusion is advisory: a PR with a
  red `lint-and-test` can be merged, and a commit can be pushed straight to
  `main` with no PR at all. Five of the six recorded runs are direct pushes to
  `main`, so this is the working pattern, not a hypothetical.
- **Impact:** Every other gate in this audit is downstream of this one. A
  broken commit reaches `main` regardless of what CI says, and `main` is what
  users install from via the README's curl-to-bash instructions. This is the
  single change that converts the existing (good) CI into enforcement.
- **Fix:** Add a ruleset requiring the check. Repo settings, or:

```bash
gh api -X POST repos/obelisk-complex/Matrix_Setup/rulesets \
  --input - <<'JSON'
{
  "name": "main protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          { "context": "lint-and-test" }
        ]
      }
    }
  ]
}
JSON
```

Note this is a settings change, not a repo edit; it is listed here for the
maintainer to apply, and it was **not** applied by this audit.

---

### [HIGH] A tag push publishes a signed, attested release without running lint or tests

**Confidence: 5** (traced both triggers)

- **Situation:** `release.yml:5-7` triggers on `push: tags: ['v*']`. `ci.yml:3-6`
  triggers on `push: branches: [main]` and `pull_request` — **`branches:`, not
  `tags:`**, so pushing a tag does not start a CI run.
- **Behaviour:** The release job's first substantive step is
  `pin-digests.sh --check` (`release.yml:24`). It never runs `shellcheck` and
  never runs `tests/test_runner.sh`. Combined with the previous finding, nothing
  requires the tagged commit to be one where CI passed — a tag can be pushed at
  any commit on any branch, including one that never went through `main`. Run
  history confirms the two `Release` runs (v0.1.0, v0.1.1) had sibling `CI` runs
  only because the tag happened to coincide with a `main` push.
- **Impact:** The pipeline can emit `setup.sh` signed with a Sigstore bundle and
  carrying SLSA provenance, from a commit that fails shellcheck and fails the
  300-test suite. `docs/SUPPLY_CHAIN.md:49-63` tells users to verify that
  signature. The signature is honest about *what it attests* — that this workflow
  in this repo produced the file — but a reader of that section will reasonably
  read it as a quality assurance it does not carry.
- **Fix:** Split the gate into a job the release depends on. Minimal version:

```yaml
jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6.0.3
      - name: Install shellcheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck
      - name: ShellCheck (severity=warning)
        run: |
          mapfile -t files < <(find . -type f -name '*.sh' -not -path './.git/*')
          shellcheck --severity=warning -x "${files[@]}"
      - name: Run test suite
        run: bash tests/test_runner.sh

  release:
    needs: verify
    runs-on: ubuntu-latest
    # ... existing steps unchanged
```

Duplicating the three steps is deliberate; a reusable workflow for two callers
is not worth the indirection here.

---

### [MEDIUM] `test_runner.sh` derives its exit code and its summary line from independent sources, which can disagree

**Confidence: 5** (reproduced in a scratch copy, repo untouched)

- **Situation:** `ci.yml:26` runs `bash tests/test_runner.sh`; the step's pass/fail
  is the runner's exit status. `tests/test_runner.sh:32` captures each test file's
  exit code, `:59-63` returns it, `:84-86` sets `total_exit=1`, `:102` exits with
  it. Separately, `:41-45` counts `not ok ` lines into `TESTS_FAILED`, which is
  printed at `:92-93` and **never influences the exit code**.
- **Behaviour:** Every test file that exists today ends in `test_report`
  (`tests/test_utils.sh:198-203`, `exit 1` when `_TEST_FAILURES > 0`) or an
  explicit `exit $(( fails == 0 ? 0 : 1 ))` (`tests/test_phase_resolution.sh:49`),
  so the two agree right now — I verified the last non-comment line of all 11
  discovered test files. A file that prints `not ok` and then falls off the end
  exits 0 and the runner goes green while printing the failures. Reproduced in a
  copy of the repo under the scratchpad:

  ```
  RUNNER EXIT: 0
    not ok 1 - deliberately broken assertion
    not ok 2 - another broken assertion
  ==========================
  Results: 0 passed, 2 failed, 0 skipped
  ```

  Positive control, same probe file with `test_report` appended: `RUNNER EXIT: 1`.
- **Impact:** Latent rather than active. It converts one forgotten line in a
  future test file into a permanently green CI that visibly prints its own
  failures — the worst failure mode for a gate, because the log looks like it
  is working.
- **Fix:** Make the counter authoritative too, `tests/test_runner.sh:95`:

```bash
    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        printf '%sFailed:%s\n' "$RED" "$RESET"
        for t in "${FAILED_TESTS[@]}"; do
            printf '  %s- %s%s\n' "$RED" "$t" "$RESET"
        done
    fi

    # A test file that prints "not ok" but exits 0 must still fail the run.
    (( TESTS_FAILED > 0 )) && total_exit=1

    exit $total_exit
```

---

### [MEDIUM] The release signs artifacts but never verifies that the signature it just produced is verifiable

**Confidence: 5**

- **Situation:** `release.yml:35-47` runs `cosign sign-blob --new-bundle-format`
  for `setup.sh` and each SBOM. `release.yml:37-41` is a comment giving the exact
  `cosign verify-blob` invocation users should run.
- **Behaviour:** That verify command is never executed by the workflow. The step
  fails only if `sign-blob` itself exits non-zero. `sign-blob` succeeding is not
  the same claim as "the emitted bundle verifies against the identity documented
  in `docs/SUPPLY_CHAIN.md:55-63`". A cosign version bump changing
  `--new-bundle-format` semantics, or an identity mismatch, publishes silently.
  The pinned `cosign-installer` commit is the one that "default[s] cosign to
  v2.5.2", so the cosign binary version is itself floating relative to that
  installer pin's own default.
- **Impact:** The first person to discover a bad bundle is a user following the
  verification instructions, after the release is public. Cost of the fix is
  seconds.
- **Fix:** Add after the signing step — the identity is derivable from the
  workflow context, no new secret needed:

```yaml
      - name: Verify the bundles we just produced
        env:
          IDENTITY: https://github.com/${{ github.repository }}/.github/workflows/release.yml@${{ github.ref }}
        run: |
          verify() {
            cosign verify-blob "$1" --bundle "$1.cosign.bundle" \
              --new-bundle-format \
              --certificate-identity "$IDENTITY" \
              --certificate-oidc-issuer https://token.actions.githubusercontent.com
          }
          verify setup.sh
          for f in sbom/*.cdx.json; do verify "$f"; done
```

(`${{ github.repository }}` and `${{ github.ref }}` are not attacker-controlled
here and are passed via `env:` rather than inlined, consistent with the file's
existing style.)

---

### [MEDIUM] The digest drift gate passes vacuously if it finds zero images

**Confidence: 5** (static trace; the vacuous branch is not currently reachable)

- **Situation:** `release.yml:22-24` is described in its own comment as "Fail the
  release if any pinned digest no longer matches upstream", and
  `docs/SUPPLY_CHAIN.md:39-40` repeats that claim.
- **Behaviour:** `scripts/pin-digests.sh:73-77` builds `CURRENT` from lines
  matching `^readonly[[:space:]]+([A-Z_]+_IMAGE)="([^"]+)"`. If that regex matches
  nothing — a refactor to `declare -r`, a rename, a move out of
  `lib/00_constants.sh`, a reformat that puts the value on a continuation line —
  then the loop at `:84` never executes, `FAILED` stays empty, `drift` stays `0`,
  and `:114` prints `OK: all image digests match upstream.` and exits 0. The
  gate reports success having checked nothing. I confirmed the regex currently
  matches all 17 images, so this is a robustness gap, not a live miss.
- **Impact:** The failure mode is silent and the message is actively
  reassuring. The same shape affects `scripts/gen-sbom.sh:23-31` (`count=0`,
  empty `sbom/`), though there the release does still go red downstream because
  `release.yml:44` iterates an unmatched glob and `cosign` fails on the literal
  path `sbom/*.cdx.json`.
- **Fix:** Assert non-empty in `scripts/pin-digests.sh` after the `CURRENT` loop
  (line 77) and in `scripts/gen-sbom.sh` after its loop (line 31):

```bash
# pin-digests.sh, after the CURRENT loop
if (( ${#CURRENT[@]} == 0 )); then
    echo "ERROR: no *_IMAGE constants found in $CONSTANTS — regex drift?" >&2
    exit 1
fi
```

```bash
# gen-sbom.sh, replacing the final echo
if (( count == 0 )); then
    echo "ERROR: no *_IMAGE constants found in $CONSTANTS — regex drift?" >&2
    exit 1
fi
echo "Wrote $count CycloneDX SBOM(s) to $OUT/"
```

---

### [MEDIUM] The `pull_request` path has never executed

**Confidence: 5** (full run history is six runs)

- **Situation:** `ci.yml:6` declares a `pull_request` trigger, and the repo is
  public, so fork PRs are possible.
- **Behaviour:** All six recorded runs are `push`-triggered (four `CI` on `main`,
  two `Release` on tags). No `pull_request` run exists. The PR gate is entirely
  unexercised — including the parts most specific to that trigger: the merge-ref
  checkout, `sudo apt-get` on a fork-PR runner, and the read-only token.
- **Impact:** Not a vulnerability; static reading of the workflow says the fork
  case is handled correctly and safely. But "we have PR CI" is currently an
  untested assertion, and it will first be tested by an outside contributor.
  Given the direct-push-to-`main` habit visible in the history, it may stay
  untested indefinitely.
- **Fix:** Land the next change as a PR rather than a direct push, which
  exercises the path and (with the ruleset from the first finding) makes it
  load-bearing at the same time.

---

### [LOW] The lint gate cannot fail on any `info`-severity finding

**Confidence: 5** (ran the identical command locally at each level)

- **Situation:** `ci.yml:23` runs `shellcheck --severity=warning -x`. `--severity`
  is a floor, so `info` and `style` diagnostics are excluded from both the output
  and the exit status.
- **Behaviour:** Over the same 52 files the CI command discovers, locally
  (ShellCheck 0.9.0): `--severity=warning` -> 0 findings (genuinely clean),
  `--severity=info` -> 40, `--severity=style` -> 43. The 40 are
  28x SC1091 (cannot follow sourced file — noise, the libs are sourced
  dynamically), 7x SC2153 (possible misspelling — false positives on the
  intentional `CONFIG`-derived uppercase globals), 4x SC2317 (unreachable —
  false positives on trap/stub functions), and 1x SC2086. That one SC2086 is
  `lib/21_deploy.sh:52`, `run_as_user $COMPOSE_CMD -f "$compose_file" up -d`,
  where the word-splitting is intentional (`COMPOSE_CMD` may be `docker compose`).
- **Impact:** Small in practice, and the current floor is a defensible choice —
  raising it to `info` today would add 39 false positives for 1 intentional
  finding. The point worth recording is the scope claim: the gate cannot fail on
  unquoted expansion in a suite that runs as root, so that class is being
  policed by review rather than by CI. The one real instance should carry an
  inline disable so the intent is explicit rather than accidental.
- **Fix:** Annotate the intentional case at `lib/21_deploy.sh:51`, then the
  `info` tier minus the three noisy codes is clean and can be enforced:

```yaml
      - name: ShellCheck (warning + selected info checks)
        run: |
          mapfile -t files < <(find . -type f -name '*.sh' -not -path './.git/*')
          # SC1091: libs are sourced dynamically; SC2153/SC2317: false positives
          # on CONFIG-derived globals and trap/stub functions.
          shellcheck --severity=info -x \
            --exclude=SC1091,SC2153,SC2317 "${files[@]}"
```

---

### [LOW] ShellCheck itself is installed unpinned from apt

**Confidence: 4**

- **Situation:** `ci.yml:18` is `sudo apt-get update && sudo apt-get install -y
  shellcheck`, and `ci.yml:13` is `runs-on: ubuntu-latest`.
- **Behaviour:** The ShellCheck version is whatever the current runner image
  ships. The last run used image `ubuntu-24.04` version 20260823.283.1; the step
  does not print the version, so the log does not record which ShellCheck
  produced the clean result. When `ubuntu-latest` advances (it moved to 24.04
  and will move again), the version changes with no commit in this repo.
- **Impact:** Two directions, both undesirable: a newer ShellCheck adds checks
  and turns an unrelated PR red for reasons its author cannot see in the diff; an
  image change could in principle move the version backwards and quietly weaken
  the gate. This is why I could not fully settle the "is the floor stable"
  question above.
- **Fix:** Print the version so the log is self-describing, at minimum:

```yaml
      - name: Install shellcheck
        run: |
          sudo apt-get update && sudo apt-get install -y shellcheck
          shellcheck --version
```

  A stronger option is the upstream static binary pinned by version, which
  removes the apt dependency entirely — worth doing only if the version churn
  actually bites.

---

### [LOW] `runs-on: ubuntu-latest` in the release workflow

**Confidence: 5**

- **Situation:** `release.yml:16`. This job produces the signed artifacts users
  install.
- **Behaviour:** `ubuntu-latest` is a moving label; the last release ran on
  `ubuntu-24.04` but nothing in the repo says so. The build environment for a
  signed artifact changes without a commit.
- **Impact:** Low for a Bash project, where `setup.sh` is copied rather than
  compiled — but the release also depends on the image's `gh`, `curl`, `python3`
  and `bash` versions (`scripts/pin-digests.sh` uses `python3` and bash 4.4+
  array semantics). A major image bump can break a release at exactly the moment
  it is least convenient.
- **Fix:** Pin the release runner and let CI keep floating so image breakage is
  discovered on PRs first:

```yaml
jobs:
  release:
    runs-on: ubuntu-24.04   # pinned: release artifacts should not float with the runner image
```

---

### [LOW] `tests/distro/test_integration.sh` is never executed by anything

**Confidence: 5**

- **Situation:** `tests/test_runner.sh:74` globs `"$SCRIPT_DIR"/test_*.sh`, which
  is `tests/` only and does not recurse.
- **Behaviour:** `tests/distro/test_integration.sh` and its `Vagrantfile` are
  tracked in git, are linted by `ci.yml:22` (the `find` does recurse), and are
  run by nothing — not CI, not the runner, and there is no documented manual
  command. Nothing in the repo states that it needs Vagrant and is therefore
  excluded on purpose.
- **Impact:** Dead weight that reads as coverage. Someone will assume distro
  integration is tested in CI because a test file for it exists.
- **Fix:** Either wire it into a manual/`workflow_dispatch` path, or add a
  one-line comment at the top of the file stating it requires Vagrant and is
  excluded from the CI runner by design. The comment is the cheaper honest fix.

---

### [LOW] `docs/SUPPLY_CHAIN.md:22` overstates when CI runs

**Confidence: 5**

- **Situation:** The table row reads `Lint + tests | .github/workflows/ci.yml |
  every push / PR`.
- **Behaviour:** `ci.yml:4-5` restricts push to `branches: [main]`. A push to any
  other branch — including `qa/fleet-loop-20260910`, this audit's own branch —
  runs nothing. Neither does a tag push (see the second finding).
- **Impact:** Minor, but it is the documentation that a maintainer will consult
  when deciding whether a branch is covered.
- **Fix:** `every push to main / every PR`.

---

### [LOW] Repo Actions policy does not enforce the pinning discipline the workflows follow

**Confidence: 5** (read from the API)

- **Situation:** Both workflows pin correctly by SHA today, and
  `docs/SUPPLY_CHAIN.md:83` states this as a project rule.
- **Behaviour:** `GET /repos/.../actions/permissions` returns
  `{"enabled":true,"allowed_actions":"all","sha_pinning_required":false}`. The
  rule lives only in the maintainer's habit and in a doc line; a future workflow
  using `uses: some/action@v1` is accepted without complaint.
- **Impact:** Low today, since the discipline is being followed. Turning the
  setting on converts it from convention to policy at zero ongoing cost, which
  is the point of the setting.
- **Fix:** Settings -> Actions -> General -> require SHA pinning. This is a repo
  setting change for the maintainer, not applied by this audit.

---

### [LOW] Both pinned action versions are behind the current major

**Confidence: 5** (release/tag lists read from the API)

- **Situation:** `ci.yml:15` and `release.yml:18` pin `actions/checkout` v6.0.3;
  `release.yml:33` pins `sigstore/cosign-installer` at the current `v3` tag;
  `release.yml:50` pins `actions/attest-build-provenance` v4.1.0;
  `release.yml:27` pins `anchore/sbom-action` v0.24.0.
- **Behaviour:** Latest releases are `actions/checkout` **v7.0.1** (2026-07-20),
  `cosign-installer` **v4.1.2** (2026-05-07), `attest-build-provenance`
  **v4.2.2** (2026-08-06), `sbom-action` **v0.24.2** (2026-08-28). No current pin
  is deprecated, and all use `node24` or `composite`, so there is no forced
  migration pending — this is drift, not breakage.
- **Impact:** None immediately. The `cosign-installer` gap is a full major
  version and the one worth attention, since it determines the cosign binary
  that produces the release bundles.
- **Fix:** Bump deliberately, re-resolving each SHA and keeping the `# vX.Y.Z`
  comment exact rather than the current `# v0` / `# v3` shorthand, which does not
  identify what is pinned. Verify a release end-to-end after the
  `cosign-installer` major bump specifically, since `--new-bundle-format`
  behaviour is the thing that changed across it.

---

### [INFO] No `concurrency` group on either workflow

**Confidence: 5**

- **Situation:** Neither file declares `concurrency:`.
- **Behaviour:** Two pushes in quick succession to `main`, or two rapid pushes to
  a PR branch, run the full job twice with no cancellation.
- **Impact:** Negligible in absolute terms — CI runs take 19-30 seconds. Listed
  for completeness rather than urgency.
- **Fix:** For `ci.yml` only (a release must never be cancelled mid-flight):

```yaml
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
```

---

### [INFO] Every release gets the entire CHANGELOG as its release notes

**Confidence: 5**

- **Situation:** `release.yml:64` is `--notes-file CHANGELOG.md`.
- **Behaviour:** The full 5 KB changelog, all versions, is posted as the notes for
  each individual tag rather than the section for that version.
- **Impact:** Cosmetic. Readers of the v0.2.0 release page see v0.1.0's notes too.
- **Fix:** Either extract the section for `${GITHUB_REF_NAME}` with an awk range,
  or use `--generate-notes` and drop the file. The awk extraction is the more
  faithful option since the changelog is hand-written.

## Verified OK

Checked and found correct; recorded so a future pass does not re-derive them.

- No `pull_request_target`, `workflow_run`, `issue_comment`, `schedule`, or
  `repository_dispatch` trigger in either workflow. No TOCTOU comment-trigger
  surface, no untrusted artifact download, no privileged fork-PR path.
- No `${{ }}` expression of any attacker-controllable value reaches a `run:`
  block in either file. Checked every `run:` step.
- No `secrets.*` reference. No secret can be leaked to a log or artifact,
  because none is present.
- No `continue-on-error`, no `|| true`, no `set +e`, and no pipe that would
  swallow an exit status, in any step of either workflow.
- `permissions:` present at workflow level in both files; the release scopes
  match exactly what `gh release create`, keyless cosign, and
  `attest-build-provenance` require, with nothing spare.
- Both files reference only scripts that exist: `scripts/pin-digests.sh`,
  `scripts/gen-sbom.sh`, `tests/test_runner.sh`, `CHANGELOG.md`, `setup.sh`.
  Confirmed all present and tracked.
- The ShellCheck step's `find` covers the complete shell surface: all 52 `.sh`
  files, and a shebang scan found **zero** extensionless shell scripts that the
  `*.sh` pattern would miss.
- `mapfile -t files < <(find ...)` at `ci.yml:22` is safe under the runner's
  default `bash -e {0}` shell: `mapfile` is a bash builtin, and if the array
  were empty, `shellcheck` with no file operands exits non-zero rather than
  passing vacuously.
- `scripts/pin-digests.sh:113-115` reaches `exit 1` correctly on drift; the
  `(( drift == 0 )) && echo ... || exit 1` chain does not misfire, since the
  `echo` cannot fail into the `||` branch in practice.
- `scripts/pin-digests.sh:52-54` refuses a non-HTTPS token realm, which closes
  the obvious MITM redirect on the registry auth probe. Good instinct, correctly
  implemented.
- `release.yml:61-62` globs match what the signing loop writes:
  `sbom/X.cdx.json` -> `sbom/X.cdx.json.cosign.bundle`, matched by
  `sbom/*.cosign.bundle`.
- The `--certificate-identity` documented at `docs/SUPPLY_CHAIN.md:57` and `:63`
  matches the identity a tag-triggered run of `release.yml` actually asserts.
- Both release runs (v0.1.0, v0.1.1) completed successfully, so
  `cosign sign-blob --new-bundle-format` is empirically working with the pinned
  installer's cosign default — this is runtime evidence, not inference.
- All test files use `set -euo pipefail`; no assertion helper is invoked inside a
  pipeline or command substitution, so no `_TEST_FAILURES` increment is lost to a
  subshell. Grepped for both patterns and found none.

## Completion

**Status:** COMPLETE
**Finished:** 2026-09-10

**Tally:** 2 High, 4 Medium, 6 Low, 2 Info. 14 findings, 0 marked
`UNCERTAIN:` or `UNVERIFIED:`.

The two High findings are the same shape and reinforce each other: the
workflows are well written, but nothing requires them to have passed. Fixing
branch protection and adding `needs: verify` to the release job is most of the
value in this report.

**Not checked, and why:**

- **Fork-PR behaviour in practice.** No `pull_request` run has ever occurred, and
  the brief forbids triggering workflows. Settled only by a real fork PR or an
  `act` run with a fork-shaped event payload.
- **ShellCheck version stability across runner image changes.** The step does not
  print the version, so no log records it. Settled by adding
  `shellcheck --version` to the install step.
- **Whether the SC2153/SC2317 suppressions I recommend are all false positives.**
  I spot-checked several (`CONFIG`-derived globals, stub functions) and they are,
  but I did not review all 11 individually. Deferred to `code-auditor`, which
  owns the script bodies.
- **Deep supply-chain analysis of the container images themselves** (the 17
  pinned digests, their upstream provenance). Out of scope here and owned by
  `dependency-auditor`; this audit verified only that the CI *pinning mechanism*
  is sound.
- **No workflow was triggered, nothing was pushed, and nothing outside
  `docs/qa-review/` was written.** The `test_runner.sh` reproduction ran against
  a throwaway copy in the session scratchpad, which was deleted; `git status`
  confirms the working tree is otherwise clean.
