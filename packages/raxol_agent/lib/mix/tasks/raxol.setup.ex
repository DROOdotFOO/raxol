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
    * `--remove`   — delete the provider's stored reference
    * `--status`   — print provider status and exit (default when no action given)
  """

  use Mix.Task

  alias Raxol.Agent.Setup

  @switches [
    provider: :string,
    op: :string,
    api_key: :string,
    model: :string,
    base_url: :string,
    vault: :string,
    remove: :boolean,
    status: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} ->
        dispatch(opts)

      {_opts, _args, invalid} ->
        usage_error("unknown options: #{inspect(invalid)}")
    end
  end

  defp dispatch(opts) do
    provider = Keyword.get(opts, :provider)

    cond do
      Keyword.get(opts, :status, false) or no_action?(opts) ->
        print_status()

      is_nil(provider) ->
        usage_error("--provider is required for that action")

      Keyword.get(opts, :remove, false) ->
        do_remove(provider)

      Keyword.get(opts, :op) ->
        do_connect_ref(provider, opts)

      Keyword.get(opts, :api_key) ->
        do_connect_key(provider, opts)

      true ->
        usage_error("give one of --op, --api-key, or --remove for #{provider}")
    end
  end

  defp no_action?(opts) do
    not Enum.any?(
      [:op, :api_key, :remove, :provider],
      &Keyword.has_key?(opts, &1)
    )
  end

  # -- actions ----------------------------------------------------------------

  defp do_connect_ref(provider, opts) do
    attrs = %{
      op_ref: opts[:op],
      model: opts[:model],
      base_url: opts[:base_url]
    }

    provider
    |> Setup.connect_ref(attrs)
    |> report_connect()
  end

  defp do_connect_key(provider, opts) do
    provider
    |> Setup.connect_key(
      opts[:api_key],
      Keyword.take(opts, [:model, :base_url, :vault])
    )
    |> report_connect_key()
  end

  defp do_remove(provider) do
    case Setup.remove(provider) do
      {:ok, harness} ->
        IO.puts("removed stored reference for #{harness}")

      {:error, reason} ->
        fail("could not remove #{provider}: #{inspect(reason)}")
    end
  end

  # -- reporting --------------------------------------------------------------

  defp report_connect({:ok, harness, validation}) do
    IO.puts("stored reference for #{harness}")
    report_validation(harness, validation)
  end

  defp report_connect({:error, reason}), do: fail(connect_error(reason))

  defp report_connect_key({:ok, harness, ref, validation}) do
    IO.puts("stored reference for #{harness}: #{ref}")
    report_validation(harness, validation)
  end

  defp report_connect_key({:error, reason}), do: fail(connect_error(reason))

  # A validation that authorizes prints a check and exits 0; anything else
  # prints why and exits non-zero, so a CI step fails on a bad credential.
  defp report_validation(harness, :valid),
    do: IO.puts("#{harness} credential validated ✓")

  defp report_validation(harness, {:rejected, status}),
    do:
      fail(
        "#{harness} credential rejected (HTTP #{status}) — check the key/reference"
      )

  defp report_validation(harness, {:reachable_error, status}),
    do: fail("#{harness} endpoint returned HTTP #{status}")

  defp report_validation(harness, :unreachable),
    do: fail("#{harness} endpoint unreachable")

  defp report_validation(harness, :unsupported),
    do: IO.puts("#{harness} stored (no validation endpoint for this provider)")

  defp report_validation(harness, {:no_key, _}),
    do:
      fail(
        "#{harness} reference stored but no key resolved — is `op` signed in?"
      )

  defp report_validation(harness, :no_provider),
    do: fail("could not resolve a provider for #{harness}")

  defp print_status do
    %{op: op, providers: providers} = Setup.status()

    IO.puts("1Password (op): #{op}")
    IO.puts("providers:")

    Enum.each(providers, fn p ->
      mark = if p.available?, do: "●", else: "○"
      src = if p.source, do: " (via #{p.source})", else: ""
      note = if p[:note], do: "  — #{p.note}", else: ""
      IO.puts("  #{mark} #{p.label}#{src}#{note}")
    end)
  end

  # -- errors -----------------------------------------------------------------

  defp connect_error({:unknown_provider, name}),
    do: "unknown provider: #{name}"

  defp connect_error(:not_an_op_ref),
    do: "--op must be an op://Vault/Item/field reference"

  defp connect_error(:op_unavailable),
    do:
      "the `op` (1Password) CLI is not installed — install it or use --op with an existing reference"

  defp connect_error(reason), do: "setup failed: #{inspect(reason)}"

  defp usage_error(message) do
    IO.puts(:stderr, "raxol.setup: #{message}")
    exit({:shutdown, 64})
  end

  defp fail(message) do
    IO.puts(:stderr, "raxol.setup: #{message}")
    exit({:shutdown, 1})
  end
end
