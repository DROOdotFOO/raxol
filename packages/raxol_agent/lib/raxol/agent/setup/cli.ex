defmodule Raxol.Agent.Setup.CLI do
  @moduledoc """
  Argv front end for `Raxol.Agent.Setup` — the headless provider connect.

  Mix-free on purpose, like `Raxol.Agent.Code.Launcher` and
  `Raxol.Agent.ClientProtocol.Serve`: `mix raxol.setup` and the packaged
  binary's `raxol setup` are both thin shims over this, so the two cannot
  drift. That matters more here than elsewhere — connecting a provider is the
  first thing a fresh install needs, and before this the only way to do it
  headlessly was a Mix task, which someone who installed via npm does not have.

  `run/1` returns a process exit code rather than raising: 0 on success, 64 on
  a usage error, 1 on a failure. A credential that does not authorize exits
  non-zero so a CI step fails loudly on a bad or expired reference.

  See `Mix.Tasks.Raxol.Setup` for the option reference.
  """

  alias Raxol.Agent.Auth.Flow
  alias Raxol.Agent.Backend.Resolver
  alias Raxol.Agent.Setup

  @switches [
    provider: :string,
    op: :string,
    api_key: :string,
    model: :string,
    base_url: :string,
    vault: :string,
    browser: :boolean,
    remove: :boolean,
    status: :boolean,
    help: :boolean
  ]

  @aliases [h: :help]

  @doc "Run the setup front end for `argv`, returning an exit code."
  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
      {opts, [], []} ->
        if Keyword.get(opts, :help, false) do
          usage()
          0
        else
          dispatch(opts)
          0
        end

      {_opts, _args, invalid} ->
        usage_error("unknown options: #{inspect(invalid)}")
    end
  catch
    # The reporting helpers below signal their exit code by unwinding, so a
    # failure deep inside a validation report does not have to be threaded back
    # through every caller. Caught here and turned into a return value, which
    # is what both shims want.
    :exit, {:shutdown, code} when is_integer(code) ->
      code
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

      Keyword.get(opts, :browser, false) ->
        do_connect_browser(provider)

      true ->
        usage_error("give one of --op, --api-key, --browser, or --remove for #{provider}")
    end
  end

  defp no_action?(opts) do
    not Enum.any?(
      [:op, :api_key, :browser, :remove, :provider],
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

  # The flow stores through `Setup.connect_key/3` like every other path here,
  # so what lands on disk is still only an `op://` reference.
  defp do_connect_browser(provider) do
    case Resolver.harness_from_string(provider) do
      {:ok, harness} -> run_browser_flow(harness)
      :error -> fail(connect_error({:unknown_provider, provider}))
    end
  end

  defp run_browser_flow(harness) do
    if Flow.supported?(harness) do
      IO.puts("opening a browser to sign in to #{harness}...")
      report_browser(Flow.run(harness), harness)
    else
      fail(
        "#{harness} has no browser sign-in — use --op or --api-key " <>
          "(browser sign-in: #{Enum.map_join(Flow.providers(), ", ", &to_string/1)})"
      )
    end
  end

  defp report_browser(
         {:ok, %{provider: provider, validation: validation}},
         _harness
       ) do
    IO.puts("stored reference for #{provider}")
    report_validation(provider, validation)
    print_next_steps(:connected)
  end

  defp report_browser({:error, reason}, harness) do
    fail("#{harness} sign-in failed: #{Flow.describe(reason)}")
  end

  defp do_remove(provider) do
    case Setup.remove(provider) do
      {:ok, harness} ->
        IO.puts("removed stored reference for #{harness}")
        print_current_next_steps()

      {:error, reason} ->
        fail("could not remove #{provider}: #{inspect(reason)}")
    end
  end

  # -- reporting --------------------------------------------------------------

  defp report_connect({:ok, harness, validation}) do
    IO.puts("stored reference for #{harness}")
    report_validation(harness, validation)
    print_next_steps(:connected)
  end

  defp report_connect({:error, reason}), do: fail(connect_error(reason))

  defp report_connect_key({:ok, harness, ref, validation}) do
    IO.puts("stored reference for #{harness}: #{ref}")
    report_validation(harness, validation)
    print_next_steps(:connected)
  end

  defp report_connect_key({:error, reason}), do: fail(connect_error(reason))

  # A validation that authorizes prints a check and exits 0; anything else
  # prints why and exits non-zero, so a CI step fails on a bad credential.
  defp report_validation(harness, :valid),
    do: IO.puts("#{harness} credential validated ✓")

  defp report_validation(harness, {:rejected, status}),
    do: fail("#{harness} credential rejected (HTTP #{status}) — check the key/reference")

  defp report_validation(harness, {:reachable_error, status}),
    do: fail("#{harness} endpoint returned HTTP #{status}")

  defp report_validation(harness, :unreachable),
    do: fail("#{harness} endpoint unreachable")

  defp report_validation(harness, :unsupported),
    do: IO.puts("#{harness} stored (no validation endpoint for this provider)")

  defp report_validation(harness, {:no_key, _}),
    do: fail("#{harness} reference stored but no key resolved — is `op` signed in?")

  defp report_validation(harness, :no_provider),
    do: fail("could not resolve a provider for #{harness}")

  @doc "Print the provider status table (also what `raxol doctor` shows)."
  @spec print_status() :: :ok
  def print_status do
    %{op: op, providers: providers} = Setup.status()

    IO.puts("1Password (op): #{op}")
    IO.puts("providers:")

    Enum.each(providers, fn p ->
      mark = if p.available?, do: "●", else: "○"
      src = if p.source, do: " (via #{p.source})", else: ""
      note = if p[:note], do: "  — #{p.note}", else: ""
      IO.puts("  #{mark} #{p.label}#{src}#{note}")
    end)

    IO.puts("")
    IO.puts(next_steps(providers))
  end

  defp print_current_next_steps do
    %{providers: providers} = Setup.status()
    print_next_steps(providers)
  end

  defp print_next_steps(state) do
    IO.puts("")
    IO.puts(next_steps(state))
  end

  defp next_steps(providers) when is_list(providers) do
    if Enum.any?(providers, & &1.available?),
      do: next_steps(:connected),
      else: next_steps(:disconnected)
  end

  defp next_steps(:connected) do
    """
    next:
      start the agent:
        raxol

      coding TUI:
        raxol code

      inspect install:
        raxol doctor
    """
    |> String.trim_trailing()
  end

  defp next_steps(:disconnected) do
    """
    next:
      connect a provider:
        raxol login openrouter
        raxol setup --provider anthropic --op op://Vault/Item/api_key

      try offline:
        raxol

      inspect install:
        raxol doctor
    """
    |> String.trim_trailing()
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
    IO.puts(:stderr, "raxol setup: #{message}")
    exit({:shutdown, 64})
  end

  defp fail(message) do
    IO.puts(:stderr, "raxol setup: #{message}")
    exit({:shutdown, 1})
  end

  defp usage do
    IO.puts("""
    Usage: raxol setup [options]

    Connect or inspect an LLM provider without the TUI. Only 1Password
    references are written to disk, never a raw key.

    Options:
      --provider NAME   provider (anthropic, openai, kimi, ollama, ...)
      --op REF          store an existing op://Vault/Item/field reference
      --api-key KEY     create a 1Password item from a raw key, store its ref
      --model NAME      default model to store with the reference
      --base-url URL    base URL override to store with the reference
      --vault NAME      1Password vault for --api-key (default: Private)
      --browser         browser sign-in, for providers that offer one
      --remove          forget a provider's stored reference
      --status          print provider status and exit (the default)
      -h, --help        show this help

    With no options, prints what is connected and why a provider is not.
    """)
  end
end
