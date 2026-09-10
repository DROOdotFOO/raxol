# Release Hardening Implementation Plan

**Source:** Release follow-up after the first OIDC-published `@raxol/cli` release
**Goal:** Make npm, GitHub Release, Hex, and `curl | bash` releases verifiable, resumable, and independent of unauthenticated GitHub API discovery.

## Context

`@raxol/cli` 0.2.8 proved the end-to-end OIDC publication path and exposed one remaining race: npm accepted packages before they were query-visible. The workflow now waits for platform packages, but it still creates the GitHub Release without proving that a fresh consumer can install and verify the wrapper package. GitHub release tags are also mutable because the repository has no tag ruleset.

The Hex workflow has complete preflight and resumable publishing logic, but it has not yet performed a real automated publication. The shell installer verifies SHA-256 checksums but discovers the latest version through the unauthenticated GitHub Releases API and has no provenance-verification mode.

## Architectural Decisions

1. **Registry state is the release gate.** A CLI GitHub Release is created only after all five npm packages are query-visible and a fresh isolated install of the wrapper succeeds.
2. **Version tags are immutable.** One active GitHub tag ruleset covers `refs/tags/v*` and `refs/tags/raxol-cli-v*`, blocks update and deletion, permits creation, and has no bypass actors. Emergency recovery changes the audited ruleset; it never silently moves a published version tag.
3. **Release approval stays solo-maintainer friendly.** The protected `release` environment continues to allow DROOdotFOO to approve their own deployment.
4. **GitHub artifact attestations are the provenance format.** CLI binaries receive SLSA provenance through `actions/attest@v4`, bound to the release workflow and exact tag ref.
5. **Checksums remain the default installer trust contract.** The dependency-free install path continues to fail closed on a missing or invalid SHA-256 checksum. Provenance verification is explicit through `--verify-provenance`; that mode requires `gh` and fails closed if verification cannot complete.
6. **Latest release discovery uses a cached channel manifest, not the GitHub API.** Each immutable CLI release carries its own manifest. A dedicated `raxol-cli-channel` prerelease carries the mutable `latest.json` pointer, updated only after the immutable release and registry smoke pass. `https://raxol.io/releases/latest.json` fetches that fixed asset URL, serves validated JSON with a short shared-cache TTL and stale-on-error window, and therefore needs no web deployment for each CLI release.
7. **The channel tag is intentionally mutable infrastructure.** It is excluded from the immutable version-tag ruleset. Rollback replaces only the channel manifest with a previously published immutable manifest; binaries and version tags never move.
8. **Hex publication waits for product value.** The first live automated Hex run ships the next substantive release rather than consuming 2.7.1 solely as an automation canary.
9. **Registry credentials do not expand.** npm remains OIDC-only. Hex continues to use the API-write-scoped `HEX_API_KEY` behind the protected environment.

## Phase 1: Close the npm Registry Loop

**Classification:** AFK

### What to Build

Extend `.github/workflows/release-raxol-cli.yml` with a post-publication registry smoke gate:

- Wait for `@raxol/cli@<version>` itself to become query-visible after the four platform packages.
- Install the exact wrapper version using a new temporary prefix and npm cache with online registry resolution forced.
- Execute the installed `raxol --version` and require the released semantic version.
- Run `npm audit signatures` with attestation checks against the isolated install.
- Query every platform package and the wrapper for the expected version and npm provenance metadata.
- Make GitHub Release creation depend on this gate. A resumed tag run must skip already-published versions and still repeat the consumer smoke.

### User-Visible Outcome

A successful CLI release run proves that a clean npm consumer can install and execute the just-published version before GitHub advertises the release.

### Acceptance Criteria

- [ ] A tag run cannot enter the GitHub Release job until all five exact npm versions are query-visible.
- [ ] The smoke uses an empty prefix and cache, installs `@raxol/cli@<version>`, and executes the installed Linux x64 binary successfully.
- [ ] `npm audit signatures` succeeds and all five packuments expose SLSA provenance.
- [ ] Re-running the same tag skips immutable npm versions but repeats and passes the registry smoke.
- [ ] Manual workflow dispatch remains build-only and never publishes.

## Phase 2: Make Release Tags Immutable

**Classification:** HITL - repository security policy

### What to Build

Create an active repository ruleset named `Immutable release tags` through the GitHub rulesets API:

- Target tags matching `refs/tags/v*` and `refs/tags/raxol-cli-v*`.
- Add update and deletion restrictions.
- Do not add a creation restriction; maintainers must still be able to create a new release tag.
- Do not add bypass actors. Keep `raxol-cli-channel` outside the include patterns.
- Record the exact configuration and emergency-disable procedure in `docs/development/RELEASE_CHECKLIST.md`.

GitHub Enterprise-only evaluate mode is not assumed. Validate the request payload before activation, then verify the active configuration through the API without attempting to mutate an existing release tag.

### User-Visible Outcome

Published release identities cannot be retargeted or deleted during normal repository operations.

### Acceptance Criteria

- [ ] The repository exposes one active tag ruleset with the two intended include patterns.
- [ ] The ruleset contains update and deletion restrictions, no creation restriction, and no bypass actor.
- [ ] Existing `v*` and `raxol-cli-v*` tags remain unchanged.
- [ ] `raxol-cli-channel` is not matched by the ruleset.
- [ ] The protected `release` environment still requires approval and permits self-approval.

## Phase 3: Attest Every CLI Binary

**Classification:** HITL - supply-chain security boundary

### What to Build

Add GitHub artifact attestations to the immutable CLI release job:

- Grant only `id-token: write`, `attestations: write`, and the existing minimal contents permission to the job that assembles final release assets.
- Generate `SHA256SUMS` first, then use `actions/attest@v4` with that checksum file as the four-binary subject set.
- Upload the generated Sigstore bundle beside the binaries and checksums in the immutable GitHub Release.
- Verify the bundle in the workflow before publishing assets, requiring the `DROOdotFOO/raxol` repository, `.github/workflows/release-raxol-cli.yml` signer workflow, exact `refs/tags/raxol-cli-v<version>` source ref, GitHub OIDC issuer, and GitHub-hosted runner.
- Add the exact consumer verification command to the release checklist.

### User-Visible Outcome

A consumer can download a released binary and its bundle, then prove which workflow and tag produced that exact digest.

### Acceptance Criteria

- [ ] Every released CLI binary digest is present in a SLSA provenance attestation.
- [ ] The immutable GitHub Release includes the attestation bundle, `SHA256SUMS`, and all four binaries.
- [ ] `gh attestation verify` succeeds with the repository, signer workflow, source ref, and hosted-runner constraints.
- [ ] Verification fails when run against a modified copy of a released binary.
- [ ] No long-lived signing key or new repository secret is introduced.

## Phase 4: Publish a Stable Release Manifest

**Classification:** AFK after the one-time channel release exists

### What to Build

Define a versioned JSON manifest contract and publish it from the CLI release workflow after registry smoke and attestation verification.

Manifest version 1 contains:

- `schema_version`, CLI `version`, immutable `tag`, release timestamp, repository, and signer workflow.
- One entry per supported platform with asset name, immutable download URL, SHA-256 digest, and attestation bundle URL.

For every release:

1. Generate and validate the manifest from the built assets and `SHA256SUMS`.
2. Attach it as `raxol-cli-manifest.json` to the immutable version release.
3. Only after that release succeeds, replace `latest.json` on the dedicated `raxol-cli-channel` prerelease.
4. Add `GET /releases/latest.json` to the raw Phoenix pipeline. Fetch the fixed channel-asset URL, validate the response, honor upstream validators, and serve JSON with `Cache-Control: public, max-age=60, stale-if-error=300` plus an ETag. Keep the last validated manifest available during a transient upstream failure.
5. Document rollback as replacing `latest.json` with the manifest downloaded from a prior immutable release.

### User-Visible Outcome

`curl -fsSL https://raxol.io/releases/latest.json` returns current, machine-readable release metadata without consuming the GitHub Releases API quota.

### Acceptance Criteria

- [ ] The manifest validates against one checked-in schema and covers exactly the four supported platforms.
- [ ] Asset URLs are immutable version-release URLs and every digest matches the downloaded asset.
- [ ] The immutable release receives its manifest before the channel manifest changes.
- [ ] The raxol.io endpoint returns cached JSON from the fixed channel URL, emits an ETag and explicit cache policy, survives a transient upstream failure with the last validated manifest, and never calls the GitHub API or requires a web redeploy.
- [ ] Replacing the channel asset with a prior immutable manifest rolls back discovery without changing a version tag or binary.

## Phase 5: Consume the Manifest and Offer Provenance Verification

**Classification:** HITL - public installer contract

### What to Build

Update `scripts/install.sh` and its public `/install` copy contract:

- Default installs fetch `https://raxol.io/releases/latest.json`; pinned installs fetch `raxol-cli-manifest.json` from the named immutable release.
- Remove latest-version parsing through `api.github.com/repos/.../releases`.
- Validate schema version, semantic version, tag/version agreement, supported platform entry, asset host/path, and SHA-256 shape before downloading a binary.
- Keep checksum verification mandatory and before the atomic install rename.
- Add `--verify-provenance` and `RAXOL_VERIFY_PROVENANCE=1`. This explicit mode requires `gh`, downloads the published bundle, and runs `gh attestation verify` with repository, signer workflow, exact source ref, and hosted-runner constraints before installation.
- Do not silently fall back to the GitHub API. On manifest failure, report the failing URL and explain how to request a pinned version.

### User-Visible Outcome

The normal one-command installer remains dependency-free and checksum-safe. Security-sensitive users can opt into exact workflow provenance verification.

### Acceptance Criteria

- [ ] A live default install resolves the latest version without any request to `api.github.com`.
- [ ] A pinned install resolves only immutable version-release URLs and installs the requested version.
- [ ] Missing, malformed, mismatched, or unsupported manifest data aborts before binary installation.
- [ ] A bad checksum always aborts; the default path never weakens checksum enforcement.
- [ ] Provenance mode fails when `gh` is missing or verification fails, and succeeds for an unmodified attested release binary.

## Phase 6: Add Post-Publish Hex Consumer Verification

**Classification:** AFK

### What to Build

Extend `.github/workflows/release-hex.yml` so GitHub Release creation depends on observable registry consumption, not only successful publish commands:

- Preserve dependency-order publication and skip-if-present resume behavior.
- After publication, query the Hex API for every public package/version expected by the release train.
- Build a fresh temporary Mix consumer that resolves the released root package from Hex with no umbrella path dependencies.
- Poll HexDocs only for newly published package versions, with a bounded timeout and an error naming the package whose docs are unavailable.
- Make the root GitHub Release depend on this verification result.

### User-Visible Outcome

An automated Hex run is successful only when consumers can resolve the release from Hex and the newly published documentation is reachable.

### Acceptance Criteria

- [ ] Dry-run mode performs all preflight checks without publishing or entering registry verification.
- [ ] Publish mode verifies every expected package/version through the public Hex API.
- [ ] A fresh external Mix project resolves and compiles against the released root package.
- [ ] Newly published package documentation becomes reachable before the GitHub Release is created.
- [ ] Re-running a partially completed train skips existing versions and verifies the complete final registry state.

## Phase 7: Ship the First Automated Hex Release

**Classification:** HITL - irreversible registry publication

### What to Build

Use the next substantive Raxol change as the first live automated Hex train:

1. Determine package versions from the actual public API changes; do not assume 2.8.0 until the release diff justifies it.
2. Update every changed package version, changelog date, dependency constraint, documentation source ref, and package metadata together.
3. Run the full release gates from a clean tree and run the reusable Hex workflow with `publish=false` against the exact release commit.
4. Create package-scoped tags only for changed independent-version packages and verify every tag targets the release commit.
5. Create the root `vMAJOR.MINOR.PATCH` tag, approve the protected `release` deployment, and let the workflow publish and verify the train.
6. Confirm the public package pages, HexDocs, fresh consumer project, and GitHub Release. Record the actual versions in the checklist.

### User-Visible Outcome

The next meaningful Raxol release is published to Hex entirely through the protected, resumable workflow and is proven consumable before GitHub announces it.

### Acceptance Criteria

- [ ] Release versions follow SemVer for the actual changes; no automation-only package version is consumed.
- [ ] All changed independent-package tags and the root tag point to the same reviewed release commit.
- [ ] The protected environment approval is recorded before registry writes begin.
- [ ] Every changed public package is visible on Hex and HexDocs, and a fresh consumer compiles successfully.
- [ ] The GitHub Release exists only after the complete Hex registry verification gate passes.

## Rollout Order

```text
Phase 1 npm registry gate ───────────────┐
Phase 2 immutable tags ─────────────────┤
Phase 3 binary attestations ──> Phase 4 manifest publisher ──> Phase 5 installer
Phase 6 Hex consumer gate ───────────────────────────────────> Phase 7 live Hex release
```

Phases 1, 2, 3, and 6 are independent implementation slices. Phase 4 requires the attestation asset contract from Phase 3. Phase 5 requires the public manifest from Phase 4. Phase 7 waits for both Phase 6 and a substantive package change.

## Verification Matrix

| Surface | Proof |
| --- | --- |
| npm | Fresh isolated install, executed version, signature audit, five provenance-bearing packuments |
| Git tags | Active ruleset returned by GitHub API with immutable version patterns and no bypass |
| CLI binaries | `gh attestation verify` constrained to repository, workflow, exact tag ref, and hosted runner |
| Manifest | Schema validation, four digest-matching assets, live raxol.io resolution, rollback exercise |
| Installer | Live latest install, pinned install, checksum failure, provenance success and failure |
| Hex | Public API visibility, fresh external Mix resolution, HexDocs reachability, GitHub Release dependency |

## Explicit Non-Goals

- No second human reviewer requirement.
- No automatic version calculation or automatic release-tag creation.
- No long-lived npm token, signing key, or new package-registry credential.
- No attempt to bootstrap `gh` or Cosign inside the zero-dependency installer.
- No immutable rule for the intentionally mutable `raxol-cli-channel` tag.
- No automation-only Hex version published solely to test the workflow.
