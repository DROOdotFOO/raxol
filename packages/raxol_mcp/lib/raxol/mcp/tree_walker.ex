defmodule Raxol.MCP.TreeWalker do
  @moduledoc """
  Traverses a view element tree and derives namespaced MCP tools from widgets.

  The view tree is the output of a TEA app's `view/1` function -- nested maps
  with `:type`, `:id`, `:attrs`, `:children` keys. TreeWalker walks this tree,
  finds widgets that implement `Raxol.MCP.ToolProvider`, calls `mcp_tools/1`
  to get tool specs, namespaces them by session and widget ID, and wraps
  callbacks that dispatch TEA messages through the session's Dispatcher.

  ## Usage

      context = %{dispatcher_pid: dispatcher_pid, session_id: "demo"}
      tools = TreeWalker.derive_tools(view_tree, context)
      Raxol.MCP.Registry.register_tools(tools)

  Tool names are namespaced as `"session_id.widget_id.action"`, e.g.,
  `"demo.search_input.type_into"`, so two sessions rendering the same widget
  each get their own tool. Nodes without an `:id` key are skipped (layout
  containers like `:column`, `:row`). The session id and the widget id become
  part of a tool name the client lists, so a session whose id is not 1-32
  characters of `[A-Za-z0-9_-]` derives no tools at all, and a provider whose
  widget id is not derives none of its own (`id?/1`). Neither may hold a `.`,
  so the first segment of a derived name is always its whole session id. The
  action name is the last segment: one that is not a lowercase letter
  followed by up to 31 of `[a-z0-9_]` derives no tool.

  Everything else a provider writes reaches the client's tool list as well,
  which a model reads as instructions. Control, format (bidi, zero-width,
  BOM, tag), line/paragraph separator, private-use and invisible filler
  characters (variation selectors, combining grapheme joiner, Hangul
  fillers, braille blank) are stripped from a tool's `description` and from
  every string and every key inside its `inputSchema` (titles, enums,
  defaults, examples, property names). Of a spec's `annotations` only
  `sensitive: true` and `destructiveHint: true` are kept: they can only add
  the authorizer requirement, while any other key (`title`, `readOnlyHint`,
  ...) is a provider's self-report a client would act on.

  An atom is encoded as its name, so it is cleaned as that name: a
  `description` atom becomes its cleaned name, and a schema key or leaf
  atom stays an atom when its name is clean and becomes the cleaned string
  otherwise. A spec derives no tool, and is refused like a misnamed action,
  when its `description` is neither a string nor an atom (`nil` means none),
  when its `inputSchema` holds anything JSON cannot encode (a tuple, a
  struct, a pid, a function, an improper list, a key that is neither a
  string nor an atom), when two keys of one map are equal once cleaned
  and stringified (`:amount` and `"amount"`, or `"amount"` and
  `"amount\\u200B"`), or when its `inputSchema` nests maps and lists deeper
  than 32 levels or holds more than 10,000 values (each map, list and leaf
  counts one). One such spec would otherwise make every client's
  `tools/list` unencodable, let one property definition silently replace
  another, or hold up every render while it is cleaned.

  A derived tool is registered as one by `Raxol.MCP.ToolSynchronizer`
  (`Raxol.MCP.Registry.register_tools/3` with `derived: true`), which is
  what `Raxol.MCP.Server`'s boot check reads to tell it from a static tool.

  ## Excluding Widgets

  Set `mcp_exclude: true` in a widget's attrs to suppress tool derivation:

      %{type: :text_input, id: "internal", attrs: %{mcp_exclude: true}}

  The widget and its children still render normally -- only MCP tool
  exposure is suppressed. Useful for decorative or internal widgets.

  ## Explicit provider marker (`attrs.component_module`)

  Components whose root emits a plain layout type (`:column`, `:row`) can
  declare their providing module explicitly instead of growing this
  package's type map (the harness block Components do this):

      %{type: :column, id: "blk", attrs: %{component_module: MyBlock}}

  An explicit marker wins over the built-in type map; the same
  `ToolProvider` guard applies, so a module that does not implement the
  behaviour still derives nothing, and a non-atom marker is ignored.
  """

  alias Raxol.MCP.ToolProvider

  require Logger

  # Widget type atoms -> module names. These are in main raxol, so we use
  # @compile to suppress undefined warnings for cross-package references.
  @compile {:no_warn_undefined,
            [
              Raxol.UI.Components.Input.Button,
              Raxol.UI.Components.Input.TextInput,
              Raxol.UI.Components.Input.SelectList,
              Raxol.UI.Components.Input.Checkbox,
              Raxol.UI.Components.Input.Tabs,
              Raxol.UI.Components.Input.TextArea,
              Raxol.UI.Components.Input.Menu,
              Raxol.UI.Components.Input.PasswordField,
              Raxol.UI.Components.Display.Tree,
              Raxol.UI.Components.Display.Viewport,
              Raxol.UI.Components.Modal,
              Raxol.UI.Components.Table,
              Raxol.UI.Charts.BarChart,
              Raxol.UI.Charts.LineChart,
              Raxol.UI.Charts.ScatterChart,
              Raxol.UI.Components.Input.Scrubber
            ]}

  @default_type_map %{
    button: Raxol.UI.Components.Input.Button,
    text_input: Raxol.UI.Components.Input.TextInput,
    select_list: Raxol.UI.Components.Input.SelectList,
    checkbox: Raxol.UI.Components.Input.Checkbox,
    tabs: Raxol.UI.Components.Input.Tabs,
    text_area: Raxol.UI.Components.Input.TextArea,
    menu: Raxol.UI.Components.Input.Menu,
    password_field: Raxol.UI.Components.Input.PasswordField,
    tree: Raxol.UI.Components.Display.Tree,
    viewport: Raxol.UI.Components.Display.Viewport,
    modal: Raxol.UI.Components.Modal,
    table: Raxol.UI.Components.Table,
    bar_chart: Raxol.UI.Charts.BarChart,
    line_chart: Raxol.UI.Charts.LineChart,
    scatter_chart: Raxol.UI.Charts.ScatterChart,
    scrubber: Raxol.UI.Components.Input.Scrubber
  }

  @type context :: %{
          required(:session_id) => String.t(),
          optional(:dispatcher_pid) => pid() | nil,
          optional(:type_map) => %{atom() => module()},
          optional(:view) => (-> {:ok, map() | [map()]} | {:error, term()}),
          optional(:synced) => (-> term())
        }

  @doc """
  The built-in declaration-type -> Component-module map used when `context`
  carries no `:type_map`.

  Exposed so the main app can assert it against `Raxol.UI.Registry`; this
  package cannot derive the map from that registry (main raxol is not a
  dependency), so conformance is a test, not a compile-time guarantee.
  """
  @spec default_type_map() :: %{atom() => module()}
  def default_type_map, do: @default_type_map

  @typedoc """
  Why a provider derived less than it declared: `{:widget_id, id}` for a
  widget whose id derives no tools, `{:action_name, widget_id, name}` for
  one spec whose action name derives no tool, `{:action_spec, widget_id,
  name, fault}` for one whose description or input schema does (see the
  moduledoc).
  """
  @type refusal ::
          {:widget_id, String.t()}
          | {:action_name, String.t(), term()}
          | {:action_spec, String.t(), String.t(), spec_fault()}

  @typedoc """
  `:not_json` for a term JSON cannot encode, `{:duplicate_key, key}` for two
  keys that are both `key` once cleaned, `:too_large` for an input schema
  deeper than 32 levels or larger than 10,000 values.
  """
  @type spec_fault :: :not_json | {:duplicate_key, String.t()} | :too_large

  @doc """
  Derives MCP tool definitions from a view element tree, and logs every
  refusal (a widget id, action name or action spec that derives nothing) as
  a warning.

  Returns a list of `Registry.tool_def()` maps with namespaced names and
  wrapped callbacks that dispatch TEA messages. Also logs a session id
  refused (`id?/1`). A caller that derives on every render and wants each
  refusal logged once uses `derive_with_refusals/2` instead.

  ## Options in context

    * `:session_id` - the session's id, the first segment of every tool name
      (required)
    * `:dispatcher_pid` - pid of the session's Dispatcher (for message dispatch)
    * `:type_map` - optional override for widget type -> module mapping
    * `:view` - a function answering the session's current view tree,
      `{:ok, tree}` or `{:error, reason}`. With it, every call resolves its
      widget by id in that tree, so it acts on the widget as it is now, not
      as it was when the tool was derived. Without it (a static tree), a call
      acts on the node it was derived from.
    * `:synced` - a function called after a call's messages have been
      dispatched and before it answers, to bring the session's tool set up
      to date with their effect

  ## Live resolution

  With `:view` in the context, a call whose widget is no longer in the view,
  no longer offers the action (a disabled Button offers none) or is now
  another kind of widget answers `{:error, {:widget_unavailable, widget_id,
  :absent | :disabled | :type_changed}}` (`widget_unavailable?/1`). Those
  answers are about the question, not the tool's health, so they never count
  toward its circuit breaker (`:fault?`). When several widgets in the view
  share the id, the call acts on the first, in view order, that is of the
  tool's kind and offers the action. A call into a session whose dispatcher
  has exited answers `{:error, {:session_not_running, session_id}}`.

  Every tool also carries `:provider`, the widget's module: with its name and
  listed definition it is what `Raxol.MCP.ToolSynchronizer` keys a session's
  tool set on.
  """
  @spec derive_tools(map() | [map()], context()) :: [
          Raxol.MCP.Registry.tool_def()
        ]
  def derive_tools(tree, context) do
    if not id?(Map.fetch!(context, :session_id)),
      do: warn_refused_session_id(context.session_id)

    {tools, refusals} = derive_with_refusals(tree, context)
    Enum.each(refusals, &warn_refusal/1)
    tools
  end

  @doc """
  `derive_tools/2` without logging: returns the tools and the set of
  refusals (see `t:refusal/0`) instead. A session id that is not (`id?/1`)
  derives no tools and refuses no widget. A caller that derives on every
  render (`Raxol.MCP.ToolSynchronizer`) logs each new refusal once with
  `warn_refusal/1`, and a refused session id with
  `warn_refused_session_id/1`.
  """
  @spec derive_with_refusals(map() | [map()], context()) ::
          {[Raxol.MCP.Registry.tool_def()], MapSet.t(refusal())}
  def derive_with_refusals(tree, context) do
    if id?(Map.fetch!(context, :session_id)) do
      type_map = Map.get(context, :type_map, @default_type_map)
      do_walk(tree, context, type_map, {[], MapSet.new()})
    else
      {[], MapSet.new()}
    end
  end

  # A session or widget id is one segment of a listed tool name, so the cap
  # bounds that segment: a view cannot list names of unbounded length. 32 is
  # a bound, not a fit to any client's name limit; session prefix + id +
  # action can still exceed one (OMP's 64, which counts its own prefix too).
  @id ~r/\A[A-Za-z0-9_-]{1,32}\z/

  @doc """
  Whether `id` may be a segment of a derived tool name: a binary of 1-32
  characters of `[A-Za-z0-9_-]`. The session id and every widget id must be.
  A segment is the text the client lists, so it holds no `.` (which would
  read as a segment boundary) and no control or format characters.
  """
  @spec id?(term()) :: boolean()
  def id?(id) when is_binary(id), do: Regex.match?(@id, id)
  def id?(_id), do: false

  @unavailable_reasons [:absent, :disabled, :type_changed]

  @doc """
  Whether `reason` is the `{:widget_unavailable, widget_id, why}` a derived
  tool answers (see "Live resolution" in `derive_tools/2`): `widget_id`
  passes `id?/1` and `why` is `:absent`, `:disabled` or `:type_changed`. Any
  tool can return a term of that shape, so this is what makes it safe to name
  the widget to a client.
  """
  @spec widget_unavailable?(term()) :: boolean()
  def widget_unavailable?({:widget_unavailable, widget_id, why}),
    do: why in @unavailable_reasons and id?(widget_id)

  def widget_unavailable?(_reason), do: false

  # The last segment, the action name. Every built-in action (`click`,
  # `get_visible_range`, ...) is lowercase snake case; the same 32 bounds it.
  @action_name ~r/\A[a-z][a-z0-9_]{0,31}\z/

  # Cleaning walks a provider's whole input schema on every render, and a
  # shared subterm doubles per level once walked as a tree; these bound it.
  @max_schema_depth 32
  @max_schema_values 10_000

  @doc "Logs why `refusal` derived nothing."
  @spec warn_refusal(refusal()) :: :ok
  def warn_refusal({:widget_id, id}) do
    Logger.warning(
      "[MCP.TreeWalker] widget id #{inspect(id)} derives no tools: an id must be " <>
        "1-32 characters of [A-Za-z0-9_-]"
    )
  end

  def warn_refusal({:action_name, widget_id, name}) do
    Logger.warning(
      "[MCP.TreeWalker] widget #{inspect(widget_id)} action #{inspect(name)} derives " <>
        "no tool: an action name must be a lowercase letter followed by up to 31 " <>
        "of [a-z0-9_]"
    )
  end

  def warn_refusal({:action_spec, widget_id, name, :not_json}) do
    Logger.warning(
      "[MCP.TreeWalker] widget #{inspect(widget_id)} action #{inspect(name)} derives " <>
        "no tool: its description is not a string or atom, or its inputSchema holds " <>
        "a term JSON cannot encode (a tuple, struct, pid, function, improper list or " <>
        "a key that is not a string or atom)"
    )
  end

  def warn_refusal({:action_spec, widget_id, name, {:duplicate_key, key}}) do
    Logger.warning(
      "[MCP.TreeWalker] widget #{inspect(widget_id)} action #{inspect(name)} derives " <>
        "no tool: two inputSchema keys of one map are both #{inspect(key)} once cleaned"
    )
  end

  def warn_refusal({:action_spec, widget_id, name, :too_large}) do
    Logger.warning(
      "[MCP.TreeWalker] widget #{inspect(widget_id)} action #{inspect(name)} derives " <>
        "no tool: its inputSchema nests deeper than #{@max_schema_depth} maps and lists " <>
        "or holds more than #{@max_schema_values} values"
    )
  end

  @doc "Logs that the session `id` derives no tools because of its id."
  @spec warn_refused_session_id(term()) :: :ok
  def warn_refused_session_id(id) do
    Logger.warning(
      "[MCP.TreeWalker] session id #{inspect(id)} derives no tools: an id must be " <>
        "1-32 characters of [A-Za-z0-9_-]"
    )
  end

  @doc """
  Whether `name` may name an action: a lowercase letter followed by up to 31
  of `[a-z0-9_]`. It becomes part of a listed tool name.
  """
  @spec action_name?(term()) :: boolean()
  def action_name?(name), do: is_binary(name) and Regex.match?(@action_name, name)

  @doc """
  An action spec's `description` and `inputSchema` as the client's tool list
  gets them: cleaned as the moduledoc describes, or the `t:spec_fault/0`
  that refuses the spec. `Raxol.MCP.AgentBridge` applies it to an Action's
  meta.
  """
  @spec clean_spec(term(), term()) :: {:ok, String.t() | nil, term()} | {:error, spec_fault()}
  def clean_spec(description, input_schema) do
    with {:ok, description} <- clean_description(description),
         {:ok, schema, _budget} <- clean_schema(input_schema, 0, @max_schema_values) do
      {:ok, description, schema}
    end
  end

  defp do_walk(nodes, context, type_map, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &do_walk(&1, context, type_map, &2))
  end

  defp do_walk(%{type: type, id: id} = node, context, type_map, acc)
       when is_atom(type) and is_binary(id) and id != "" do
    acc = do_walk(child_nodes(node), context, type_map, acc)
    add_widget_tools(widget_specs(node, type, type_map), node, id, context, acc)
  end

  defp do_walk(%{children: _} = node, context, type_map, acc) do
    do_walk(child_nodes(node), context, type_map, acc)
  end

  # An `:absolute_layer` (Raxol.UI.Components.AbsoluteLayer) parents its
  # subtree through `:flow_child` + `:overlays[].element`, not `:children`,
  # and carries no `:id` of its own -- so without these clauses the walker
  # would stop at it and every overlay Component hosted over the transcript
  # (pickers, panels, dialogs) would derive zero tools. Walk into both so an
  # overlay Component's stamped root is reached exactly as a flow child's is.
  defp do_walk(%{flow_child: _} = node, context, type_map, acc) do
    do_walk(child_nodes(node), context, type_map, acc)
  end

  defp do_walk(%{overlays: _} = node, context, type_map, acc) do
    do_walk(child_nodes(node), context, type_map, acc)
  end

  defp do_walk(_node, _context, _type_map, acc), do: acc

  defp add_widget_tools(nil, _node, _id, _context, acc), do: acc

  defp add_widget_tools({module, specs}, node, id, context, {tools, refusals}) do
    if id?(id) do
      {named, misnamed} = Enum.split_with(specs, &action_name?(Map.get(&1, :name)))
      refusals = Enum.into(misnamed, refusals, &{:action_name, id, Map.get(&1, :name)})

      {built, refusals} =
        Enum.flat_map_reduce(named, refusals, &add_action(&1, &2, id, module, node, context))

      {built ++ tools, refusals}
    else
      {tools, MapSet.put(refusals, {:widget_id, id})}
    end
  end

  defp add_action(spec, refusals, id, module, node, context) do
    case build_tool_def(spec, id, module, node, context) do
      {:ok, tool} -> {[tool], refusals}
      {:error, fault} -> {[], MapSet.put(refusals, {:action_spec, id, spec.name, fault})}
    end
  end

  # The View DSL allows :children to be a list or a single element map
  # (e.g. a box whose do-block is one column). Mirror the Bubbler's
  # path-finding, which treats both shapes as first-class. An
  # `:absolute_layer` also contributes its flow child + overlay elements
  # (see the flow_child/overlays clauses above).
  defp child_nodes(node) do
    direct =
      case Map.get(node, :children) do
        kids when is_list(kids) -> kids
        kid when is_map(kid) -> [kid]
        _ -> []
      end

    direct ++ absolute_layer_children(node)
  end

  # The `:absolute_layer` overlay wiring: the flow child plus each
  # overlay's `:element`. Absent on ordinary nodes (both default to []), so
  # this is a no-op everywhere except an absolute layer.
  defp absolute_layer_children(node) do
    flow =
      case Map.get(node, :flow_child) do
        child when is_map(child) -> [child]
        _ -> []
      end

    overlay_elements =
      node
      |> Map.get(:overlays, [])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{element: element} when is_map(element) -> [element]
        _ -> []
      end)

    flow ++ overlay_elements
  end

  # The provider module and its specs, or nil for a node that derives nothing
  # (excluded, no provider, or no specs).
  defp widget_specs(node, type, type_map) do
    module = resolve_module(node, type, type_map)

    if not mcp_excluded?(node) and module != nil and ToolProvider.tool_provider?(module) do
      case module.mcp_tools(node) do
        [_ | _] = specs -> {module, specs}
        _none -> nil
      end
    end
  end

  # An explicit `attrs.component_module` declaration wins over the
  # built-in type map (the marker exists precisely for nodes whose :type
  # is a plain layout container). `ToolProvider.tool_provider?/1` guards
  # both paths, so an arbitrary/unloaded module still derives nothing.
  defp resolve_module(node, type, type_map) do
    case node do
      %{attrs: %{component_module: module}} when is_atom(module) and not is_nil(module) ->
        module

      _no_marker ->
        Map.get(type_map, type)
    end
  end

  # The tool list is read by a model as instructions: a forged line break, a
  # bidi override, invisible tag characters or variation selectors (which can
  # carry arbitrary bytes invisibly) there are a prompt-injection channel. The
  # built-in providers keep their specs static per action; this holds for any
  # other provider as well. Control (C0, C1, DEL), format (bidi, zero-width,
  # BOM, tag), line/paragraph separator and private-use characters, the
  # variation selectors (U+FE00-FE0F, U+E0100-E01EF), the combining grapheme
  # joiner (U+034F), the Hangul fillers (U+115F, U+1160, U+3164, U+FFA0) and
  # the braille blank (U+2800).
  @unsafe_chars ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Co}\x{FE00}-\x{FE0F}\x{E0100}-\x{E01EF}\x{034F}\x{115F}\x{1160}\x{3164}\x{FFA0}\x{2800}]/u

  defp build_tool_def(spec, widget_id, module, node, context) do
    with {:ok, description, schema} <-
           clean_spec(Map.get(spec, :description), Map.get(spec, :inputSchema)) do
      %{
        name: "#{Map.fetch!(context, :session_id)}.#{widget_id}.#{spec.name}",
        description: description,
        inputSchema: schema,
        provider: module,
        fault?: &fault?/1,
        callback: fn args -> call_action(spec.name, args, widget_id, module, node, context) end
      }
      |> put_annotations(Map.get(spec, :annotations))
      |> then(&{:ok, &1})
    end
  end

  defp call_action(action_name, args, widget_id, module, node, context) do
    with :ok <- dispatcher_alive(context),
         {:ok, live} <- live_node(widget_id, module, action_name, node, context) do
      tool_context = %{
        widget_id: widget_id,
        widget_state: live,
        dispatcher_pid: context[:dispatcher_pid]
      }

      action_name
      |> module.handle_tool_call(args, tool_context)
      |> answer(context)
    end
  end

  defp answer({:ok, result, messages}, context) do
    with :ok <- dispatch_messages(messages, context[:dispatcher_pid]) do
      synced(context)
      {:ok, format_result(result)}
    end
  end

  defp answer({:ok, result}, _context), do: {:ok, format_result(result)}
  defp answer({:error, reason}, _context), do: {:error, reason}

  # Answers about the widget, not the tool's health: the breaker must not
  # open on a dismissed modal's tool and stay open when it reopens.
  defp fault?(reason), do: not widget_unavailable?(reason)

  defp dispatcher_alive(%{dispatcher_pid: pid, session_id: session_id}) when is_pid(pid) do
    if Process.alive?(pid), do: :ok, else: {:error, {:session_not_running, session_id}}
  end

  defp dispatcher_alive(_context), do: :ok

  defp live_node(_widget_id, _module, _action, node, context)
       when not is_map_key(context, :view),
       do: {:ok, node}

  defp live_node(widget_id, module, action, _node, context) do
    with {:ok, tree} <- context.view.() do
      type_map = Map.get(context, :type_map, @default_type_map)
      tree |> find_nodes(widget_id) |> pick_live(widget_id, module, action, type_map)
    end
  end

  # Ids are not unique in every view, and `do_walk/4` derives from every node
  # with the id, so the call takes the first of the tool's kind that offers
  # the action.
  defp pick_live([], widget_id, _module, _action, _type_map),
    do: {:error, {:widget_unavailable, widget_id, :absent}}

  defp pick_live(nodes, widget_id, module, action, type_map) do
    same_kind = Enum.filter(nodes, &(resolve_module(&1, &1.type, type_map) == module))

    case Enum.find(same_kind, &offers?(&1, module, action)) do
      nil when same_kind == [] -> {:error, {:widget_unavailable, widget_id, :type_changed}}
      nil -> {:error, {:widget_unavailable, widget_id, :disabled}}
      live -> {:ok, live}
    end
  end

  defp offers?(node, module, action) do
    not mcp_excluded?(node) and Enum.any?(module.mcp_tools(node), &(&1.name == action))
  end

  # Every node with `widget_id` that `do_walk/4` would derive tools from, in
  # view order.
  defp find_nodes(nodes, widget_id) when is_list(nodes),
    do: Enum.flat_map(nodes, &find_nodes(&1, widget_id))

  defp find_nodes(%{type: type, id: widget_id} = node, widget_id) when is_atom(type),
    do: [node | find_nodes(child_nodes(node), widget_id)]

  defp find_nodes(node, widget_id) when is_map(node),
    do: node |> child_nodes() |> find_nodes(widget_id)

  defp find_nodes(_node, _widget_id), do: []

  defp synced(%{synced: synced}), do: synced.()
  defp synced(_context), do: :ok

  # Only the two flags `Raxol.MCP.ToolDef.sensitive?/1` reads, and only when
  # `true`: a provider declaring its action dangerous is credible, one
  # declaring it safe (`readOnlyHint`, `destructiveHint: false`) is not, and a
  # client acts on the hints it finds (OMP's plan mode reads `readOnlyHint`).
  # No built-in provider sets any other key.
  @kept_annotations [:sensitive, :destructiveHint]

  defp put_annotations(tool, annotations) when is_map(annotations) do
    kept =
      for key <- @kept_annotations,
          (Map.get(annotations, key) || Map.get(annotations, Atom.to_string(key))) == true,
          into: %{},
          do: {key, true}

    if kept == %{}, do: tool, else: Map.put(tool, :annotations, kept)
  end

  defp put_annotations(tool, _annotations), do: tool

  # Invalid UTF-8 is replaced first, since the `u` regex refuses it.
  defp sanitize_text(text) do
    text |> String.replace_invalid() |> String.replace(@unsafe_chars, "")
  end

  defp clean_description(nil), do: {:ok, nil}
  defp clean_description(text) when is_binary(text), do: {:ok, sanitize_text(text)}
  defp clean_description(atom) when is_atom(atom), do: {:ok, sanitize_text(Atom.to_string(atom))}
  defp clean_description(_other), do: {:error, :not_json}

  # Every key and every string leaf, at any depth (titles, enums, defaults,
  # examples, property names, nested objects, array `items`), or the fault
  # that refuses the spec. `depth` is how many maps and lists enclose the
  # term, `budget` how many more values (maps, lists, leaves) may be walked;
  # past either cap the walk stops, so its cost is bounded whatever the
  # provider hands over.
  defp clean_schema(_term, _depth, budget) when budget <= 0, do: {:error, :too_large}

  defp clean_schema(%{} = map, depth, budget) when not is_struct(map) do
    if depth >= @max_schema_depth or map_size(map) >= budget do
      {:error, :too_large}
    else
      clean_map(map, depth + 1, budget - 1)
    end
  end

  defp clean_schema(list, depth, budget) when is_list(list) do
    if depth >= @max_schema_depth,
      do: {:error, :too_large},
      else: clean_list(list, depth + 1, budget - 1, [])
  end

  defp clean_schema(text, _depth, budget) when is_binary(text),
    do: {:ok, sanitize_text(text), budget - 1}

  defp clean_schema(literal, _depth, budget) when literal in [nil, true, false],
    do: {:ok, literal, budget - 1}

  defp clean_schema(atom, _depth, budget) when is_atom(atom),
    do: {:ok, clean_atom(atom), budget - 1}

  defp clean_schema(number, _depth, budget) when is_number(number),
    do: {:ok, number, budget - 1}

  defp clean_schema(_other, _depth, _budget), do: {:error, :not_json}

  defp clean_map(map, depth, budget) do
    Enum.reduce_while(map, {:ok, %{}, MapSet.new(), budget}, fn {key, value},
                                                                {:ok, clean, seen, budget} ->
      case clean_entry(key, value, seen, depth, budget) do
        {:ok, key, name, value, budget} ->
          {:cont, {:ok, Map.put(clean, key, value), MapSet.put(seen, name), budget}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, clean, _seen, budget} -> {:ok, clean, budget}
      error -> error
    end
  end

  # `name` is the key as JSON writes it, so `:a` and `"a"` collide.
  defp clean_entry(key, value, seen, depth, budget) do
    with {:ok, key, name} <- clean_key(key),
         :ok <- unseen(name, seen),
         {:ok, value, budget} <- clean_schema(value, depth, budget) do
      {:ok, key, name, value, budget}
    end
  end

  defp unseen(name, seen) do
    if MapSet.member?(seen, name), do: {:error, {:duplicate_key, name}}, else: :ok
  end

  defp clean_key(key) when is_binary(key) do
    clean = sanitize_text(key)
    {:ok, clean, clean}
  end

  defp clean_key(key) when is_atom(key) do
    case clean_atom(key) do
      ^key -> {:ok, key, Atom.to_string(key)}
      clean -> {:ok, clean, clean}
    end
  end

  defp clean_key(_other), do: {:error, :not_json}

  # An atom is encoded as its name, so one whose name changes is replaced by
  # the cleaned string.
  defp clean_atom(atom) do
    name = Atom.to_string(atom)
    clean = sanitize_text(name)
    if clean == name, do: atom, else: clean
  end

  defp clean_list([], _depth, budget, acc), do: {:ok, Enum.reverse(acc), budget}

  defp clean_list([item | rest], depth, budget, acc) do
    case clean_schema(item, depth, budget) do
      {:ok, clean, budget} -> clean_list(rest, depth, budget, [clean | acc])
      error -> error
    end
  end

  defp clean_list(_improper_tail, _depth, _budget, _acc), do: {:error, :not_json}

  # A call, not a cast: each message has been through the app's update/2 by
  # the time the tool answers. An update/2 that failed answers
  # `{:error, :update_failed}`, which stops the remaining messages and becomes
  # the tool's error result. A dispatcher that is gone or does not answer
  # exits here, and `Raxol.MCP.Registry` turns that exit into an error result.
  defp dispatch_messages(messages, dispatcher_pid)
       when is_pid(dispatcher_pid) do
    messages
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while(:ok, fn msg, :ok ->
      case GenServer.call(dispatcher_pid, {:dispatch_tool_message, msg}) do
        :ok -> {:cont, :ok}
        {:error, :update_failed} = error -> {:halt, error}
      end
    end)
  end

  defp dispatch_messages(_messages, _pid), do: :ok

  defp format_result(result) when is_binary(result) do
    [%{type: "text", text: result}]
  end

  defp format_result(result) do
    [%{type: "text", text: inspect(result)}]
  end

  defp mcp_excluded?(%{attrs: %{mcp_exclude: true}}), do: true
  defp mcp_excluded?(_), do: false
end
