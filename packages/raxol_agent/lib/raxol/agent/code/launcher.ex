defmodule Raxol.Agent.Code.Launcher do
  @moduledoc """
  The coding-agent TUI launch path, as a plain function.

  Shared by every entrypoint: `mix raxol.code` (dev), the `raxol code`
  subcommand of the Burrito-packaged CLI (release), and the repo-root
  `bin/raxol-code` shim. Contains no Mix calls, so it runs inside a release
  where Mix does not exist; `main/2` returns the exit code and leaves
  halting to the caller.

  Flag parsing, provider resolution (through `Raxol.Agent.Backend.Cli` and
  `Raxol.Agent.Backend.Resolver`), the `.raxol/config.json` repo pin, and
  session resolution all live here so the entrypoints cannot drift. The
  caller injects its boot step via the `:boot` option; a boot that returns
  `{:error, message}` (a non-interactive terminal, say) vetoes the launch
  with exit 1 before any UI starts.
  """

  alias Raxol.Agent.Backend.Cli
  alias Raxol.Agent.Code.Store

  @switches [
    backend: :string,
    # `--harness` is a deprecated alias for `--backend`.
    harness: :string,
    model: :string,
    api_key: :string,
    base_url: :string,
    system: :string,
    continue: :boolean,
    resume: :string,
    sessions: :boolean,
    ascii: :boolean,
    help: :boolean
  ]

  @aliases [h: :help]

  @usage """
  Usage: raxol code [options]    (dev: mix raxol.code [options])

  Interactive coding agent TUI (the axol face).

  Options:
    --backend NAME   LLM backend (auto-detected if omitted; --harness is a
                     deprecated alias)
    --model NAME     model override
    --api-key KEY    API key for the selected backend (else op/env)
    --base-url URL   override the backend base URL
    --system TEXT    system prompt override
    --continue       resume the most recently updated session
    --resume ID      resume a specific session by id
    --sessions       print saved sessions and exit
    --ascii          ASCII-only face for terminals without a UTF-8 font
    -h, --help       print this help

  Full docs: mix help raxol.code
  """

  @doc """
  Run the coding-agent entrypoint from `argv`; returns the exit code.

  Options: `:boot` — a zero-arity function run after flag/provider
  resolution and before the TUI starts; return `:ok` to proceed or
  `{:error, message}` to veto with exit 1. Defaults to starting the
  `:raxol_agent` application (idempotent under a release).
  """
  @spec main([String.t()], keyword()) :: non_neg_integer()
  def main(argv, opts \\ []) do
    {parsed, _args, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    cond do
      Keyword.get(parsed, :help, false) ->
        IO.puts(@usage)
        0

      invalid != [] ->
        usage_error!("unknown options: #{inspect(invalid)}")

      Keyword.get(parsed, :sessions, false) ->
        print_sessions()

      true ->
        launch(parsed, Keyword.get(opts, :boot, &default_boot/0))
    end
  catch
    {:raxol_code_usage, message} ->
      IO.puts(:stderr, "raxol.code: #{message}\n\n#{@usage}")
      64
  end

  # Non-local exit for the deep parse/validate sites; caught in main/2.
  defp usage_error!(message), do: throw({:raxol_code_usage, message})

  defp print_sessions do
    dir = Store.default_dir()

    case Store.list(dir) do
      [] ->
        IO.puts("no saved sessions in #{dir}")

      sessions ->
        IO.puts("saved sessions in #{dir}:")

        Enum.each(sessions, fn s ->
          IO.puts("  #{s.id}  (#{s.message_count} msgs)")
        end)
    end

    0
  end

  defp launch(parsed, boot) do
    # Resolve flags and the provider before booting: an unknown backend
    # errors fast, without starting anything.
    app_opts = app_opts(parsed)

    case boot.() do
      :ok ->
        {:ok, pid} = Raxol.start_link(Raxol.Agent.Code.App, app_opts)
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> 0
        end

      {:error, message} ->
        IO.puts(:stderr, "raxol code: #{message}")
        1
    end
  end

  defp default_boot do
    {:ok, _} = Application.ensure_all_started(:raxol_agent)
    :ok
  end

  @doc false
  # The Code.App boot options for parsed flags: repo pin + resolver +
  # session resolution. Public (hidden) so the SSH serving path can reuse it.
  @spec app_opts(keyword()) :: keyword()
  def app_opts(parsed) do
    project = Raxol.Agent.Code.ProjectConfig.load(File.cwd!())

    resolution =
      Raxol.Agent.Backend.Resolver.resolve(resolver_opts(parsed, project))

    []
    |> put_if(:system, Keyword.get(parsed, :system))
    |> put_if(:model, Keyword.get(parsed, :model) || Map.get(project, :model))
    |> put_if(:session_key, resolve_session(parsed))
    |> Keyword.put(:ascii, Keyword.get(parsed, :ascii, false))
    |> apply_resolution(resolution)
  end

  # The resolver inputs, in precedence order explicit flag > `.raxol/config.json`
  # pin > env auto-detect: a `--backend`/`--model`/`--base-url` wins, else the
  # per-repo pin, else the resolver auto-detects. The resolver's own input key
  # stays `:harness` (its internal provider vocabulary); only the user-facing
  # flag is renamed.
  defp resolver_opts(parsed, project) do
    []
    |> maybe_put(
      :harness,
      backend_flag(parsed) || Map.get(project, :provider)
    )
    |> maybe_put(:model, Keyword.get(parsed, :model) || Map.get(project, :model))
    |> maybe_put(:api_key, Keyword.get(parsed, :api_key))
    |> maybe_put(
      :base_url,
      Keyword.get(parsed, :base_url) || Map.get(project, :base_url)
    )
  end

  # Shared `--backend`/`--harness` normalization + validation (deprecation
  # notices, supported-name check) through `Backend.Cli`. Returns the backend
  # atom, or `nil` when neither flag is given (auto-detect).
  defp backend_flag(parsed) do
    case Cli.flag(parsed, "raxol.code") do
      {:ok, backend} -> backend
      {:error, message} -> usage_error!(message)
    end
  end

  # `{:ok, executor, source}` wires the executor and records how it was found;
  # `{:no_key, harness}` and `:no_provider` open the App on its setup panel
  # (no executor) so the user can `/login` rather than hit a crash.
  defp apply_resolution(app_opts, {:ok, executor, source}) do
    app_opts
    |> Keyword.put(:executor, executor)
    |> Keyword.put(:provider_status, {:ready, executor.backend, source})
  end

  defp apply_resolution(app_opts, {:no_key, harness}) do
    Keyword.put(app_opts, :provider_status, {:no_key, harness})
  end

  defp apply_resolution(app_opts, :no_provider) do
    Keyword.put(app_opts, :provider_status, :no_provider)
  end

  defp resolve_session(parsed) do
    cond do
      key = Keyword.get(parsed, :resume) -> key
      Keyword.get(parsed, :continue, false) -> Store.latest(Store.default_dir())
      true -> nil
    end
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp put_if(kw, _key, nil), do: kw
  defp put_if(kw, key, value), do: Keyword.put(kw, key, value)
end
