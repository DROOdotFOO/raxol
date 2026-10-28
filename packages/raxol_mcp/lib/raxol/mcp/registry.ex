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

  A tool registered with `register_tools(registry, tools, derived: true)` is a
  derived tool: `static_tools/1` lists only the others, and that is what
  `Raxol.MCP.Server`'s boot check scans. Only `Raxol.MCP.ToolSynchronizer`
  passes the option, for a session's tools (those `Raxol.MCP.TreeWalker`
  derives from its view, and its `discover_tools` meta-tool); a `:derived`
  key in a tool map is ignored.

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

  ## Owners

  `register_tools/3`, `register_resources/3` and `register_prompts/3` take an
  `owner: pid`. The registry monitors each owner, and when one exits it
  removes everything the owner still holds and, if that included tools,
  sends one `notifications/tools/list_changed` to its `:server` (start
  option, default `Raxol.MCP.Server`). Registering a name again moves it to
  the new registration's owner, or to none. A registration without an owner
  is never removed automatically, so a short-lived caller (a test, a task)
  does not take its tools with it when it exits.

  Unregistering, by name or by an owner's exit, also forgets the entry's
  circuit-breaker state. `await_owner_cleanup/2` is a barrier for callers
  that must not answer until a dead owner's entries are gone.
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

  @doc """
  Start the registry, linked to the calling process.

  `:server` names the `Raxol.MCP.Server` told when an owner's exit removes
  tools: an atom, a pid, `{:global, name}` or `{:via, module, name}`; any
  other value is `{:error, {:invalid_server, server}}` and starts nothing.
  The default is the application's `Raxol.MCP.Server`, so a registry started
  beside a private server passes that server here, or its owners' exits
  notify the application's clients instead.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    server = Keyword.get(opts, :server, Raxol.MCP.Server)

    if server_name?(server),
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: {:error, {:invalid_server, server}}
  end

  # `Raxol.MCP.Server.notify/3` casts to it from the DOWN handler, where a
  # value that is no server name would raise and take the registry down.
  defp server_name?(server) when is_atom(server) or is_pid(server), do: true
  defp server_name?({:global, _name}), do: true
  defp server_name?({:via, module, _name}) when is_atom(module), do: true
  defp server_name?(_server), do: false

  @doc """
  Register one or more tools.

  A client may rename tools: OMP (at the version
  `docs/adr/0042-lean-on-omp.md` pins) lowercases a tool name, turns each run
  of characters outside `[a-z0-9_]` into `_`, collapses repeated `_` and trims
  them from both ends (`omp_name/1`). Two distinct names that come out the
  same there, such as `"s.x_y.click"` and `"s.x.y.click"`, would reach the
  client as one tool. So a tool whose `omp_name/1` is already held by a
  differently named tool is refused, and the rest are registered:
  `{:error, {:name_collision, [{refused_name, holder_name}]}}`. Registering
  a name again replaces its tool, as before. `register_all/2` refuses the
  whole batch instead.

  A tool whose `:name` is not a binary (or that has none) refuses the whole
  batch, `{:error, {:invalid_tool_name, name}}`, and the registry keeps
  serving the tools it holds.

  `derived: true` registers them as derived, which leaves them out of
  `static_tools/1` and so out of `Raxol.MCP.Server`'s boot check (the
  `tools/call` refusal still holds them). It is for
  `Raxol.MCP.ToolSynchronizer` alone: a tool registered with it skips the
  check that refuses to boot an unguarded server on a sensitive tool.

  `owner: pid` makes the registration owned (see "Owners").
  """
  @spec register_tools(GenServer.server(), [tool_def()], keyword()) ::
          :ok
          | {:error, {:name_collision, [{String.t(), String.t()}]}}
          | {:error, {:invalid_tool_name, term()}}
  def register_tools(registry \\ __MODULE__, tools, opts \\ []) do
    if Keyword.get(opts, :derived, false) == true,
      do: GenServer.call(registry, {:register_derived_tools, tools, owner(opts)}),
      else: GenServer.call(registry, {:register_tools, tools, owner(opts)})
  end

  @doc """
  The name OMP (`mcp/tool-bridge.ts`, at the version ADR-0042 pins) makes of
  a tool name before it adds its `mcp__<server>_` prefix: lowercased, each run
  outside `[a-z0-9_]` turned into `_`, runs of `_` collapsed, `_` trimmed from
  both ends, and `"tool"` if nothing is left.

  OMP also strips an exact `<server>_` prefix from the result once, which
  this does not model. Raxol's server key is `raxol`, so `raxol_start`
  refuses the session id `raxol`: that session's `raxol.nav_menu.click`
  would reach OMP as session `nav`'s `nav.menu.click`. OMP's 64-character
  limit (55 characters, `_` and an 8-character hash) applies to the prefixed
  name and, barring a hash collision, keeps distinct names distinct, so it
  is not modeled either: past it OMP shows a hashed name, about which
  `Raxol.MCP.ToolSynchronizer` warns.
  """
  @spec omp_name(String.t()) :: String.t()
  def omp_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "tool"
      cleaned -> cleaned
    end
  end

  @doc """
  Registers tools and/or resources in one call after validating each tool
  shape via `Raxol.MCP.ToolDef.validate/1`.

  Reduces the common consumer boilerplate:

      :ok = Registry.register_tools(registry, tools)
      :ok = Registry.register_resources(registry, resources)

  to a single call:

      :ok = Registry.register_all(registry, tools: tools, resources: resources)

  Returns `{:error, {:invalid_tool, index, reasons}}` when validation fails
  and `{:error, {:name_collision, [{refused_name, holder_name}]}}` when a
  tool's `omp_name/1` is taken, by a registered tool or by another tool in
  the batch. Either way nothing is registered: no tools, resources or
  prompts.

  Note: this helper requires the `Raxol.MCP.Registry` module to be loaded
  at runtime. Consumers with `raxol_mcp` as an optional dep should still
  gate the call with `Code.ensure_loaded?(Raxol.MCP.Registry)`. Optional
  deps are an Elixir-level concern; no helper can paper over a missing
  module.
  """
  @spec register_all(GenServer.server(), keyword()) ::
          :ok
          | {:error, {:invalid_tool, non_neg_integer(), [atom()]}}
          | {:error, {:name_collision, [{String.t(), String.t()}]}}
  def register_all(registry \\ __MODULE__, opts) when is_list(opts) do
    tools = Keyword.get(opts, :tools, [])
    resources = Keyword.get(opts, :resources, [])
    prompts = Keyword.get(opts, :prompts, [])

    with :ok <- validate_tools(tools),
         :ok <- register_whole(registry, tools) do
      if resources != [], do: :ok = register_resources(registry, resources)
      if prompts != [], do: :ok = register_prompts(registry, prompts)
      :ok
    end
  end

  defp register_whole(_registry, []), do: :ok

  defp register_whole(registry, tools),
    do: GenServer.call(registry, {:register_tools, tools, nil, :all_or_nothing})

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

  @doc """
  Unregister tools by name.

  With `owner: pid`, only the named tools `pid` still owns go (see
  "Owners"): a name another owner has registered since stays.
  """
  @spec unregister_tools(GenServer.server(), [String.t()], keyword()) :: :ok
  def unregister_tools(registry \\ __MODULE__, names, opts \\ []) do
    GenServer.call(registry, {:unregister_tools, names, owner(opts)})
  end

  @doc "List all registered tools (definitions without callbacks)."
  @spec list_tools(GenServer.server()) :: [map()]
  def list_tools(registry \\ __MODULE__) do
    table = get_table(registry)

    :ets.select(table, [
      {{:"$1", {:tool, :"$2", :"$3", :_, :_, :_}}, [], [:"$3"]}
    ])
  end

  @doc """
  `list_tools/1` without the tools registered with `derived: true`: the
  tools an embedder registered itself, rather than a session's view.
  """
  @spec static_tools(GenServer.server()) :: [map()]
  def static_tools(registry \\ __MODULE__) do
    table = get_table(registry)

    :ets.select(table, [
      {{:"$1", {:tool, :"$2", :"$3", :_, :_, false}}, [], [:"$3"]}
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
      [{_key, {:tool, ^name, _def, callback, classifier, _derived}}] ->
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
    register_resources(registry, resources, [])
  end

  @doc "`register_resources/2` with `owner: pid` (see \"Owners\")."
  @spec register_resources(GenServer.server(), [resource_def()], keyword()) :: :ok
  def register_resources(registry, resources, opts) when is_list(opts) do
    GenServer.call(registry, {:register_resources, resources, owner(opts)})
  end

  @doc """
  Unregister resources by URI. With `owner: pid`, only those `pid` still
  owns (see `unregister_tools/3`).
  """
  @spec unregister_resources(GenServer.server(), [String.t()], keyword()) :: :ok
  def unregister_resources(registry \\ __MODULE__, uris, opts \\ []) do
    GenServer.call(registry, {:unregister_resources, uris, owner(opts)})
  end

  @doc "Wait until the registry holds no tools, resources or prompts for `owner`."
  @spec await_owner_cleanup(GenServer.server(), pid()) :: :ok
  def await_owner_cleanup(registry \\ __MODULE__, owner) when is_pid(owner) do
    GenServer.call(registry, {:await_owner_cleanup, owner})
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
    register_prompts(registry, prompts, [])
  end

  @doc "`register_prompts/2` with `owner: pid` (see \"Owners\")."
  @spec register_prompts(GenServer.server(), [prompt_def()], keyword()) :: :ok
  def register_prompts(registry, prompts, opts) when is_list(opts) do
    GenServer.call(registry, {:register_prompts, prompts, owner(opts)})
  end

  defp owner(opts) do
    case Keyword.get(opts, :owner) do
      nil -> nil
      pid when is_pid(pid) -> pid
      other -> raise ArgumentError, "owner must be a pid, got: #{inspect(other)}"
    end
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

    {:ok,
     %{
       table: table,
       breaker_table: breaker_table,
       server: Keyword.get(opts, :server, Raxol.MCP.Server),
       # owner pid => %{ref: monitor, keys: entries it holds, waiters: callers
       # waiting for those entries to be removed}; `held_by` is the reverse
       # map. Entries are ETS keys: {:tool | :resource | :prompt, _}.
       owners: %{},
       held_by: %{}
     }}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:register_tools, tools, owner}, _from, state) do
    register_each(state, tools, false, owner)
  end

  def handle_manager_call({:register_derived_tools, tools, owner}, _from, state) do
    register_each(state, tools, true, owner)
  end

  # `register_all/2`'s batch: checked whole before anything is inserted, so a
  # refusal leaves the table as it was.
  def handle_manager_call({:register_tools, tools, owner, :all_or_nothing}, from, state) do
    with :ok <- refuse_invalid_names(tools),
         [] <- collisions(state.table, tools) do
      handle_manager_call({:register_tools, tools, owner}, from, state)
    else
      [_ | _] = refused -> {:reply, {:error, {:name_collision, refused}}, state}
      refusal -> {:reply, refusal, state}
    end
  end

  def handle_manager_call({:unregister_tools, names, owner}, _from, state) do
    names = Enum.filter(names, &held?(state, tool_key(&1), owner))
    state = Enum.reduce(names, state, &remove(&2, tool_key(&1)))

    :telemetry.execute(
      [:raxol, :mcp, :registry, :tools_changed],
      %{count: length(names)},
      %{action: :unregister, names: names}
    )

    {:reply, :ok, state}
  end

  def handle_manager_call({:register_resources, resources, owner}, _from, state) do
    state =
      Enum.reduce(resources, state, fn resource, state ->
        entry =
          {:resource, resource.uri, resource_definition(resource), resource.callback,
           fault_classifier(resource)}

        :ets.insert(state.table, {resource_key(resource.uri), entry})
        register_entry(state, resource_key(resource.uri), owner)
      end)

    {:reply, :ok, state}
  end

  def handle_manager_call({:unregister_resources, uris, owner}, _from, state) do
    keys = for uri <- uris, held?(state, resource_key(uri), owner), do: resource_key(uri)
    {:reply, :ok, Enum.reduce(keys, state, &remove(&2, &1))}
  end

  def handle_manager_call({:register_prompts, prompts, owner}, _from, state) do
    state =
      Enum.reduce(prompts, state, fn prompt, state ->
        entry =
          {:prompt, prompt.name, prompt_definition(prompt), prompt.callback,
           fault_classifier(prompt)}

        :ets.insert(state.table, {prompt_key(prompt.name), entry})
        register_entry(state, prompt_key(prompt.name), owner)
      end)

    {:reply, :ok, state}
  end

  def handle_manager_call({:unregister_prompts, names}, _from, state) do
    {:reply, :ok, Enum.reduce(names, state, &remove(&2, prompt_key(&1)))}
  end

  def handle_manager_call({:await_owner_cleanup, owner}, from, state) do
    case Map.fetch(state.owners, owner) do
      {:ok, entry} ->
        owners = Map.put(state.owners, owner, %{entry | waiters: [from | entry.waiters]})
        {:noreply, %{state | owners: owners}}

      :error ->
        {:reply, :ok, state}
    end
  end

  # An owner exited: everything it still holds goes, and a client listing
  # tools hears once that they changed.
  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.fetch(state.owners, pid) do
      {:ok, %{ref: ^ref, keys: keys}} ->
        state = Enum.reduce(keys, state, &remove(&2, &1))
        tool_names = for {:tool, name} <- keys, do: name

        if tool_names != [] do
          :telemetry.execute(
            [:raxol, :mcp, :registry, :tools_changed],
            %{count: length(tool_names)},
            %{action: :unregister, names: tool_names}
          )

          Raxol.MCP.Server.notify(state.server, "notifications/tools/list_changed", %{})
        end

        {:noreply, state}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # -- Private -----------------------------------------------------------------

  defp tool_key(name), do: {:tool, name}
  defp omp_key(name), do: {:omp_name, omp_name(name)}
  defp resource_key(uri), do: {:resource, uri}
  defp prompt_key(name), do: {:prompt, name}

  # A tool's name keys its row and its client-side name (`omp_name/1` takes a
  # binary), so a batch holding a tool without a binary name is refused before
  # anything is inserted. Raising here instead would take the registry, and
  # every tool it holds, down with the caller's mistake.
  defp refuse_invalid_names(tools) do
    Enum.find_value(tools, :ok, fn
      %{name: name} when is_binary(name) -> nil
      %{name: name} -> {:error, {:invalid_tool_name, name}}
      _no_name -> {:error, {:invalid_tool_name, nil}}
    end)
  end

  defp register_each(state, tools, derived?, owner) do
    case refuse_invalid_names(tools) do
      :ok ->
        {reply, registered} = insert_tools(state.table, tools, derived?)
        {:reply, reply, Enum.reduce(registered, state, &register_entry(&2, tool_key(&1), owner))}

      refusal ->
        {:reply, refusal, state}
    end
  end

  # Answers the reply and the names inserted, in order.
  defp insert_tools(table, tools, derived?) do
    {registered, refused} =
      Enum.reduce(tools, {[], []}, fn tool, {registered, refused} ->
        case insert_tool(table, tool, derived?) do
          :ok -> {[tool.name | registered], refused}
          {:taken, holder} -> {registered, [{tool.name, holder} | refused]}
        end
      end)

    registered = Enum.reverse(registered)

    :telemetry.execute(
      [:raxol, :mcp, :registry, :tools_changed],
      %{count: length(registered)},
      %{action: :register, names: registered}
    )

    case refused do
      [] -> {:ok, registered}
      _ -> {{:error, {:name_collision, Enum.reverse(refused)}}, registered}
    end
  end

  # Deletes an entry, its circuit-breaker row and its ownership.
  defp remove(state, {:tool, name} = key) do
    # A name `register_tools/3` would refuse has no client-side name row.
    if is_binary(name), do: :ets.delete_object(state.table, {omp_key(name), name})
    remove_entry(state, key)
  end

  defp remove(state, key), do: remove_entry(state, key)

  defp remove_entry(state, key) do
    :ets.delete(state.table, key)
    CircuitBreaker.reset(state.breaker_table, key)
    disown(state, key)
  end

  # A registration starts with a closed circuit: a call to the name's previous
  # holder that finished after it was unregistered recorded its result on a
  # row nobody owns, and the next registration must not inherit it.
  defp register_entry(state, key, owner) do
    CircuitBreaker.reset(state.breaker_table, key)
    own(state, key, owner)
  end

  # Unregistering without an owner takes the entry whoever holds it; with
  # one, only if that owner still does.
  defp held?(_state, _key, nil), do: true
  defp held?(state, key, owner), do: Map.get(state.held_by, key) == owner

  # The latest registration of an entry decides its owner, or that it has none.
  defp own(state, key, owner) do
    if Map.get(state.held_by, key) == owner do
      state
    else
      state |> disown(key) |> hold(key, owner)
    end
  end

  defp hold(state, _key, nil), do: state

  defp hold(state, key, owner) do
    entry =
      Map.get_lazy(state.owners, owner, fn ->
        %{ref: Process.monitor(owner), keys: MapSet.new(), waiters: []}
      end)

    %{
      state
      | owners: Map.put(state.owners, owner, %{entry | keys: MapSet.put(entry.keys, key)}),
        held_by: Map.put(state.held_by, key, owner)
    }
  end

  defp disown(state, key) do
    case Map.pop(state.held_by, key) do
      {nil, _held_by} ->
        state

      {owner, held_by} ->
        %{ref: ref, keys: keys} = entry = Map.fetch!(state.owners, owner)
        keys = MapSet.delete(keys, key)

        owners =
          if MapSet.size(keys) == 0 do
            Process.demonitor(ref, [:flush])
            Enum.each(entry.waiters, &GenServer.reply(&1, :ok))
            Map.delete(state.owners, owner)
          else
            Map.put(state.owners, owner, %{entry | keys: keys})
          end

        %{state | held_by: held_by, owners: owners}
    end
  end

  # The `{:omp_name, _}` row records which tool holds a client-side name.
  defp insert_tool(table, tool, derived?) do
    key = omp_key(tool.name)

    case :ets.lookup(table, key) do
      [{^key, holder}] when holder != tool.name ->
        {:taken, holder}

      _free_or_own ->
        entry =
          {:tool, tool.name, tool_definition(tool), tool.callback, fault_classifier(tool),
           derived?}

        :ets.insert(table, [{tool_key(tool.name), entry}, {key, tool.name}])
        :ok
    end
  end

  # The refusals `insert_tool/3` would make for `tools`, in order, without
  # inserting anything: against the table and against earlier tools in the
  # batch.
  defp collisions(table, tools) do
    {_held, refused} =
      Enum.reduce(tools, {%{}, []}, fn tool, {held, refused} ->
        key = omp_key(tool.name)
        holder = Map.get_lazy(held, key, fn -> holder(table, key) end)

        if holder in [nil, tool.name],
          do: {Map.put(held, key, tool.name), refused},
          else: {held, [{tool.name, holder} | refused]}
      end)

    Enum.reverse(refused)
  end

  defp holder(table, key) do
    case :ets.lookup(table, key) do
      [{^key, holder}] -> holder
      [] -> nil
    end
  end

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
