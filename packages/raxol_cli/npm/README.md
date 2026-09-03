# raxol

Interactive AI agent and TUI toolkit in your terminal, as a self-contained
binary. No Erlang, Elixir, or Node runtime needed at run time.

```bash
npm install -g raxol
raxol            # interactive AI agent
raxol doctor     # what this install resolves: build, providers, config
raxol update     # replace this binary with the latest verified release
raxol playground # component catalog
raxol new my_app # scaffold an app
raxol help
```

Not a Node user? The binary does not need one:

```bash
curl -fsSL https://raxol.io/install | bash
brew install droodotfoo/tap/raxol
```

## Connecting a provider

Without a provider the agent replies with mock output. Connect one:

```bash
raxol login                                  # browser sign-in where offered
raxol setup --provider anthropic --op op://Vault/Item/api_key
raxol setup --status                         # what is connected, and why not
```

A provider key in the environment (`AI_API_KEY`, or `ANTHROPIC_API_KEY` and
friends) is also honoured. `raxol setup` writes only 1Password references to
disk, never a raw key.

If something looks wrong, `raxol doctor` reports the build commit, the runtime,
every provider it can see, and the config it resolved.

`raxol` checks for a newer `raxol-cli-v*` GitHub Release once per day when
started interactively and prompts before installing. `raxol update` runs the
same path on demand: it downloads the matching platform binary, verifies
`SHA256SUMS`, and replaces the installed binary in place. Restart `raxol` after
it reports success. Set `RAXOL_NO_UPDATE_CHECK=1` to disable the entry prompt.

## How this package is put together

`raxol` is a small launcher. The platform binaries ship as separate packages
(`@raxol/cli-darwin-arm64` and friends), declared as `optionalDependencies` with
`os`/`cpu` set, so npm downloads only the one matching your machine rather than
all four. `scripts/pack.sh` builds them from the Burrito output.
