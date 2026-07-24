defmodule Raxol.Agent.Backend.Cli do
  @moduledoc """
  Shared `--backend` / `--harness` flag handling for the `raxol.code` and
  `raxol.p` mix tasks.

  `--backend` is the canonical flag; `--harness` is a deprecated alias. If both
  are given, `--backend` wins. Resolution and the supported-name error message
  live here so the two tasks cannot drift.

  `prog` is the task name used in stderr deprecation notices (`"raxol.code"`).
  Pass `nil` to suppress those notices entirely — `raxol.p` reserves stderr for
  its JSONL event stream, and a plain-text line would corrupt it.
  """

  alias Raxol.Agent.Backend.Selector
  alias Raxol.Agent.ExecutorConfig

  @default_backend "lm_studio"

  @doc """
  Resolve the `--backend` / `--harness` flags to a `Selector` backend atom.

  Returns `{:ok, backend}` or `{:error, message}` (unknown name). Emits a
  deprecation notice to stderr when `--harness` is used or both flags are given,
  unless `prog` is `nil`.
  """
  @spec resolve(keyword(), String.t() | nil) ::
          {:ok, ExecutorConfig.backend()} | {:error, String.t()}
  def resolve(opts, prog) when is_list(opts) do
    {name, status} = flag(opts)
    maybe_warn(status, prog)
    resolve_name(name)
  end

  # `--backend` is canonical; `--harness` is the deprecated alias (backend wins).
  defp flag(opts) do
    case {Keyword.get(opts, :backend), Keyword.get(opts, :harness)} do
      {nil, nil} -> {@default_backend, :default}
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
end
