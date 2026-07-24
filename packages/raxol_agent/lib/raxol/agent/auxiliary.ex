defmodule Raxol.Agent.Auxiliary do
  @moduledoc """
  Per-task-kind model routing for background agent work.

  Not every model call deserves the frontier model. Compression, titling, triage,
  curation, and profile description are cheap work a small fast model does well at
  a fraction of the cost and latency. This resolver maps a task kind to the
  `Raxol.Agent.ExecutorConfig` for its slot, so a feature asks for "the curation
  model" instead of carrying its own backend config.

  ## Config

  An `auxiliary:` map keyed by task kind, passed through the resolver's options.
  Each slot is an `ExecutorConfig`-shaped map plus an optional `:fallback` (an
  ordered list of other slot names or `:default`):

      auxiliary: %{
        curation:    %{backend: :anthropic, model: "claude-haiku-4-5", fallback: [:default]},
        user_model:  %{backend: :anthropic, model: "claude-haiku-4-5"},
        title:       %{backend: :openai,    model: "gpt-5-mini"},
        default_aux: %{backend: :anthropic, model: "claude-haiku-4-5"}
      }

  `default_aux` is the catch-all auxiliary slot. `:default` refers to the agent's
  primary executor, passed as `:default`. A slot's backend key is `:backend`;
  `:harness` is accepted as a deprecated alias.

  ## Precedence

  A task kind resolves to its own slot, then `default_aux`, then the primary
  executor (`:default`). With `auxiliary:` unset, every kind resolves to the
  primary executor. A feature that carries an explicit backend keeps it as an
  override; the resolver is consulted only when that explicit config is absent.

  ## Resolution vs selection

  `resolve/2` returns one `ExecutorConfig` (the slot's primary). `resolve_chain/2`
  returns the slot's primary followed by its fallback chain, terminating at the
  primary executor. `select/2` walks that chain through
  `Raxol.Agent.Backend.Selector`, returning the first available backend, so a
  cheap slot degrades to another cheap slot rather than failing the task.
  """

  alias Raxol.Agent.Backend.Selector
  alias Raxol.Agent.ExecutorConfig

  @type task_kind :: atom()
  @type slot :: map()

  @default_aux_slot :default_aux
  @primary_ref :default

  @doc """
  Resolve a task kind to the `ExecutorConfig` of its slot.

  Falls back to the `default_aux` slot, then to the primary executor passed as
  `:default` (or a `:mock` config if none is given).

  ## Options

  * `:auxiliary` -- the slot map (default `%{}`).
  * `:default` -- the primary executor `ExecutorConfig` (the `:default` target).
  """
  @spec resolve(task_kind(), keyword()) :: ExecutorConfig.t()
  def resolve(task_kind, opts \\ []) when is_atom(task_kind) do
    case slot_for(task_kind, aux_map(opts)) do
      nil -> default_config(opts)
      slot -> to_config(slot)
    end
  end

  @doc """
  Resolve a task kind to its ordered fallback chain of `ExecutorConfig`s.

  The chain is the slot's primary config, then each entry of the slot's
  `:fallback` (a slot name or `:default`), and finally the primary executor, so a
  walk always terminates at `:default`. Duplicates are removed.
  """
  @spec resolve_chain(task_kind(), keyword()) :: [ExecutorConfig.t()]
  def resolve_chain(task_kind, opts \\ []) when is_atom(task_kind) do
    aux = aux_map(opts)
    default = default_config(opts)

    primary =
      case slot_for(task_kind, aux) do
        nil -> default
        slot -> to_config(slot)
      end

    fallbacks =
      task_kind
      |> fallback_names(aux)
      |> Enum.map(fn
        @primary_ref -> default
        name -> resolve(name, opts)
      end)

    dedup(Enum.concat([[primary], fallbacks, [default]]))
  end

  @doc """
  Resolve and select a backend for a task kind, walking the fallback chain.

  Returns `{:ok, backend_module, backend_opts}` for the first config in the chain
  that is available and resolves through `Backend.Selector`, else
  `{:error, :no_available_backend}`.

  ## Options

  In addition to `resolve/2`'s options:

  * `:available?` -- a `(ExecutorConfig.t() -> boolean)` predicate deciding
    whether a config's backend is usable (e.g. has credentials). Defaults to a
    structural check that the harness resolves to a backend module.
  """
  @spec select(task_kind(), keyword()) ::
          {:ok, module(), keyword()} | {:error, term()}
  def select(task_kind, opts \\ []) when is_atom(task_kind) do
    available? = Keyword.get(opts, :available?, &available?/1)

    task_kind
    |> resolve_chain(opts)
    |> Enum.find_value({:error, :no_available_backend}, fn config ->
      with true <- available?.(config),
           {:ok, module, backend_opts} <- Selector.select(config) do
        {:ok, module, backend_opts}
      else
        _ -> nil
      end
    end)
  end

  # -- helpers --

  defp aux_map(opts) do
    case Keyword.get(opts, :auxiliary, %{}) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp slot_for(task_kind, aux) do
    Map.get(aux, task_kind) || Map.get(aux, @default_aux_slot)
  end

  defp fallback_names(task_kind, aux) do
    slot = Map.get(aux, task_kind) || Map.get(aux, @default_aux_slot) || %{}

    case Map.get(slot, :fallback, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp default_config(opts) do
    case Keyword.get(opts, :default) do
      %ExecutorConfig{} = config -> config
      attrs when is_list(attrs) or is_map(attrs) -> ExecutorConfig.new(attrs)
      _ -> ExecutorConfig.new(backend: :mock)
    end
  end

  defp to_config(%ExecutorConfig{} = config), do: config

  defp to_config(slot) when is_map(slot) do
    case Map.get(slot, :backend) || Map.get(slot, :harness) do
      nil ->
        raise ArgumentError,
              "auxiliary slot requires :backend (or :harness), got: #{inspect(slot)}"

      backend ->
        ExecutorConfig.new(%{
          backend: backend,
          model: Map.get(slot, :model),
          auth: Map.get(slot, :auth, %{}),
          opts: Map.get(slot, :opts, [])
        })
    end
  end

  defp available?(config),
    do: match?({:ok, _module, _opts}, Selector.select(config))

  defp dedup(configs) do
    configs
    |> Enum.reduce([], fn config, acc ->
      if config in acc, do: acc, else: [config | acc]
    end)
    |> Enum.reverse()
  end
end
