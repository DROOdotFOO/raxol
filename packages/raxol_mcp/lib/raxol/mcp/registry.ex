defmodule Raxol.MCP.Registry do
  @moduledoc """
  ETS-backed registry for MCP tools and resources.

  Any module can register tools and resources. The registry stores definitions
  alongside callback functions that are invoked when tools are called or
  resources are read.

  Reads (`list_tools`, `call_tool`, `list_resources`, `read_resource`) go
  directly to ETS with `read_concurrency: true` -- no GenServer bottleneck.
  Writes (`register_*`, `unregister_*`) serialize through the GenServer.

  ## Tool Registration

      tools = [
        %{
          name: "raxol_screenshot",
          description: "Capture a screenshot",
          inputSchema: %{type: "object", properties: %{id: %{type: "string"}}},
          callback: fn args -> {:ok, [%{type: "text", text: "screenshot data"}]} end
        }
      ]
      Registry.register_tools(registry, tools)

  ## Resource Registration

      resources = [
        %{
          uri: "raxol://session/demo/model",
          name: "Session Model",
          description: "Current TEA model state",
          callback: fn -> {:ok, %{counter: 5}} end
        }
      ]
      Registry.register_resources(registry, resources)

  ## Which errors open a circuit

  Every callback runs behind a `Raxol.MCP.CircuitBreaker` keyed on the tool,
  resource or prompt. A raise or an exit always counts as a failure; a
  returned `{:error, reason}` counts unless the registration declares a
  `:fault?` classifier:

      %{
        name: "web3_get_transaction",
        description: "...",
        inputSchema: %{type: "object"},
        callback: &Tools.get_transaction/1,
        fault?: &Tools.fault?/1
      }

  `:fault?` is a 1-arity function called with the `reason` the callback
  returned. `false` means the error is an answer about the question -- a
  not-found, a malformed cursor -- and records nothing. Anything else is an
  availability fault and records a failure. The registry stays generic: it
  knows no taxonomy, only who to ask.

  A callback that raises or exits answers `{:error, {:callback_raised,
  module}}` or `{:error, {:callback_exited, atom}}`. The exception message is
  logged, never returned, because the return value reaches a model.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.MCP.CircuitBreaker

  @type tool_def :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:inputSchema) => map(),
          required(:callback) => (map() -> {:ok, term()} | {:error, term()}),
          optional(:fault?) => (term() -> boolean())
        }

  @type resource_def :: %{
          required(:uri) => String.t(),
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:callback) => (-> {:ok, term()} | {:error, term()}),
          optional(:fault?) => (term() -> boolean())
        }

  @type prompt_def :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:arguments) => [map()],
          required(:callback) => (map() -> {:ok, [map()]} | {:error, term()}),
          optional(:fault?) => (term() -> boolean())
        }

  # -- Client API ---------------------------------------------------------------

  @doc "Start the registry, linked to the calling process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Register one or more tools."
  @spec register_tools(GenServer.server(), [tool_def()]) :: :ok
  def register_tools(registry \\ __MODULE__, tools) do
    GenServer.call(registry, {:register_tools, tools})
  end

  @doc """
  Registers tools and/or resources in one call after validating each tool
  shape via `Raxol.MCP.ToolDef.validate/1`.

  Reduces the common consumer boilerplate:

      :ok = Registry.register_tools(registry, tools)
      :ok = Registry.register_resources(registry, resources)

  to a single call:

      :ok = Registry.register_all(registry, tools: tools, resources: resources)

  Returns `{:error, {:invalid_tool, index, reasons}}` (no tools or
  resources registered) when validation fails.

  Note: this helper requires the `Raxol.MCP.Registry` module to be loaded
  at runtime. Consumers with `raxol_mcp` as an optional dep should still
  gate the call with `Code.ensure_loaded?(Raxol.MCP.Registry)`. Optional
  deps are an Elixir-level concern; no helper can paper over a missing
  module.
  """
  @spec register_all(GenServer.server(), keyword()) ::
          :ok | {:error, {:invalid_tool, non_neg_integer(), [atom()]}}
  def register_all(registry \\ __MODULE__, opts) when is_list(opts) do
    tools = Keyword.get(opts, :tools, [])
    resources = Keyword.get(opts, :resources, [])
    prompts = Keyword.get(opts, :prompts, [])

    case validate_tools(tools) do
      :ok ->
        if tools != [], do: :ok = register_tools(registry, tools)
        if resources != [], do: :ok = register_resources(registry, resources)
        if prompts != [], do: :ok = register_prompts(registry, prompts)
        :ok

      {:error, _} = err ->
        err
    end
  end

  defp validate_tools(tools) do
    tools
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {tool, index}, _acc ->
      case Raxol.MCP.ToolDef.validate(tool) do
        :ok -> {:cont, :ok}
        {:error, reasons} -> {:halt, {:error, {:invalid_tool, index, reasons}}}
      end
    end)
  end

  @doc "Unregister tools by name."
  @spec unregister_tools(GenServer.server(), [String.t()]) :: :ok
  def unregister_tools(registry \\ __MODULE__, names) do
    GenServer.call(registry, {:unregister_tools, names})
  end

  @doc "List all registered tools (definitions without callbacks)."
  @spec list_tools(GenServer.server()) :: [map()]
  def list_tools(registry \\ __MODULE__) do
    table = get_table(registry)

    :ets.select(table, [
      {{:"$1", {:tool, :"$2", :"$3", :_, :_}}, [], [:"$3"]}
    ])
  end

  @doc "Call a registered tool by name with arguments."
  @spec call_tool(GenServer.server(), String.t(), map()) ::
          {:ok, term()} | {:error, term()}
  def call_tool(registry \\ __MODULE__, name, arguments) do
    table = get_table(registry)
    breaker_table = get_breaker_table(registry)
    breaker_key = tool_key(name)

    case :ets.lookup(table, breaker_key) do
      [{_key, {:tool, ^name, _def, callback, classifier}}] ->
        invoke_with_breaker(breaker_table, breaker_key, classifier, fn ->
          callback.(arguments)
        end)

      [] ->
        {:error, :tool_not_found}
    end
  end

  @doc "Register one or more resources."
  @spec register_resources(GenServer.server(), [resource_def()]) :: :ok
  def register_resources(registry \\ __MODULE__, resources) do
    GenServer.call(registry, {:register_resources, resources})
  end

  @doc "Unregister resources by URI."
  @spec unregister_resources(GenServer.server(), [String.t()]) :: :ok
  def unregister_resources(registry \\ __MODULE__, uris) do
    GenServer.call(registry, {:unregister_resources, uris})
  end

  @doc "List all registered resources (definitions without callbacks)."
  @spec list_resources(GenServer.server()) :: [map()]
  def list_resources(registry \\ __MODULE__) do
    table = get_table(registry)

    :ets.select(table, [
      {{:"$1", {:resource, :"$2", :"$3", :_, :_}}, [], [:"$3"]}
    ])
  end

  @doc "Read a registered resource by URI."
  @spec read_resource(GenServer.server(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def read_resource(registry \\ __MODULE__, uri) do
    table = get_table(registry)
    breaker_table = get_breaker_table(registry)
    breaker_key = resource_key(uri)

    case :ets.lookup(table, breaker_key) do
      [{_key, {:resource, ^uri, _def, callback, classifier}}] ->
        invoke_with_breaker(breaker_table, breaker_key, classifier, fn -> callback.() end)

      [] ->
        {:error, :resource_not_found}
    end
  end

  # -- Prompts API --------------------------------------------------------------

  @doc "Register one or more prompts."
  @spec register_prompts(GenServer.server(), [prompt_def()]) :: :ok
  def register_prompts(registry \\ __MODULE__, prompts) do
    GenServer.call(registry, {:register_prompts, prompts})
  end

  @doc "Unregister prompts by name."
  @spec unregister_prompts(GenServer.server(), [String.t()]) :: :ok
  def unregister_prompts(registry \\ __MODULE__, names) do
    GenServer.call(registry, {:unregister_prompts, names})
  end

  @doc "List all registered prompts (definitions without callbacks)."
  @spec list_prompts(GenServer.server()) :: [map()]
  def list_prompts(registry \\ __MODULE__) do
    table = get_table(registry)

    :ets.select(table, [
      {{:"$1", {:prompt, :"$2", :"$3", :_, :_}}, [], [:"$3"]}
    ])
  end

  @doc "Get a prompt by name, rendering it with the given arguments."
  @spec get_prompt(GenServer.server(), String.t(), map()) ::
          {:ok, [map()]} | {:error, term()}
  def get_prompt(registry \\ __MODULE__, name, arguments) do
    table = get_table(registry)
    breaker_table = get_breaker_table(registry)
    breaker_key = prompt_key(name)

    case :ets.lookup(table, breaker_key) do
      [{_key, {:prompt, ^name, _def, callback, classifier}}] ->
        invoke_with_breaker(breaker_table, breaker_key, classifier, fn ->
          callback.(arguments)
        end)

      [] ->
        {:error, :prompt_not_found}
    end
  end

  @doc "Get circuit breaker status for a tool, resource, or prompt key."
  @spec circuit_status(GenServer.server(), CircuitBreaker.key()) :: map()
  def circuit_status(registry \\ __MODULE__, key) do
    breaker_table = get_breaker_table(registry)
    CircuitBreaker.status(breaker_table, key)
  end

  @doc "Manually reset a circuit breaker."
  @spec reset_circuit(GenServer.server(), CircuitBreaker.key()) :: :ok
  def reset_circuit(registry \\ __MODULE__, key) do
    breaker_table = get_breaker_table(registry)
    CircuitBreaker.reset(breaker_table, key)
  end

  # -- GenServer Callbacks -------------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    table_name = Keyword.get(opts, :table_name, :raxol_mcp_registry)

    table =
      :ets.new(table_name, [
        :set,
        :public,
        read_concurrency: true
      ])

    breaker_name = :"#{table_name}_breakers"
    breaker_table = CircuitBreaker.new(breaker_name)

    {:ok, %{table: table, breaker_table: breaker_table}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:register_tools, tools}, _from, state) do
    for tool <- tools do
      entry = {:tool, tool.name, tool_definition(tool), tool.callback, fault_classifier(tool)}
      :ets.insert(state.table, {tool_key(tool.name), entry})
    end

    :telemetry.execute(
      [:raxol, :mcp, :registry, :tools_changed],
      %{count: length(tools)},
      %{action: :register, names: Enum.map(tools, & &1.name)}
    )

    {:reply, :ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:unregister_tools, names}, _from, state) do
    for name <- names do
      :ets.delete(state.table, tool_key(name))
    end

    :telemetry.execute(
      [:raxol, :mcp, :registry, :tools_changed],
      %{count: length(names)},
      %{action: :unregister, names: names}
    )

    {:reply, :ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:register_resources, resources}, _from, state) do
    for resource <- resources do
      entry =
        {:resource, resource.uri, resource_definition(resource), resource.callback,
         fault_classifier(resource)}

      :ets.insert(state.table, {resource_key(resource.uri), entry})
    end

    {:reply, :ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:unregister_resources, uris}, _from, state) do
    for uri <- uris do
      :ets.delete(state.table, resource_key(uri))
    end

    {:reply, :ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:register_prompts, prompts}, _from, state) do
    for prompt <- prompts do
      entry =
        {:prompt, prompt.name, prompt_definition(prompt), prompt.callback,
         fault_classifier(prompt)}

      :ets.insert(state.table, {prompt_key(prompt.name), entry})
    end

    {:reply, :ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:unregister_prompts, names}, _from, state) do
    for name <- names do
      :ets.delete(state.table, prompt_key(name))
    end

    {:reply, :ok, state}
  end

  # -- Private -----------------------------------------------------------------

  defp tool_key(name), do: {:tool, name}
  defp resource_key(uri), do: {:resource, uri}
  defp prompt_key(name), do: {:prompt, name}

  defp tool_definition(tool) do
    # `:annotations` is an MCP spec field (destructiveHint, readOnlyHint, ...)
    # and must survive onto the listed definition: clients read the hints from
    # `tools/list`, and `Raxol.MCP.Server`'s sensitive-tool guard reads them
    # back from here to decide what may run unguarded. `Map.take/2` ignores an
    # absent key, so an unannotated tool is unchanged.
    Map.take(tool, [:name, :description, :inputSchema, :annotations])
  end

  defp resource_definition(resource) do
    Map.take(resource, [:uri, :name, :description])
  end

  defp prompt_definition(prompt) do
    Map.take(prompt, [:name, :description, :arguments])
  end

  # -- Circuit breaker integration ----------------------------------------------

  # A breaker guards AVAILABILITY, so only an availability fault counts. A
  # callback that raises or exits is one. A callback that returns
  # `{:error, reason}` may be either: `:not_found` is an answer to the question
  # that was asked, and counting five of those as five faults quarantines a
  # tool that is working perfectly. Only the tool knows which of its own
  # reasons are which, so it may register a `:fault?` classifier; with none,
  # every error counts, which is what this did before.
  defp invoke_with_breaker(breaker_table, key, classifier, callback_fn) do
    case CircuitBreaker.check(breaker_table, key) do
      :open ->
        {:error, :circuit_open}

      _closed_or_half_open ->
        invoke(breaker_table, key, classifier, callback_fn)
    end
  end

  # `catch` is not decoration. `Raxol.MCP.Server` runs tool callbacks INLINE in
  # its own process with an `:infinity` call timeout (`server.ex:219-223`), and
  # a callback that reaches a dead or slow peer -- `GenServer.call` on a
  # `:noproc`, a call timeout -- exits rather than raises. With `rescue` alone
  # that exit propagated out of the ETS read and took the whole MCP server
  # down, dropping every connected session for one broken tool.
  #
  # The returned term names the exception STRUCT or the exit CLASS and nothing
  # else. `{:error, Exception.message(e)}` put upstream bytes in the return
  # value, and the return value is rendered into the `tools/call` response a
  # model reads: an `ArgumentError`, a `Jason.EncodeError` or a
  # `Protocol.UndefinedError` message embeds an `inspect` of the offending
  # value, so a broken or hostile upstream got text into a context through a
  # tool whose own error taxonomy carries none. The full message and its
  # stacktrace are logged here instead, where an operator wants them.
  defp invoke(breaker_table, key, classifier, callback_fn) do
    case callback_fn.() do
      {:ok, _} = ok ->
        CircuitBreaker.record_success(breaker_table, key)
        ok

      {:error, reason} = err ->
        if fault?(classifier, reason) do
          CircuitBreaker.record_failure(breaker_table, key)
        end

        err

      other ->
        CircuitBreaker.record_success(breaker_table, key)
        {:ok, other}
    end
  rescue
    error ->
      CircuitBreaker.record_failure(breaker_table, key)
      log_callback_failure(key, "raised", Exception.format(:error, error, __STACKTRACE__))
      {:error, {:callback_raised, error.__struct__}}
  catch
    :exit, reason ->
      CircuitBreaker.record_failure(breaker_table, key)
      log_callback_failure(key, "exited", Exception.format_exit(reason))
      {:error, {:callback_exited, exit_class(reason)}}

    :throw, value ->
      CircuitBreaker.record_failure(breaker_table, key)
      log_callback_failure(key, "threw", inspect(value))
      {:error, :callback_threw}
  end

  # Anything but an explicit `false` counts, so a classifier that falls through
  # protects the breaker instead of silently disabling it.
  defp fault?(nil, _reason), do: true
  defp fault?(classifier, reason), do: classifier.(reason) != false

  # The SHAPE of the exit, never its payload: `{:timeout, {GenServer, :call,
  # [pid, request, 5000]}}` carries the request, and this term is model-visible.
  defp exit_class(reason) when is_atom(reason), do: reason
  defp exit_class({reason, _detail}) when is_atom(reason), do: reason
  defp exit_class(_other), do: :unknown

  defp log_callback_failure(key, verb, detail) do
    Logger.error("[MCP.Registry] #{inspect(key)} callback #{verb}: #{detail}")
  end

  # A value that is not a 1-arity function is no classifier. `ToolDef.validate/1`
  # refuses one loudly at the `register_all/2` seam; a direct `register_tools/2`
  # falls back to the protective default rather than crashing a registration.
  defp fault_classifier(%{fault?: classifier}) when is_function(classifier, 1), do: classifier
  defp fault_classifier(_definition), do: nil

  # -- Table resolution --------------------------------------------------------

  # Resolve a registry name/pid to its ETS table reference.
  # The GenServer stores the table ref in its state, but we need it
  # from client processes. We use :sys.get_state for named processes.
  @table_cache :raxol_mcp_registry_tables
  @breaker_cache :raxol_mcp_registry_breakers

  defp get_table(registry) when is_atom(registry) do
    case :persistent_term.get({@table_cache, registry}, nil) do
      nil ->
        %{table: table} = :sys.get_state(registry)
        :persistent_term.put({@table_cache, registry}, table)
        table

      table ->
        table
    end
  end

  defp get_table(registry) do
    %{table: table} = :sys.get_state(registry)
    table
  end

  defp get_breaker_table(registry) when is_atom(registry) do
    case :persistent_term.get({@breaker_cache, registry}, nil) do
      nil ->
        %{breaker_table: bt} = :sys.get_state(registry)
        :persistent_term.put({@breaker_cache, registry}, bt)
        bt

      bt ->
        bt
    end
  end

  defp get_breaker_table(registry) do
    %{breaker_table: bt} = :sys.get_state(registry)
    bt
  end
end
