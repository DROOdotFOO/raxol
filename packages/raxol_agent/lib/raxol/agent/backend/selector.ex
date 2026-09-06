defmodule Raxol.Agent.Backend.Selector do
  @moduledoc """
  Resolve a `Raxol.Agent.ExecutorConfig` to a concrete backend module + options.

  This is the explicit replacement for `Raxol.Agent.Backend.HTTP`'s implicit
  `base_url` substring detection: a named backend maps to a backend module and a
  set of default options (provider hint, base URL), which are merged with the
  config's own model/auth/opts.

  Native CLI backends (`:claude_native`, `:grok_native`, `:cursor`) hand the
  loop to a vendor CLI. `:codex` is reserved -- it speaks a stateful app-server
  protocol served by `Raxol.Symphony.Runners.Codex` rather than an agent
  backend -- and resolves to an error.
  """

  alias Raxol.Agent.Backend.Catalog
  alias Raxol.Agent.ExecutorConfig

  # backend => {backend_module, default_opts}
  #
  # Derived from the catalog rather than declared again: ADR-0034 measured this
  # table, the resolver's provider list and `ExecutorConfig.backend()`
  # disagreeing about which backends exist. Only runnable kinds land here;
  # `:reserved` entries stay out on purpose and fall through to `reason_for/1`.
  @backend_table Map.new(
                   Catalog.by_kind([:http, :native, :mock]),
                   &{&1.id, {&1.module, &1.backend_opts}}
                 )

  @reserved_backends Enum.map(Catalog.by_kind(:reserved), & &1.id)

  @doc """
  Resolve an executor config to `{:ok, backend_module, backend_opts}`.

  The returned `backend_opts` are the backend defaults merged with the config's
  flattened `model`/`auth`/`opts` (config values win on conflict). Returns
  `{:error, {:backend_not_implemented, backend}}` for reserved native backends
  and `{:error, {:unknown_backend, backend}}` otherwise.
  """
  @spec select(ExecutorConfig.t()) ::
          {:ok, module(), keyword()} | {:error, term()}
  def select(%ExecutorConfig{backend: backend} = config) do
    case Map.fetch(@backend_table, backend) do
      {:ok, {module, defaults}} ->
        opts = Keyword.merge(defaults, ExecutorConfig.to_backend_opts(config))
        {:ok, module, opts}

      :error ->
        {:error, reason_for(backend)}
    end
  end

  @doc "List the backend atoms this selector can resolve to a backend module."
  @spec supported_backends() :: [ExecutorConfig.backend()]
  def supported_backends, do: Map.keys(@backend_table)

  @doc false
  @deprecated "Use supported_backends/0"
  @spec supported_harnesses() :: [ExecutorConfig.backend()]
  def supported_harnesses, do: supported_backends()

  defp reason_for(backend) when backend in @reserved_backends,
    do: {:backend_not_implemented, backend}

  defp reason_for(backend), do: {:unknown_backend, backend}
end
