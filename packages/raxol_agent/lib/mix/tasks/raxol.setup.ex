defmodule Mix.Tasks.Raxol.Setup do
  @shortdoc "Connect/validate an LLM provider without the TUI (CI/headless)"

  @moduledoc """
  Headless provider setup — the non-TUI twin of the coding agent's `/login`.

  Use this on CI, in scripts, or on a remote box where `mix raxol.code`'s
  interactive `/login` panel is not reachable. It writes only 1Password
  *references* to `~/.raxol/providers.json` (override with `$RAXOL_PROVIDERS`)
  through the same `Raxol.Agent.Backend.{Credentials, Resolver}` front door
  every surface resolves, so a provider connected here is picked up
  identically by `raxol.code`, `raxol.p`, and the other agent surfaces.

      # show what is connected (and why a provider is not)
      mix raxol.setup
      mix raxol.setup --status

      # connect via an existing 1Password reference (+ optional model)
      mix raxol.setup --provider anthropic \\
        --op op://Employee/Anthropic/api_key --model claude-sonnet-5

      # connect a raw key: creates a 1Password item, stores its reference
      mix raxol.setup --provider openai --api-key sk-... --vault Private

      # sign in through a browser (providers that offer one; opt-in, see below)
      mix raxol.setup --provider openrouter --browser

      # forget a provider's stored reference
      mix raxol.setup --provider openai --remove

  Each connect validates the credential (a token-free model-list call) and
  exits non-zero if it does not authorize, so a CI step fails loudly on a
  bad or expired reference.

  ## Options

    * `--provider` — provider name (`anthropic`, `openai`, `kimi`, `ollama`, ...)
    * `--op`       — an existing `op://Vault/Item/field` reference to store
    * `--api-key`  — a raw key to turn into a 1Password item (needs the `op` CLI)
    * `--model`    — default model to store with the reference
    * `--base-url` — base URL override to store with the reference
    * `--vault`    — 1Password vault for `--api-key` (default `$RAXOL_OP_VAULT` or `Private`)
    * `--browser`  — run the provider's browser sign-in (opens a browser; see below)
    * `--remove`   — delete the provider's stored reference
    * `--status`   — print provider status and exit (default when no action given)

  `--browser` is opt-in rather than the default here, unlike `raxol login`.
  This task is the CI/headless twin, and a build step must never block on a
  browser that will not open. It also needs a browser on THIS machine: the
  sign-in redirect lands on a loopback port.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    case Raxol.Agent.Setup.CLI.run(argv) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end
end
