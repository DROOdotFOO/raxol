# @raxol/cli

The Raxol TUI toolkit and agent servers in your terminal, as a self-contained
binary. No Erlang, Elixir, or Node runtime needed at run time.

```bash
npm install -g @raxol/cli
raxol mcp        # serve Raxol apps as MCP tools on stdio
raxol acp        # serve a Raxol agent to ACP editors on stdio
raxol doctor     # what this install is: build, runtime, ACP surface
raxol update     # replace this binary with the latest verified release
raxol playground # component catalog
raxol new my_app # scaffold an app
raxol help
```

Not a Node user? The binary does not need one:

```bash
curl -fsSL https://raxol.io/install | bash
```

To require GitHub Actions provenance as well as the mandatory SHA-256 check,
install the GitHub CLI first, then run:

```bash
curl -fsSL https://raxol.io/install | bash -s -- --verify-provenance
```

If something looks wrong, `raxol doctor` reports the build commit, the
packaging, the runtime, and whether the ACP surface is available.

`raxol playground` checks for a newer `raxol-cli-v*` GitHub Release once per
day when started interactively and prompts before installing. `raxol update` runs the
same path on demand: it downloads the matching platform binary, verifies it
against `SHA256SUMS` and the release's Sigstore provenance (signed by this
repository's release workflow for that tag, checked by `raxol` itself with no
`gh` needed), and replaces the installed binary in place. A release whose
provenance is missing or does not verify is not installed. Restart `raxol`
after it reports success. Set `RAXOL_NO_UPDATE_CHECK=1` to disable the entry
prompt.

## How this package is put together

`raxol` is a small launcher. The platform binaries ship as separate packages
(`@raxol/cli-darwin-arm64` and friends), declared as `optionalDependencies` with
`os`/`cpu` set, so npm downloads only the one matching your machine rather than
all four. `scripts/pack.sh` builds them from the Burrito output.
