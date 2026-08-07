defmodule Raxol.Agent.Backend.Cli do
  @moduledoc """
  Shared `--backend` / `--harness` flag handling for the `raxol.code` and
  `raxol.p` mix tasks.

  `--backend` is the canonical flag; `--harness` is a deprecated alias. If both
  are given, `--backend` wins. Flag normalization, the supported-name error
  message, and credential resolution through `Raxol.Agent.Backend.Resolver`
  live here so the two tasks cannot drift.

  `prog` is the task name used in stderr deprecation notices (`"raxol.code"`).
  Pass `nil` to suppress those notices entirely — `raxol.p` reserves stderr for
  its JSONL event stream, and a plain-text line would corrupt it.
  """

  alias Raxol.Agent.Backend.Resolver
  alias Raxol.Agent.Backend.Selector
  alias Raxol.Agent.ExecutorConfig

  @doc """
  Normalize the `--backend` / `--harness` flags to a `Selector` backend atom.

  Returns `{:ok, backend}` for a valid explicit flag, `{:ok, nil}` when
  neither flag is given (the caller decides between auto-detection and its own
  default), or `{:error, message}` for an unknown name. Emits a deprecation
  notice to stderr when `--harness` is used or both flags are given, unless
  `prog` is `nil`.
  """
  @spec flag(keyword(), String.t() | nil) ::
          {:ok, ExecutorConfig.backend() | nil} | {:error, String.t()}
  def flag(opts, prog) when is_list(opts) do
    {name, status} = raw_flag(opts)
    maybe_warn(status, prog)

    case name do
      nil -> {:ok, nil}
      name -> resolve_name(name)
    end
  end

  @doc """
  Resolve the task flags all the way to a ready `ExecutorConfig` via
  `Raxol.Agent.Backend.Resolver`.

  With an explicit `--backend`, that provider's credential is resolved (op://
  reference, then env var); keyless providers (`lm_studio`, `ollama`, ...)
  need none. With no flag, the resolver auto-detects from stored references
  and env vars. Recognized opts besides the flags: `:model`, `:api_key`.

  Returns `{:ok, executor, source}` or `{:error, message}` where the message
  is actionable (how to connect a provider), suitable for printing verbatim.
  """
  @spec resolve_executor(keyword(), String.t() | nil) ::
          {:ok, ExecutorConfig.t(), Resolver.source()} | {:error, String.t()}
  def resolve_executor(opts, prog) when is_list(opts) do
    with {:ok, backend} <- flag(opts, prog) do
      []
      |> maybe_put(:harness, backend)
      |> maybe_put(:model, Keyword.get(opts, :model))
      |> maybe_put(:api_key, Keyword.get(opts, :api_key))
      |> Resolver.resolve()
      |> case do
        {:ok, executor, source} -> {:ok, executor, source}
        :no_provider -> {:error, no_provider_message()}
        {:no_key, harness} -> {:error, no_key_message(harness)}
      end
    end
  end

  defp no_provider_message do
    "no provider configured; run `mix raxol.setup`, set a provider env var " <>
      "(ANTHROPIC_API_KEY, OPENAI_API_KEY, AI_API_KEY, ...), or pass " <>
      "--backend (e.g. --backend lm_studio for a local server)"
  end

  defp no_key_message(harness) do
    "no credential resolved for #{harness}; run " <>
      "`mix raxol.setup --provider #{harness}`, set its API key env var, " <>
      "or pass --api-key"
  end

  # `--backend` is canonical; `--harness` is the deprecated alias (backend wins).
  defp raw_flag(opts) do
    case {Keyword.get(opts, :backend), Keyword.get(opts, :harness)} do
      {nil, nil} -> {nil, :none}
      {nil, legacy} -> {legacy, :deprecated}
      {name, nil} -> {name, :ok}
      {name, _both} -> {name, :both}
    end
  end

  defp resolve_name(name) do
    supported = Selector.supported_backends()

    case Enum.find(supported, &(Atom.to_string(&1) == name)) do
      nil ->
        list = Enum.map_join(supported, ", ", &Atom.to_string/1)
        {:error, "unknown backend #{inspect(name)}; supported: #{list}"}

      backend ->
        {:ok, backend}
    end
  end

  defp maybe_warn(_status, nil), do: :ok

  defp maybe_warn(:deprecated, prog),
    do: IO.puts(:stderr, "#{prog}: --harness is deprecated; use --backend")

  defp maybe_warn(:both, prog),
    do:
      IO.puts(
        :stderr,
        "#{prog}: both --backend and --harness given; using --backend"
      )

  defp maybe_warn(_status, _prog), do: :ok

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)
end
