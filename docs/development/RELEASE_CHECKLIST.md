# Release checklist

Release process for the public Hex train and the `@raxol/cli` npm package.
Publishing is close to irreversible: a new Hex version has a one-hour update
window, and an npm version cannot be reused.

## State for 2.8.0

The release pull request did steps 1 to 4 of "Prepare the release commit".
What remains, in order: the one-time prerequisites below, step 5, step 6 (on
the merge commit), "Publish the public Hex train", and the `raxol_gateway`
0.2.0 block. npm and the CLI are not part of this release: skip
"Publish the npm CLI" and the npm half of "Registry verification".

## One-time prerequisites

- `HEX_API_KEY` lives in the `release` environment, not in repository
  secrets, so only an approved job can read it:

  ```bash
  gh secret set HEX_API_KEY --env release -R DROOdotFOO/raxol
  gh secret delete HEX_API_KEY -R DROOdotFOO/raxol
  ```

  The workflow also accepts a repository secret, which `release.yml` passes
  explicitly; the environment's copy wins when both exist.
- "Allow GitHub Actions to create and approve pull requests" is on (Settings,
  Actions, General), so `llms-sync` can open its pull request.
- Your hex.pm account has two-factor authentication: the first release of a
  new package is held until you approve it there.

## Published surfaces

| Package | Registry | Current version |
| --- | --- | --- |
| `raxol` | Hex | 2.7.0 |
| `raxol_core` | Hex | 2.7.0 |
| `raxol_sensor` | Hex | 2.7.0 |
| `raxol_journal` | Hex | unpublished |
| `raxol_terminal` | Hex | 2.7.0 |
| `raxol_mcp` | Hex | 2.7.0 |
| `raxol_liveview` | Hex | 2.7.0 |
| `raxol_plugin` | Hex | 2.7.0 |
| `raxol_agent` | Hex | 2.7.0 |
| `raxol_speech` | Hex | 0.2.1 |
| `raxol_watch` | Hex | 0.2.1 |
| `raxol_payments` | Hex | 0.2.1 |
| `raxol_telegram` | Hex | 0.2.1 |
| `raxol_gateway` | Hex | 0.2.0 |
| `@raxol/cli` and four `@raxol/cli-*` binaries | npm | 0.2.10 |

`raxol_agent` and `raxol_payments` are on Hex and off the train: a root tag
publishes neither, and `Raxol.Release.PackageCheck.public_packages/0` holds no
agent-side package (ADR-0043). The following projects are unpublished and
outside the train: `raxol_agent_client_protocol`, `raxol_earn`, `raxol_cli`,
`raxol_console`, `raxol_web3`, and `raxol_broker`.
Package-specific gates for the candidates closest to publication remain below.

## Authorization model

The release commit and immutable version tag define what can ship. Registry
jobs run only after approval in the protected GitHub `release` environment.
That environment accepts the root `v*` tags, `raxol-cli-v*` tags, and approved
manual resumes from `master`.

- Hex uses `HEX_API_KEY` from the `release` environment; keep it scoped to API
  write. Only the key check and the publish step see it.
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
2. For each package the train publishes for the first time, which is each
   name in `@awaiting_first_publish` in
   `web/test/raxol_playground/capabilities_test.exs`:
   - Set its version to the train's. Its `source_ref` is the root tag of its
     own version, and no earlier tag contains its directory.
   - Move every requirement on it to that version: each dependant's
     `mix.exs`, the install line in its README and its row in
     `docs/PACKAGES.md`, which also gains the Hex link. For `raxol_journal`
     the dependants are `raxol_agent` and `raxol_broker`.
   - Add it to `@published` in `web/lib/raxol_playground/capabilities.ex` and
     remove it from `@awaiting_first_publish`, so the `llms.txt` generated
     from the tag lists it.
3. Date each released package's changelog entry.
4. Run the release gates from a clean tree:

   ```bash
   mix compile --warnings-as-errors
   mix format --check-formatted
   ./scripts/check-quality-ratchet.sh --gate credo
   mix raxol.check_docs
   mix raxol.release.check
   SKIP_TERMBOX2_TESTS=true MIX_ENV=test mix test --exclude integration
   ```

   Without `--exclude integration` the suite needs PostgreSQL.

   `mix raxol.release.check` validates the public train, proves every packaged
   file is tracked, runs each `HEX_BUILD=1 mix hex.build --unpack`, and compares
   the generated package metadata with the source project configuration.
   `Raxol.Release.PackageCheck` holds the train order; a new package under
   `packages/` fails the catalog check until it is classified there.
5. Validate the merge commit before tagging, from a clean checkout of
   `master`:

   ```bash
   git fetch origin
   git switch --detach origin/master
   git status --short                # empty
   git log -1 --format='%H %s'       # the release pull request's merge commit
   mix deps.get --check-locked
   mix raxol.release.check
   (cd packages/raxol_core && HEX_BUILD=1 mix hex.publish --dry-run --yes)   # sends nothing
   ```

6. Tag that commit. Create the root tag first, then the package-scoped
   documentation tags of the changed independent-version packages on the same
   commit, check, and push the four tags by name (never `--tags`):

   ```bash
   git tag -a v2.8.0 -m "Raxol 2.8.0" HEAD
   git tag -a raxol_speech-v0.3.0 -m "raxol_speech 0.3.0" 'v2.8.0^{commit}'
   git tag -a raxol_watch-v0.3.0 -m "raxol_watch 0.3.0" 'v2.8.0^{commit}'
   git tag -a raxol_telegram-v0.3.0 -m "raxol_telegram 0.3.0" 'v2.8.0^{commit}'
   git rev-parse 'v2.8.0^{commit}' origin/master   # two identical lines
   git push origin raxol_speech-v0.3.0 raxol_watch-v0.3.0 raxol_telegram-v0.3.0
   ```

   Create only the tags for packages whose version changed. Framework packages
   use the root `vMAJOR.MINOR.PATCH` source ref. The validate job refuses a tag
   that is not on `master`.

Never export `HEX_BUILD` globally. The release check and publisher set it only
for package subprocesses; an ambient value strips root path dependencies before
the checker can compare development and publish configurations.

## Publish the public Hex train

Push the root tag:

```bash
git push origin v2.8.0
```

`.github/workflows/release.yml` then:

1. calls the reusable `release-hex.yml` preflight on `refs/tags/v2.8.0`;
2. checks that the tag is on `master` and matches the root Mix project version,
   and records its commit for the later jobs;
3. runs `mix raxol.release.check`;
4. waits for approval: open the run under Actions, "Review deployments",
   tick `release`, approve;
5. publishes `Raxol.Release.PackageCheck.public_packages/0` in dependency
   order, skipping versions already on Hex. At `raxol_journal`, a new
   package, hex.pm holds the release for approval: the log prints
   "Package staged for approval at <url>". Open it and approve with your
   second factor; the job waits (`--wait`) and continues;
6. verifies every package through the public Hex API, waits for newly published
   HexDocs, and compiles a clean consumer against the released root package;
7. creates the GitHub Release only after consumer verification succeeds; and
8. regenerates `llms.txt` from the tag and opens the `bot/llms-sync` pull
   request against `master`.

Validate or resume an existing tag manually (after it is pushed):

```bash
gh workflow run release-hex.yml \
  -f release_ref=v2.8.0 \
  -f publish=false

# Set publish=true only to resume a failed train. Approval is still required.
```

"Re-run failed jobs" on the tag's own run resumes the train and keeps the
`llms.txt` pull request and the GitHub Release. A dispatched resume runs neither:
afterwards run `gh workflow run llms-sync.yml -f release_ref=v2.8.0` and create
the Release by hand.

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

### A package outside the train

A package that is not on the train is published by hand, from a release
commit, with the steps the train runs for each package, after every package it
requires is on Hex. `raxol_gateway` 0.2.0 was published this way, from
`v2.8.0`, and is now on the train; the commands below are that publish.

It needs a local Hex login (`mix hex.user auth`) and the tags fetched. Its docs
link to the `<package>-v<version>` tag, so push that first. hex.pm holds the
first release of a new package until you approve it; `--wait` blocks until
then:

```bash
git fetch origin --tags
git tag -a raxol_gateway-v0.2.0 -m "raxol_gateway 0.2.0" 'v2.8.0^{commit}'
git push origin raxol_gateway-v0.2.0
git switch --detach v2.8.0

cd packages/raxol_gateway
HEX_BUILD=1 mix deps.get
HEX_BUILD=1 mix hex.publish --dry-run --yes
HEX_BUILD=1 mix hex.publish --wait
git checkout -- mix.lock
cd ../..
git switch -
```

`HEX_BUILD=1 mix deps.get` locks the path siblings as Hex packages, which
`scripts/check_lock_path_shadows.exs` rejects, so the lockfile is restored and
never committed in that state.

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
   positioned after everything it requires, and change its `class:` from
   `:pre_alpha` to `:public`. Until you do, the checker treats it as off-train
   and reports any sibling that depends on it as dropping the requirement. Add
   it to `@published` in
   [`web/lib/raxol_playground/capabilities.ex`](../../web/lib/raxol_playground/capabilities.ex)
   in the same change; a `web` test holds `@published` equal to the train,
   less `@awaiting_first_publish`, plus the `@off_train` packages it names.
2. **Declare requirements that used to be dropped.** A sibling that omits its
   requirement on the package under `HEX_BUILD`, because Hex could not resolve
   it, declares it now, optional if the source form is. `raxol_telegram`'s
   optional `raxol_gateway "~> 0.2"` is the example. `mix raxol.release.check`
   warns about each dropped requirement.
3. **Update the state tables.** The table at the top of this file, the
   equivalent in [`docs/PACKAGES.md`](../PACKAGES.md), and the release paragraph
   in [`ROADMAP.md`](../../ROADMAP.md) all name published versions and go stale
   the moment a publish lands.
4. **Verify the docs.** `https://hexdocs.pm/<package>/<version>/` should resolve, and a
   module source link should land on the `<package>-v<version>` tag you pushed.
5. **Merge the `llms.txt` pull request.** `bot/llms-sync` is opened with the
   workflow token, which starts no CI: close and reopen it, then merge it once
   green.
6. **One follow-up pull request** carries items 1 to 3 for the package.
   Optionally turn staged publishing off for `raxol_journal` and
   `raxol_gateway` in their hex.pm settings; the workflow waits either way.
