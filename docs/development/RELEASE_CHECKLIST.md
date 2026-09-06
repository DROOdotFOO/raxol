# Release checklist

The ordered sequence for publishing a Raxol package to Hex. Written for someone
who holds the Hex credentials and the wallet, and who has no other context on
this repo.

Everything here is copy-pasteable and runs from the repository root unless a
step says otherwise. Steps marked **OPERATOR** need a credential, a live
network, or a chain transaction, and cannot be automated or rehearsed offline.

Publishing is close to irreversible. A brand new package can be reverted within
24 hours of its first publish; a new version of an existing package only within
one hour (`mix hex.publish --revert VERSION`). After that the version is
permanent. Read the whole of the section for the package you are publishing
before you run anything.

## What is published today

Twelve packages are on Hex. Six are not. Verified against `mix.exs` in the tree
and the Hex API, not against prose.

| Package                        | In tree      | On Hex | State                                |
| ------------------------------ | ------------ | ------ | ------------------------------------ |
| `raxol`                        | 2.6.1        | 2.6.1  | published, current                   |
| `raxol_core`                   | 2.6.0        | 2.6.0  | published, current                   |
| `raxol_terminal`               | 2.6.1        | 2.6.1  | published, current                   |
| `raxol_agent`                  | 2.6.0        | 2.6.0  | published, current                   |
| `raxol_mcp`                    | 2.6.0        | 2.6.0  | published, current                   |
| `raxol_liveview`               | 2.6.0        | 2.6.0  | published, current                   |
| `raxol_plugin`                 | 2.6.0        | 2.6.0  | published, current                   |
| `raxol_sensor`                 | 2.6.0        | 2.6.0  | published, current                   |
| `raxol_payments`               | 0.2.0        | 0.2.0  | published, current                   |
| `raxol_speech`                 | 0.2.0        | 0.1.0  | published, 0.2.0 pending             |
| `raxol_telegram`               | 0.2.0        | 0.1.0  | published, 0.2.0 pending             |
| `raxol_watch`                  | 0.2.0        | 0.1.0  | published, 0.2.0 pending             |
| `raxol_gateway`                | 0.1.0        | none   | unpublished, ready                   |
| `raxol_symphony`               | 0.2.0        | none   | unpublished, blocked on a live run   |
| `raxol_earn`                   | 0.2.0        | none   | unpublished, blocked on Base mainnet |
| `raxol_cli`                    | 0.2.6        | none   | unpublished, not scheduled           |
| `raxol_console`                | 0.1.0        | none   | unpublished, not scheduled           |
| `raxol_agent_client_protocol`  | 0.1.0-rc.0   | none   | unpublished, not scheduled           |

Two version lines run in parallel: the framework packages on 2.6.x, and the
payment and surface packages on independent 0.x lines. They are not released
together, so a 0.x publish does not require touching the 2.6.x line.

## Publish order is a hard gate, not advice

Read this before you publish anything. Order is forced by inter-package
requirements. Three of the packages below name a version of a sibling that Hex
does not carry yet, so publishing out of order does not degrade gracefully: the
publish aborts, because `HEX_BUILD=1 mix deps.get` cannot resolve the
requirement.

**The three blocking prerequisites.** `raxol_speech`, `raxol_telegram`, and
`raxol_watch` are all 0.2.0 in this tree and 0.1.0 on Hex. Two packages
graduating now declare them at `"~> 0.2"`:

| Publishing        | Requires on Hex first                    | Declared in `mix.exs`                            | If you skip it                              |
| ----------------- | ---------------------------------------- | ------------------------------------------------ | ------------------------------------------- |
| `raxol_gateway`   | `raxol_speech` 0.2.0                     | `raxol_speech "~> 0.2"`, optional                | `HEX_BUILD=1 mix deps.get` cannot resolve   |
| `raxol_symphony`  | `raxol_telegram` 0.2.0, `raxol_watch` 0.2.0 | both `"~> 0.2"`, optional                     | `HEX_BUILD=1 mix deps.get` cannot resolve   |

Optional does not help here. An optional requirement still has to name a
version that exists in the registry.

**The order, top to bottom.** Do not reorder it.

1. **`raxol_speech` 0.2.0**. Prerequisite for `raxol_gateway`. Requires only
   `raxol_core "~> 2.6"`, already on Hex.
2. **`raxol_watch` 0.2.0** and **`raxol_telegram` 0.2.0**. Prerequisites for
   `raxol_symphony`. Independent of each other.
3. **`raxol_gateway` 0.1.0**. Nothing external blocks it once step 1 is done.
4. **`raxol_symphony` 0.2.0**, after step 2 and after its live run
   (see [`raxol_symphony` 0.2.0](#raxol_symphony-020)).
5. **`raxol_earn` 0.2.0**, after its Base mainnet offering
   (see [`raxol_earn` 0.2.0](#raxol_earn-020)). Independent of the other four:
   its only published requirements are `raxol_payments "~> 0.2"`,
   `raxol_core "~> 2.6"`, and `raxol_mcp "~> 2.6"`, all already on Hex at
   satisfying versions. It can go out at any point in this sequence.

**Framework line.** The authoritative order for the 2.6.x packages is the
`@public_packages` list in
[`lib/raxol/release/package_check.ex`](../../lib/raxol/release/package_check.ex):
`raxol_core`, `raxol_sensor`, `raxol_terminal`, `raxol_mcp`, `raxol_liveview`,
`raxol_plugin`, `raxol_speech`, `raxol_watch`, `raxol`, `raxol_agent`,
`raxol_payments`, `raxol_telegram`. `raxol_core` and `raxol_sensor` go first
because they have no raxol requirements. Nothing on that line needs republishing
for this release; every 2.6.x package in the tree matches what is on Hex.

**One requirement is dropped rather than ordered.** `raxol_telegram` also
declares `raxol_gateway`, but its `gateway_dep/0` returns `[]` under
`HEX_BUILD`, so the requirement never reaches the tarball and `raxol_telegram`
does not wait on `raxol_gateway`. That drop becomes unnecessary once
`raxol_gateway` is on Hex; see [after publishing](#after-publishing).

## Gates that must be green first

Run these once, from the repository root, on the commit you intend to publish.

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix credo
mix raxol.check_docs
mix raxol.release.check --all
SKIP_TERMBOX2_TESTS=true MIX_ENV=test mix test
```

`mix raxol.release.check --all` is the release-specific gate. It validates
package metadata, confirms every file a tarball would ship is tracked by git,
and builds each tarball with `HEX_BUILD=1 mix hex.build --unpack` to compare the
generated `hex_metadata.config` against the source project config. It must be
run on a clean tree: `mix hex.build` packages the working tree rather than the
commit, so a green run on a dirty tree says nothing about what would ship. Do
not pass `--allow-untracked` here, which is exactly the check it relaxes.

Two warnings are expected and are not failures:

- `raxol_agent` drops `raxol_agent_client_protocol` from its tarball.
- `raxol_telegram` drops `raxol_gateway` from its tarball.

Both are unpublished packages that cannot appear as a requirement in a public
tarball. The second clears once `raxol_gateway` is on Hex.

Never set `HEX_BUILD` in your shell. The release check refuses to run with an
ambient `HEX_BUILD`, because it sets the variable per subprocess itself, and an
ambient one makes the project config publish-shaped on both sides of its
dependency audit, so the audit compares the tarball against itself and reports
nothing.

## Per-release bookkeeping

For each package you are about to publish, in its directory:

1. **Date the CHANGELOG entry.** An unreleased entry is headed
   `## [X.Y.Z] - unreleased`. Replace `unreleased` with the publish date in
   `YYYY-MM-DD`. This is deliberate: a dated heading for a version that was
   never pushed is a false claim, so the date is written at publish time. If an
   entry already carries a date from an earlier packaging pass and was never
   published, that date is wrong too; replace it.
2. **Tag the commit.** Tags are package-scoped, because the bare `vX.Y.Z` tags
   belong to the root `raxol` version line. `v0.2.0` already exists there and
   points at raxol from 2025. Six packages set `:source_ref` to
   `<package>-v<version>` in their `docs` config and expect that tag:
   `raxol_speech`, `raxol_telegram`, `raxol_watch`, `raxol_gateway`,
   `raxol_earn`, `raxol_symphony`.

   ```bash
   git tag -a raxol_gateway-v0.1.0 -m "raxol_gateway 0.1.0"
   git push origin raxol_gateway-v0.1.0
   ```

   Tag before publishing. The published docs link every module back to this
   tag, and a tag pushed afterwards leaves those links broken in between.

   **Known defect, already shipped.** `raxol_payments` 0.2.0 was published with
   `source_ref: "v0.2.0"`, so every source link in
   `https://raxol-payments.hexdocs.pm/0.2.0` points at the root `raxol` v0.2.0
   tag from 2025 instead of at the payments code. The version itself cannot be
   changed, but Hex documentation has no update window, so the docs are
   repairable: correct `:source_ref` in `packages/raxol_payments/mix.exs`, push
   a `raxol_payments-v0.2.0` tag, then `HEX_BUILD=1 mix hex.publish docs`. It is
   recorded here so nobody re-diagnoses it. The 2.6.x packages share the
   pattern without the symptom: their bare tags (`v2.6.0`, `v2.6.1`) are real
   commits on the same release line as the code they document.
3. **Confirm the docs build.** `mix hex.publish` runs `mix docs` and uploads the
   result, so a docs failure aborts a publish halfway:

   ```bash
   cd packages/<package>
   HEX_BUILD=1 mix deps.get
   HEX_BUILD=1 mix docs
   ```

## Publishing one package

**OPERATOR.** Authenticate once per machine with `mix hex.user auth`, or export
`HEX_API_KEY`. Then, from the package directory:

```bash
cd packages/<package>
HEX_BUILD=1 mix deps.get
HEX_BUILD=1 mix hex.publish --dry-run
HEX_BUILD=1 mix hex.publish
```

`HEX_BUILD=1` is required for every one of those commands. Each package's
`mix.exs` resolves its sibling raxol dependencies as local `path:` deps by
default; `HEX_BUILD=1` switches them to Hex requirements, which is what a
consumer will actually resolve. Without it you publish a tarball whose
requirements point at directories that exist only in this repo.

Inspect what you are about to ship before the real publish:

```bash
HEX_BUILD=1 mix hex.build --unpack
```

That writes the unpacked tarball next to the package and touches no network.

## Package-specific manual gates

### `raxol_gateway` 0.1.0

Nothing external blocks it. It needs `raxol_speech` 0.2.0 on Hex first (see
[publish order is a hard gate](#publish-order-is-a-hard-gate-not-advice)), then
the generic sequence above.

Metadata, license, changelog, docs entry point, and the tarball are all in
place: `HEX_BUILD=1 mix hex.build` produces `raxol_gateway-0.1.0.tar` carrying
`lib/`, `.formatter.exs`, `mix.exs`, `README.md`, `LICENSE.md`, and
`CHANGELOG.md`.

Its only required dependencies are `raxol_core "~> 2.6"`, `telemetry`, and
`jason`. Everything else (`raxol`, `raxol_agent`, `raxol_speech`, `gen_smtp`,
`mint_web_socket`, `req`) is optional and gated at runtime, so a consumer who
wants only the Telegram or in-memory adapter pulls nothing extra.

### `raxol_symphony` 0.2.0

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

### `raxol_earn` 0.2.0

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
should read `0.2.0` and the installation snippet `{:raxol_earn, "~> 0.2"}`.
Both previously described a release candidate that was never cut.

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
