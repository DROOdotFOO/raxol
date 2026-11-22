# Release checklist

Release process for the public Hex train. Publishing is close to
irreversible: a new Hex version has a one-hour update window.

2.8.0 is published: the Hex train, `raxol_gateway` 0.2.0, and the `v2.8.0`
GitHub Release. This line and the table below record what is on Hex, and are
updated after a publish (see "After publishing"), not when a release is
prepared.

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
| `raxol` | Hex | 2.8.0 |
| `raxol_core` | Hex | 2.8.0 |
| `raxol_sensor` | Hex | 2.8.0 |
| `raxol_journal` | Hex | 2.8.0 |
| `raxol_terminal` | Hex | 2.8.0 |
| `raxol_mcp` | Hex | 2.8.0 |
| `raxol_liveview` | Hex | 2.8.0 |
| `raxol_plugin` | Hex | 2.8.0 |
| `raxol_speech` | Hex | 0.3.0 |
| `raxol_watch` | Hex | 0.3.0 |
| `raxol_telegram` | Hex | 0.3.0 |
| `raxol_gateway` | Hex | 0.2.0 |

The agent packages, `@raxol/cli` included, release from
[raxol-agent](https://github.com/DROOdotFOO/raxol-agent);
`Raxol.Release.PackageCheck.public_packages/0` holds none of them (ADR-0043).

## Authorization model

The release commit and immutable version tag define what can ship. Registry
jobs run only after approval in the protected GitHub `release` environment.
That environment accepts the root `v*` tags and approved manual resumes from
`master`.

- Hex uses `HEX_API_KEY` from the `release` environment; keep it scoped to API
  write. Only the key check and the publish step see it.
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
     `docs/PACKAGES.md`, which also gains the Hex link.
   - Add it to `@published` in `web/lib/raxol_playground/capabilities.ex` and
     remove it from `@awaiting_first_publish`, so the `llms.txt` generated
     from the tag lists it.
3. Date each released package's changelog entry.
4. Make sure the scheduled Hex Advisories job (`security.yml`) is green on
   `master`, or that the pull request moving the locks past its advisories
   merges first: the release workflow does not run `mix hex.audit`, so a tag
   would otherwise ship from a commit whose locks the job flags.
5. Run the release gates from a clean tree:

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
6. Validate the merge commit before tagging, from a clean checkout of
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

7. Tag that commit. Create the root tag first, then the package-scoped
   documentation tags of the changed independent-version packages on the same
   commit, check, and push the package tags by name (never `--tags`). The
   train skips a version already on Hex, so edits to an independent-version
   package's `mix.exs` since its last tag reach Hex only when its version is
   bumped. 2.9.1 changes only `raxol_core` and `raxol`, so it needs the root
   tag alone, and no package tags. Push the `v2.9.1` tag (see "Publish the
   public Hex train" below) only once no other release run is publishing
   (`gh run list --workflow release.yml`): runs are grouped by tag, so a
   second train would publish the same not-yet-live versions from its own
   tree and race the first:

   ```bash
   git tag -a v2.9.1 -m "Raxol 2.9.1" HEAD
   git rev-parse 'v2.9.1^{commit}' origin/master   # two identical lines
   ```

   For reference (already done; do not rerun), 2.9.0 patch-bumped
   `raxol_speech`, `raxol_watch`, `raxol_telegram` and `raxol_gateway` for
   their `~> 2.9` requirements:

   ```bash
   git tag -a v2.9.0 -m "Raxol 2.9.0" HEAD
   git tag -a raxol_speech-v0.3.1 -m "raxol_speech 0.3.1" 'v2.9.0^{commit}'
   git tag -a raxol_watch-v0.3.1 -m "raxol_watch 0.3.1" 'v2.9.0^{commit}'
   git tag -a raxol_telegram-v0.3.1 -m "raxol_telegram 0.3.1" 'v2.9.0^{commit}'
   git tag -a raxol_gateway-v0.2.1 -m "raxol_gateway 0.2.1" 'v2.9.0^{commit}'
   git rev-parse 'v2.9.0^{commit}' origin/master   # two identical lines
   git push origin raxol_speech-v0.3.1 raxol_watch-v0.3.1 raxol_telegram-v0.3.1 raxol_gateway-v0.2.1
   ```

   When a release does have package tags, push the root tag last: it starts
   the release workflow, whose HexDocs `source_ref` links need the package
   tags to exist.

   2.8.0 also bumped `raxol_speech`, `raxol_watch` and `raxol_telegram`, and
   tagged each on the root tag's commit before pushing them:

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
git push origin v2.9.1
```

`.github/workflows/release.yml` then:

1. calls the reusable `release-hex.yml` preflight on `refs/tags/v2.9.1`;
2. checks that the tag is on `master` and matches the root Mix project version,
   and records its commit for the later jobs;
3. runs `mix raxol.release.check`;
4. waits for approval: open the run under Actions, "Review deployments",
   tick `release`, approve;
5. publishes `Raxol.Release.PackageCheck.public_packages/0` in dependency
   order, skipping versions already on Hex. hex.pm can hold a release for
   approval, a package new to Hex or not (`raxol_journal` 2.9.0 was held,
   with 2.8.0 already published): the log prints "Package staged for approval
   at <url>", but GitHub shows a running job's log only after it ends, so
   keep `https://hex.pm/dashboard/staged-releases` open while the train
   publishes. Approve with your second factor; the job waits (`--wait`) and
   continues. Unapproved, it waits out the step's 180-minute timeout and
   fails;
6. verifies every package through the public Hex API, waits for newly published
   HexDocs, and compiles a clean consumer against the released root package;
7. creates the GitHub Release only after consumer verification succeeds; and
8. regenerates `llms.txt` from the tag and opens the `bot/llms-sync` pull
   request against `master`.

Validate or resume an existing tag manually (after it is pushed):

```bash
gh workflow run release-hex.yml \
  -f release_ref=v2.9.1 \
  -f publish=false

# Set publish=true only to resume a failed train. Approval is still required.
```

"Re-run failed jobs" on the tag's own run resumes the train and keeps the
`llms.txt` pull request and the GitHub Release. A dispatched resume runs neither:
afterwards run `gh workflow run llms-sync.yml -f release_ref=v2.9.1` and create
the Release by hand.

## Registry verification

After approval and completion:

```bash
mix hex.info raxol 2.9.1
mix hex.info raxol_core 2.9.1   # 2.9.1 carries its fix in raxol_core
```

2.9.1 is a security fix that `mix deps.update raxol` does not pull: the
family requirement stays `raxol_core ~> 2.9`, so a locked 2.9.0 is kept.
Once 2.9.1 is live, retire 2.9.0 so every resolver still on it is warned
(owner, with the Hex key):

```bash
mix hex.retire raxol_core 2.9.0 security --message "Child processes inherit more credentials; update to 2.9.1"
```

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

## After publishing

1. **List the package on the site.** Add it to `@published` in
   [`web/lib/raxol_playground/capabilities.ex`](../../web/lib/raxol_playground/capabilities.ex)
   and drop it from `@awaiting_first_publish` in that module's test, which
   holds `@published` equal to the train in
   [`lib/raxol/release/package_check.ex`](../../lib/raxol/release/package_check.ex),
   less `@awaiting_first_publish`, plus the `@off_train` packages it names.
2. **Update the state tables.** The table at the top of this file, the
   equivalent in [`docs/PACKAGES.md`](../PACKAGES.md), and the release paragraph
   in [`ROADMAP.md`](../../ROADMAP.md) all name published versions and go stale
   the moment a publish lands.
3. **Verify the docs.** `https://hexdocs.pm/<package>/<version>/` should resolve, and a
   module source link should land on the `<package>-v<version>` tag you pushed.
4. **Merge the `llms.txt` pull request.** `bot/llms-sync` is opened with the
   workflow token, which starts no CI: close and reopen it, then merge it once
   green.
5. **One follow-up pull request** carries items 1 and 2 for the package.
   Optionally turn staged publishing off for `raxol_journal` and
   `raxol_gateway` in their hex.pm settings; the workflow waits either way.
