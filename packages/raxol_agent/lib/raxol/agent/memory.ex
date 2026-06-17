defmodule Raxol.Agent.Memory do
  @moduledoc """
  Cross-session memory for Raxol agents.

  Memory is a pluggable behaviour. A provider persists `Raxol.Agent.Memory.Record`
  entries and answers recall queries. The default provider,
  `Raxol.Agent.Memory.Store.Ets`, is a self-contained ETS+DETS store with
  pure-Elixir ranking (no external dependencies).

  Reads are automatic: `Raxol.Agent.Memory.Manager` prefetches relevant
  memories before each turn and injects them into the system prompt. Writes are
  explicit: an agent calls the `memory_remember` action.

  Memory is opt-in. With no provider configured, every hook is a no-op.

  ## Provider lifecycle

    * `prefetch/2` - records relevant to a query (defaults to `search/2`)
    * `search/2` - ranked recall for a query
    * `store/2` - persist a record
    * `forget/2` - delete a record by id
    * `build_system_prompt/1` - format records into a system-prompt block

  Only `search/2`, `store/2`, and `forget/2` are mandatory; `prefetch/2` and
  `build_system_prompt/1` have sensible defaults from `use Raxol.Agent.Memory`.

  `opts` carry `:server` (provider instance), `:agent_id` (partition),
  `:limit` (default 5), `:query`, `:query_tags`, and `:tags`.
  """

  alias Raxol.Agent.Memory.Record

  @callback prefetch(query :: String.t(), opts :: keyword()) :: [Record.t()]
  @callback search(query :: String.t(), opts :: keyword()) :: [Record.t()]
  @callback store(Record.t(), opts :: keyword()) ::
              {:ok, Record.t()} | {:error, term()}
  @callback forget(id :: String.t(), opts :: keyword()) :: :ok
  @callback build_system_prompt(opts :: keyword()) :: String.t() | nil

  @doc """
  An optional per-user context block injected into the LAST user message rather
  than the system prompt, so a per-turn refresh does not invalidate the cacheable
  system prefix. Returns `nil` to inject nothing (the default).
  """
  @callback build_user_context(opts :: keyword()) :: String.t() | nil

  @optional_callbacks build_user_context: 1

  @doc "The provider configured for this node, or nil when memory is disabled."
  @spec default_provider() :: module() | nil
  def default_provider, do: Application.get_env(:raxol_agent, :memory_provider)

  @doc """
  Build the normalized `{provider, opts}` tuple for `context[:memory]`,
  scoping records to `agent_id`. Returns `nil` when `provider` is `nil`.
  """
  @spec provider_context(module() | nil, String.t() | nil, keyword()) ::
          {module(), keyword()} | nil
  def provider_context(provider, agent_id, opts \\ [])
  def provider_context(nil, _agent_id, _opts), do: nil

  def provider_context(provider, agent_id, opts) when is_atom(provider) do
    {provider, Keyword.put(opts, :agent_id, agent_id)}
  end

  @doc """
  Build the `{module, opts}` tuple for a stacked set of providers under
  `context[:memory]`, scoping records to `agent_id`. Each entry is a bare
  module or a `{module, opts}` pair. Returns `nil` for an empty list.
  """
  @spec stack_context([module() | {module(), keyword()}], String.t() | nil, keyword()) ::
          {module(), keyword()} | nil
  def stack_context(providers, agent_id, opts \\ [])
  def stack_context([], _agent_id, _opts), do: nil

  def stack_context(providers, agent_id, opts) when is_list(providers) do
    {Raxol.Agent.Memory.Stack,
     opts |> Keyword.put(:providers, providers) |> Keyword.put(:agent_id, agent_id)}
  end

  @doc "Format memory records into a system-prompt block, or nil if empty."
  @spec format_block([Record.t()]) :: String.t() | nil
  def format_block([]), do: nil

  def format_block(records) do
    lines = Enum.map_join(records, "\n", fn r -> "- (#{r.type}) #{r.content}" end)
    "## Relevant memory\n\nRecalled from earlier sessions:\n\n#{lines}"
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Raxol.Agent.Memory

      @impl Raxol.Agent.Memory
      def prefetch(query, opts), do: search(query, opts)

      @impl Raxol.Agent.Memory
      def build_system_prompt(opts) do
        opts
        |> Keyword.get(:query, "")
        |> prefetch(opts)
        |> Raxol.Agent.Memory.format_block()
      end

      @impl Raxol.Agent.Memory
      def build_user_context(_opts), do: nil

      defoverridable prefetch: 2, build_system_prompt: 1, build_user_context: 1
    end
  end
end
