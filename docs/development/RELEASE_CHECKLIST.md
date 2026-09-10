# Release checklist

Release process for the public Hex train and the `@raxol/cli` npm package.
Publishing is close to irreversible: a new Hex version has a one-hour update
window, and an npm version cannot be reused.

## Published surfaces

| Package | Registry | Current version |
| --- | --- | --- |
| `raxol` | Hex | 2.7.0 |
| `raxol_core` | Hex | 2.7.0 |
| `raxol_sensor` | Hex | 2.7.0 |
| `raxol_terminal` | Hex | 2.7.0 |
| `raxol_mcp` | Hex | 2.7.0 |
| `raxol_liveview` | Hex | 2.7.0 |
| `raxol_plugin` | Hex | 2.7.0 |
| `raxol_agent` | Hex | 2.7.0 |
| `raxol_speech` | Hex | 0.2.1 |
| `raxol_watch` | Hex | 0.2.1 |
| `raxol_payments` | Hex | 0.2.1 |
| `raxol_telegram` | Hex | 0.2.1 |
| `@raxol/cli` and four `@raxol/cli-*` binaries | npm | 0.2.10 |

The following projects remain outside the public Hex train:
`raxol_agent_client_protocol`, `raxol_gateway`, `raxol_earn`,
`raxol_symphony`, `raxol_cli`, and `raxol_console`. Package-specific gates for
the candidates closest to publication remain below.

## Authorization model

The release commit and immutable version tag define what can ship. Registry
jobs run only after approval in the protected GitHub `release` environment.
That environment accepts the root `v*` tags, `raxol-cli-v*` tags, and approved
manual resumes from `master`.

- Hex uses the repository `HEX_API_KEY`; keep it scoped to API write.
- npm uses OIDC-only GitHub Actions trusted publishing and emits provenance.
  All five packages trust `release-raxol-cli.yml` with environment `release`.
- Every publisher checks the registry first, so a failed train can resume
  without trying to overwrite versions that already exist.

The active `Immutable release tags` repository ruleset blocks updates and
deletions for `v*` and `raxol-cli-v*` tags, with no bypass actor. It deliberately
does not block creation. Emergency recovery requires temporarily disabling the
ruleset in repository settings, performing the audited repair, and immediately
reactivating it. Never move a published version tag as routine recovery.

## Prepare the release commit

1. Bump the package versions that are changing.
2. Date each released package's changelog entry.
3. Run the release gates from a clean tree:

   ```bash
   mix compile --warnings-as-errors
   mix format --check-formatted
   mix credo
   mix raxol.check_docs
   mix raxol.release.check
   SKIP_TERMBOX2_TESTS=true MIX_ENV=test mix test
   ```

   `mix raxol.release.check` validates the public train, proves every packaged
   file is tracked, runs each `HEX_BUILD=1 mix hex.build --unpack`, and compares
   the generated package metadata with the source project configuration.
4. Push package-scoped documentation tags for changed independent-version
   packages. They must point at the release commit:

   ```bash
   git tag -a raxol_speech-v0.2.2 -m "raxol_speech 0.2.2"
   git tag -a raxol_watch-v0.2.2 -m "raxol_watch 0.2.2"
   git tag -a raxol_payments-v0.2.2 -m "raxol_payments 0.2.2"
   git tag -a raxol_telegram-v0.2.2 -m "raxol_telegram 0.2.2"
   git push origin raxol_speech-v0.2.2 raxol_watch-v0.2.2 \
     raxol_payments-v0.2.2 raxol_telegram-v0.2.2
   ```

   Create only the tags for packages whose version changed. Framework packages
   use the root `vMAJOR.MINOR.PATCH` source ref.

Never export `HEX_BUILD` globally. The release check and publisher set it only
for package subprocesses; an ambient value strips root path dependencies before
the checker can compare development and publish configurations.

## Publish the public Hex train

Create and push the root tag after the release commit is on `master`:

```bash
git tag -a v2.8.0 -m "Raxol 2.8.0"
git push origin v2.8.0
```

`.github/workflows/release.yml` then:

1. calls the reusable `release-hex.yml` preflight on the exact tag;
2. verifies `v2.8.0` matches the root Mix project version;
3. runs `mix raxol.release.check`;
4. waits for `release` environment approval;
5. publishes `Raxol.Release.PackageCheck.public_packages/0` in dependency
   order, skipping versions already on Hex;
6. verifies every package through the public Hex API, waits for newly published
   HexDocs, and compiles a clean consumer against the released root package; and
7. creates the GitHub Release only after consumer verification succeeds.

Validate or resume an existing tag manually:

```bash
gh workflow run release-hex.yml \
  -f release_ref=v2.8.0 \
  -f publish=false

# Set publish=true only to resume a failed train. Approval is still required.
```

## Publish the npm CLI

The npm version in `packages/raxol_cli/npm/package.json` and the CLI Mix project
version must already agree. Create the matching tag:

```bash
git tag -a raxol-cli-v0.2.10 -m "raxol CLI 0.2.10"
git push origin raxol-cli-v0.2.10
```

`.github/workflows/release-raxol-cli.yml` rejects a mismatched tag before doing
native builds. It builds and smokes Linux x64, Linux arm64, macOS arm64, and
Windows x64; assembles the npm tarballs; waits for `release` approval; publishes
the four platform packages and wrapper; and then proves a fresh, isolated npm
install with signature auditing. The workflow attests the four binaries, uploads
the checksums, Sigstore bundle, and release manifest to the immutable GitHub
Release, then updates the separate `raxol-cli-channel` manifest.

A manual workflow run builds tarball artifacts but does not publish. Re-run a
failed tag job to resume publication; already-published npm versions are skipped
but the registry smoke still runs.

## Registry verification

After approval and completion:

```bash
mix hex.info raxol 2.8.0
npm view @raxol/cli@0.2.10 version dist.integrity

tmp="$(mktemp -d)"
npm install --prefix "$tmp" @raxol/cli@0.2.10
"$tmp/node_modules/.bin/raxol" --version
(cd "$tmp" && npm audit signatures)

curl -fsSL https://raxol.io/releases/latest.json

install_dir="$(mktemp -d)"
curl -fsSL https://raxol.io/install |
  RAXOL_INSTALL_DIR="$install_dir" bash
"$install_dir/raxol" --version

verified_dir="$(mktemp -d)"
curl -fsSL https://raxol.io/install |
  RAXOL_INSTALL_DIR="$verified_dir" \
  RAXOL_VERIFY_PROVENANCE=1 bash
"$verified_dir/raxol" --version
```

The default installer always checks SHA-256. Provenance mode additionally
requires `gh` and verifies the GitHub repository, release workflow, exact tag
ref, OIDC issuer, and hosted runner before installation.

To roll latest discovery back without changing a version tag, download
`raxol-cli-manifest.json` from the prior immutable release, rename it
`latest.json`, and upload it to `raxol-cli-channel` with `gh release upload
raxol-cli-channel latest.json --clobber`.

## Package-specific manual gates

### `raxol_gateway` 0.1.1

Nothing external blocks it. `raxol_speech` 0.2.1 and the 2.7 framework line are
already on Hex, so its registry requirements resolve.

Metadata, license, changelog, docs entry point, and the tarball are in place:
`HEX_BUILD=1 mix hex.build` produces `raxol_gateway-0.1.1.tar` carrying `lib/`,
`.formatter.exs`, `mix.exs`, `README.md`, `LICENSE.md`, and `CHANGELOG.md`.

Its only required dependencies are `raxol_core "~> 2.7"`, `telemetry`, and
`jason`. Everything else (`raxol`, `raxol_agent`, `raxol_speech`, `gen_smtp`,
`mint_web_socket`, `req`) is optional and gated at runtime, so a consumer who
wants only the Telegram or in-memory adapter pulls nothing extra.

### `raxol_symphony` 0.2.1

**OPERATOR.** Blocked on driving at least one real tracker issue to a pull
request and capturing the evidence. The full procedure is
[`packages/raxol_symphony/RUNBOOK.md`](../../packages/raxol_symphony/RUNBOOK.md).
The short form:

1. `GITHUB_TOKEN` with `repo` scope on the target repo, plus a backend key for
   the runner (for example `ANTHROPIC_API_KEY`). `git` and `gh` on `PATH`.
2. Apply the `state/todo` label to one or two low-risk issues only. The
   orchestrator dispatches nothing without a label matching
   `tracker.active_states`, so the label set is the blast radius.
3. Write `WORKFLOW.md` (template in the runbook) and start the orchestrator:
   `{:ok, _} = Raxol.Symphony.Supervisor.start_link(workflow_path: "WORKFLOW.md")`.
   Watch it with `Raxol.Symphony.Orchestrator.snapshot()`.
4. Capture the PR URL, the CI status, and the asciicast fragments under
   `<workspace>/.raxol_symphony/`. `Raxol.Symphony.Evidence.collect/2`
   aggregates them.
5. Then publish.

Why it cannot be rehearsed: the runbook's own offline path proves the
orchestrator, the runners, and the pause and resume loop against mocks, and the
test suite covers all of it. What only a live run can pin is the tracker's real
field names and phase encoding, and that a paused run resumes against a real
repository rather than a fixture.

### `raxol_earn` 0.2.1

**OPERATOR.** Blocked on a live offering on Base mainnet. The full procedure is
[`packages/raxol_earn/RUNBOOK.md`](../../packages/raxol_earn/RUNBOOK.md), which
takes the `custom_console_agent` offering from a clean checkout to a funded,
registered seller on Base Sepolia (chain 84532) and then promotes it to mainnet
(8453). In order:

1. **Identity and funding**, through the Virtuals `acp` CLI and dashboard:
   `acp configure`, `acp agent create`, `acp agent add-signer`, then fund the
   wallet (`acp wallet topup --chain-id 84532` plus a Base Sepolia gas faucet).
   Keys come from `Raxol.Payments.Wallets.Env` or `.Op`, never a literal.
2. **Configure the seller** from `config/console_offering.example.exs`. Sepolia
   needs `seller_chain_id: 84_532` explicitly, because the queue defaults to
   8453.
3. **Register the offering** and upload the result in the dashboard:

   ```bash
   cd packages/raxol_earn
   mix earn.register_offering --offering console --pretty --out console_offering.json
   ```

4. **Offline rehearsal**, no funds and no network. This is the M1 acceptance
   gate: both suites inject a crash between handler-return, sign, and mirror,
   and assert exactly one on-chain submit through to completion.

   ```bash
   cd packages/raxol_earn
   MIX_ENV=test mix test test/raxol/earn/console/ \
     test/raxol/earn/job_session/provider_checkpoint_test.exs \
     test/raxol/earn/seller/resync_recovery_test.exs
   mix raxol_earn.bench
   ```

5. **Live dry-run on Sepolia**, with a scripted mock buyer driving
   `HookClient.create_job`, `fund`, and `complete` against the registered
   offering. Kill the BEAM between funded, submit, and complete, restart, and
   confirm it resumes without a second submit or charge.
6. **Promote to mainnet**: `seller_chain_id: 8453`, `api.acp.virtuals.io`,
   canonical Circle USDC (drop the `chain_overrides` block), and a durable
   checkpoint store with `require_checkpoint: true`. Re-run step 3 against the
   mainnet dashboard.
7. Then publish.

Why it cannot be rehearsed: the offline path proves the state machine, the
checkpoint, and the resync recovery. What only the live run can pin is the
`get_active_jobs` field names and phase encoding that `Seller.Resync`
normalizes, and that the job-id form is consistent between the REST API and the
Socket.IO relayer, which is what makes session keys match across the two
planes.

Before publishing, confirm the version claims in
`packages/raxol_earn/README.md` still agree with `mix.exs`: the status line
should read `0.2.1` and the installation snippet `{:raxol_earn, "~> 0.2"}`.

## After publishing

1. **Add the package to the release train.** Move its entry from
   `@pre_alpha_packages` to `@public_packages` in
   [`lib/raxol/release/package_check.ex`](../../lib/raxol/release/package_check.ex),
   positioned after everything it requires. Until you do, the checker treats it
   as off-train and reports any sibling that depends on it as dropping the
   requirement.
2. **Declare requirements that used to be dropped.** Once `raxol_gateway` is on
   Hex, `raxol_telegram`'s `gateway_dep/0` can declare
   `raxol_gateway "~> 0.1", optional: true` under `HEX_BUILD` instead of
   returning `[]`. That removes the documented
   `mix deps.compile raxol_telegram --force` ordering hazard for consumers who
   add `raxol_gateway` themselves, and it clears the expected warning from
   `mix raxol.release.check`.
3. **Update the state tables.** The table at the top of this file, the
   equivalent in [`docs/PACKAGES.md`](../PACKAGES.md), and the release paragraph
   in [`ROADMAP.md`](../../ROADMAP.md) all name published versions and go stale
   the moment a publish lands.
4. **Verify the docs.** `https://<package>.hexdocs.pm` should resolve, and a
   module source link should land on the `<package>-v<version>` tag you pushed.
