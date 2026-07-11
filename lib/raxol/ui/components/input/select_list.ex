defmodule Raxol.UI.Components.Input.SelectList do
  @moduledoc """
  A component that allows users to select an option from a list.

  Features:
  * Single or multiple selections
  * Robust keyboard navigation with stateful scrolling
  * Search/filtering capabilities
  * Accessibility support
  * Custom styling and theming
  * Pagination for very large lists
  """

  alias Raxol.UI.Components.Input.SelectList.{
    Navigation,
    Pagination,
    Renderer,
    Search,
    Selection,
    Utils
  }

  @behaviour Raxol.UI.Components.Base.Component
  @behaviour Raxol.MCP.ToolProvider
  @behaviour Raxol.Core.Accessibility.Provider

  @key_mapping %{
    "Down" => :navigation_down,
    :down => :navigation_down,
    "Up" => :navigation_up,
    :up => :navigation_up,
    "PageDown" => :navigation_page_down,
    :pagedown => :navigation_page_down,
    :page_down => :navigation_page_down,
    "PageUp" => :navigation_page_up,
    :pageup => :navigation_page_up,
    :page_up => :navigation_page_up,
    "Home" => :navigation_home,
    :home => :navigation_home,
    "End" => :navigation_end,
    :end => :navigation_end,
    "Enter" => :enter,
    :enter => :enter,
    "Tab" => :tab,
    :tab => :tab,
    "Backspace" => :backspace,
    :backspace => :backspace,
    "Space" => :space,
    :space => :space
  }

  # Example: {"Option Label", :option_value}
  @type option :: {String.t(), any()}
  @type options :: [option()]
  @type props :: %{
          optional(:id) => String.t(),
          :options => options(),
          optional(:label) => String.t(),
          optional(:on_select) => (any() -> any()),
          optional(:on_cancel) => (-> any()) | nil,
          optional(:on_change) => (any() -> any()) | nil,
          optional(:on_focus) => (integer() -> any()) | nil,
          optional(:theme) => map(),
          optional(:style) => map(),
          optional(:max_height) => integer() | nil,
          optional(:enable_search) => boolean(),
          optional(:multiple) => boolean(),
          optional(:searchable_fields) => list(atom()) | nil,
          optional(:placeholder) => String.t(),
          optional(:empty_message) => String.t(),
          optional(:show_pagination) => boolean()
        }

  # Enhanced state includes props and more comprehensive internal state
  @type state :: %{
          :id => String.t() | nil,
          :options => options(),
          :label => String.t() | nil,
          :on_select => (any() -> any()) | nil,
          :on_cancel => (-> any()) | nil,
          :on_change => (any() -> any()) | nil,
          :on_focus => (integer() -> any()) | nil,
          :theme => map() | nil,
          :style => map() | nil,
          :max_height => integer() | nil,
          :enable_search => boolean(),
          :multiple => boolean(),
          :searchable_fields => list(atom()) | nil,
          :placeholder => String.t(),
          :empty_message => String.t(),
          :show_pagination => boolean(),
          :focused_index => integer(),
          :selected_index => integer(),
          :scroll_offset => integer(),
          :search_text => String.t(),
          :filtered_options => options() | nil,
          :is_filtering => boolean(),
          :selected_indices => MapSet.t(),
          :is_search_focused => boolean(),
          :page_size => integer(),
          :visible_items => integer(),
          :current_page => integer(),
          :has_focus => boolean(),
          :visible_height => integer() | nil,
          :last_key_time => integer() | nil,
          :search_buffer => String.t(),
          :search_timer => integer() | nil,
          :on_focus => (integer() -> any()) | nil
        }

  @type t :: state()

  # --- Component Implementation ---

  @doc """
  Initializes the SelectList component state from the given props.
  """
  @impl Raxol.UI.Components.Base.Component
  def init(props) do
    validate_props!(props)

    defaults = %{
      focused_index: 0,
      scroll_offset: 0,
      search_text: "",
      search_query: "",
      filtered_options: nil,
      is_filtering: false,
      selected_indices: MapSet.new(),
      selected_index: 0,
      is_search_focused: false,
      page_size: Raxol.Core.Defaults.page_size(),
      visible_items: Raxol.Core.Defaults.page_size(),
      current_page: 0,
      enable_search: false,
      multiple: false,
      searchable_fields: nil,
      placeholder: "Type to search...",
      empty_message: "No options available",
      show_pagination: false,
      has_focus: false,
      visible_height: nil,
      last_key_time: nil,
      search_buffer: "",
      search_timer: nil,
      theme: %{},
      style: %{},
      on_focus: nil,
      selected_marker: "> ",
      selected_style: Raxol.Core.Defaults.selected_style(),
      search_enabled: false,
      paginated: false,
      search_active: false
    }

    # Merge validated props with default internal state
    {:ok, Map.merge(defaults, props)}
  end

  @doc """
  Updates the SelectList component state in response to messages or prop changes.
  """
  @impl Raxol.UI.Components.Base.Component
  def update({:update_props, new_props}, state) do
    validate_props!(new_props)

    # If options change substantially, we may need to reset some state
    reset_state = %{}

    reset_state = handle_options_change(new_props, state, reset_state)

    # Merge everything together, with new_props taking precedence
    updated_state = Map.merge(state, reset_state)
    {Map.merge(updated_state, new_props), nil}
  end

  def update({:search, search_text}, state) do
    # Cancel any existing timer
    _ = cancel_timer_if_present(state.search_timer)

    # Schedule new search
    timer_id = System.unique_integer([:positive])

    _ =
      Process.send_after(
        self(),
        {:apply_search, search_text},
        Raxol.Core.Defaults.debounce_ms()
      )

    # Update buffer immediately
    {%{state | search_buffer: search_text, search_timer: timer_id}, nil}
  end

  def update({:apply_search, search_text}, state) do
    new_state =
      Search.update_search_state(
        %{state | search_text: search_text, search_timer: nil},
        search_text
      )

    {new_state, nil}
  end

  def update({:select_option, index}, state) do
    Selection.update_selection_state(state, index)
  end

  def update({:set_page, page_num}, state) do
    new_state = Pagination.update_page_state(state, page_num)
    {new_state, nil}
  end

  def update({:set_focus, has_focus}, state) do
    new_state = %{state | has_focus: has_focus}

    trigger_focus_callback_if_needed(has_focus, state)

    {new_state, nil}
  end

  def update({:toggle_search_focus}, state) do
    toggle_search_focus_if_enabled(state)
  end

  def update({:set_visible_height, height}, state) do
    {%{state | visible_height: height}, nil}
  end

  def update({:set_search_focus, true}, state) do
    new_state = %{
      state
      | is_search_focused: true,
        search_text: "",
        search_buffer: "",
        filtered_options: nil,
        is_filtering: false
    }

    {new_state, nil}
  end

  def update(message, state) do
    # If state is an empty map or missing required fields, initialize a default state
    state = normalize_state(state)
    do_update(message, state)
  end

  defp normalize_state(state) when not is_map(state) do
    {:ok, s} = init(%{options: []})
    s
  end

  defp normalize_state(state) when map_size(state) == 0 do
    {:ok, s} = init(%{options: []})
    s
  end

  defp normalize_state(%{} = state) do
    ensure_options_present(state)
  end

  # The specific `update/2` clauses above handle every tagged message, so
  # do_update only ever receives non-tagged messages -- the catch-all below.

  defp do_update(_message, state), do: {state, nil}

  @doc """
  Handles events for the SelectList component, such as keypresses, mouse events, and context changes.
  """
  @impl Raxol.UI.Components.Base.Component
  def handle_event(%{__struct__: _} = event, state, context) do
    handle_event(Map.from_struct(event), state, context)
  end

  def handle_event(%{type: :key, data: %{key: key}}, state, _context) do
    state = ensure_state(state)
    handle_key_event(key, state)
  end

  def handle_event(%{type: :focus}, state, _context) do
    state = ensure_state(state)
    {new_state, _} = update({:set_focus, true}, state)
    {new_state, nil}
  end

  def handle_event(%{type: :blur}, state, _context) do
    state = ensure_state(state)
    {new_state, _} = update({:set_focus, false}, state)
    {new_state, nil}
  end

  def handle_event(
        %{type: :resize, data: %{width: _w, height: h}},
        state,
        _context
      ) do
    state = ensure_state(state)
    {new_state, _} = update({:set_visible_height, h}, state)
    {Navigation.update_scroll_position(new_state), nil}
  end

  def handle_event(%{type: :mouse, data: %{x: _x, y: y}}, state, _context) do
    state = ensure_state(state)
    handle_mouse_click(y, state)
  end

  defp handle_mouse_click(y, state) when y == 0 and state.enable_search do
    # Click on search input (y=0)
    {new_state, _} = update({:set_search_focus, true}, state)
    {new_state, nil}
  end

  defp handle_mouse_click(y, state) when y >= 1 do
    # Option click: y gives us the 0-based index directly
    index = y
    effective_options = Utils.get_effective_options(state)

    handle_option_click_if_valid(state, index, effective_options)
  end

  defp handle_mouse_click(_y, state), do: {state, nil}

  defp handle_option_click(state, index) do
    {maybe_new_state, commands} = Selection.update_selection_state(state, index)
    new_state = Map.put(maybe_new_state, :focused_index, index)
    execute_commands(commands)
    {new_state, nil}
  end

  defp execute_commands(commands) do
    Enum.each(commands, fn
      {:callback, fun, args} -> apply(fun, args)
      _ -> :ok
    end)
  end

  @doc """
  Renders the SelectList component using the current state and context.
  """
  @impl Raxol.UI.Components.Base.Component
  def render(state, context) do
    has_focus =
      Raxol.UI.FocusHelper.focused?(state[:id], context) or state.has_focus

    Renderer.render(%{state | has_focus: has_focus}, context)
  end

  @doc """
  Mounts the SelectList component. Performs any setup needed after initialization.
  """
  @impl Raxol.UI.Components.Base.Component
  def mount(state), do: state

  @doc """
  Unmounts the SelectList component, performing any necessary cleanup.
  """
  @impl Raxol.UI.Components.Base.Component
  def unmount(state), do: state

  # --- Private Helper Functions ---

  defp validate_props!(props) do
    validate_options_prop_presence(props)

    validate_options_prop_type(props.options)

    # Validate each option
    Enum.each(props.options, &validate_option!/1)
  end

  defp validate_option!({label, _value}) do
    validate_label!(label)
  end

  defp validate_option!({label, _value, style}) do
    validate_label!(label)
    validate_style!(style)
  end

  defp validate_option!(_invalid_option) do
    raise ArgumentError,
          "SelectList options must be {label, value} or {label, value, style} tuples"
  end

  defp validate_label!(label) do
    validate_label_type(label)
  end

  defp validate_style!(style) do
    validate_style_type(style)
  end

  defp ensure_state(state), do: normalize_state(state)

  defp handle_key_event(key, state) do
    action = classify_key_action(key, state)
    execute_key_action(action, state)
  end

  @key_action_mapping %{
    :navigation_down => {:navigation, :down},
    :navigation_up => {:navigation, :up},
    :navigation_page_down => {:navigation, :page_down},
    :navigation_page_up => {:navigation, :page_up},
    :navigation_home => {:navigation, :home},
    :navigation_end => {:navigation, :end},
    :enter => {:selection, :enter},
    :space => {:selection, :space},
    :tab => {:search, :toggle_focus},
    :backspace => {:search, :backspace}
  }

  defp classify_key_action(key, state) do
    key_type = classify_key(key, state)

    case key_type do
      :character -> {:search, {:character, key}}
      :unknown -> {:noop, nil}
      _ -> Map.get(@key_action_mapping, key_type, {:noop, nil})
    end
  end

  defp execute_key_action({:navigation, direction}, state) do
    navigation_handler(direction, state)
  end

  defp execute_key_action({:selection, :enter}, state) do
    Selection.update_selection_state(state, state.focused_index)
  end

  defp execute_key_action({:selection, :space}, state) do
    # Space key toggles selection in multiple mode, selects in single mode
    Selection.update_selection_state(state, state.focused_index)
  end

  defp execute_key_action({:search, action}, state) do
    search_handler(action, state)
  end

  defp execute_key_action({:noop, _}, state), do: {state, nil}

  defp navigation_handler(:down, state),
    do: Navigation.handle_arrow_down(state) |> then(&{&1, nil})

  defp navigation_handler(:up, state),
    do: Navigation.handle_arrow_up(state) |> then(&{&1, nil})

  defp navigation_handler(:page_down, state),
    do: Navigation.handle_page_down(state) |> then(&{&1, nil})

  defp navigation_handler(:page_up, state),
    do: Navigation.handle_page_up(state) |> then(&{&1, nil})

  defp navigation_handler(:home, state),
    do: Navigation.handle_home(state) |> then(&{&1, nil})

  defp navigation_handler(:end, state),
    do: Navigation.handle_end(state) |> then(&{&1, nil})

  defp search_handler(:toggle_focus, state), do: handle_tab_key(state)
  defp search_handler(:backspace, state), do: handle_backspace_key(state)

  defp search_handler({:character, key}, state),
    do: handle_character_key(key, state)

  defp classify_key(key, state) do
    key_type = get_key_type(key)

    classify_unknown_key(key_type, key, state)
  end

  defp get_key_type(key) do
    @key_mapping[key] || :unknown
  end

  defp character_key?(key, state) do
    single_character?(key) and search_enabled_and_focused?(state)
  end

  defp single_character?(key) do
    is_binary(key) and byte_size(key) == 1
  end

  defp search_enabled_and_focused?(state) do
    state.enable_search and state.is_search_focused
  end

  defp handle_character_key(key, state) do
    {new_state, _} = update({:search, state.search_buffer <> key}, state)
    {new_state, nil}
  end

  defp handle_tab_key(state) do
    toggle_search_if_enabled(state)
  end

  defp handle_backspace_key(state) do
    handle_backspace_if_applicable(state)
  end

  ## Helper functions for refactored if statements

  defp handle_options_change(new_props, state, reset_state) do
    case {Map.has_key?(new_props, :options),
          new_props[:options] != state[:options]} do
      {true, true} ->
        # Cancel any pending search timer
        _ = cancel_timer_if_present(state.search_timer)

        Map.merge(reset_state, %{
          filtered_options: nil,
          is_filtering: false,
          search_text: "",
          search_buffer: "",
          search_timer: nil,
          # Preserve selection if possible, otherwise reset
          focused_index: 0,
          scroll_offset: 0,
          current_page: 0
        })

      _ ->
        reset_state
    end
  end

  defp cancel_timer_if_present(nil), do: :ok

  defp cancel_timer_if_present(timer_id) do
    Process.cancel_timer(timer_id)
  end

  defp trigger_focus_callback_if_needed(true, %{on_focus: callback} = state)
       when is_function(callback) do
    callback.(state.focused_index)
  end

  defp trigger_focus_callback_if_needed(_has_focus, _state), do: :ok

  defp toggle_search_focus_if_enabled(%{enable_search: true} = state) do
    new_state = %{state | is_search_focused: !state.is_search_focused}

    cleared_state = %{
      new_state
      | search_text: "",
        search_buffer: "",
        filtered_options: nil,
        is_filtering: false
    }

    {cleared_state, nil}
  end

  defp toggle_search_focus_if_enabled(state) do
    {state, nil}
  end

  defp ensure_options_present(%{options: _} = state), do: state

  defp ensure_options_present(_state) do
    {:ok, s} = init(%{options: []})
    s
  end

  defp handle_option_click_if_valid(state, index, effective_options)
       when index >= 0 and index < length(effective_options) do
    handle_option_click(state, index)
  end

  defp handle_option_click_if_valid(state, _index, _effective_options) do
    {state, nil}
  end

  defp validate_options_prop_presence(%{options: _}), do: :ok

  defp validate_options_prop_presence(_props) do
    raise ArgumentError, "SelectList requires :options prop"
  end

  defp validate_options_prop_type(options) when is_list(options), do: :ok

  defp validate_options_prop_type(_options) do
    raise ArgumentError, "SelectList :options must be a list"
  end

  defp validate_label_type(label) when is_binary(label), do: :ok

  defp validate_label_type(_label) do
    raise ArgumentError, "SelectList option labels must be strings"
  end

  defp validate_style_type(style) when is_map(style), do: :ok

  defp validate_style_type(_style) do
    raise ArgumentError,
          "SelectList option style (third element) must be a map"
  end

  defp classify_unknown_key(:unknown, key, state) do
    case character_key?(key, state) do
      true -> :character
      false -> :unknown
    end
  end

  defp classify_unknown_key(key_type, _key, _state) do
    key_type
  end

  defp toggle_search_if_enabled(%{enable_search: true} = state) do
    new_state = %{state | is_search_focused: !state.is_search_focused}

    cleared_state = %{
      new_state
      | search_text: "",
        search_buffer: "",
        filtered_options: nil,
        is_filtering: false
    }

    {cleared_state, nil}
  end

  defp toggle_search_if_enabled(state) do
    {state, nil}
  end

  defp handle_backspace_if_applicable(
         %{is_search_focused: true, search_buffer: buffer} = state
       )
       when buffer != "" do
    new_buffer =
      String.slice(
        state.search_buffer,
        0,
        String.length(state.search_buffer) - 1
      )

    {new_state, _} = update({:search, new_buffer}, state)
    {new_state, nil}
  end

  defp handle_backspace_if_applicable(state) do
    {state, nil}
  end

  # -- ToolProvider callbacks --

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(state) do
    id = state[:id] || "select_list"

    [
      %{
        name: "select",
        description: "Select an option in '#{id}' by index",
        inputSchema: %{
          type: "object",
          properties: %{
            index: %{type: "integer", description: "Option index (0-based)"}
          },
          required: ["index"]
        }
      },
      %{
        name: "get_selected",
        description: "Get the currently selected option in '#{id}'",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "get_options",
        description: "Get all available options in '#{id}'",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("select", %{"index" => index}, context) do
    {:ok, "Selected option #{index}",
     [{:select_option, context.widget_id, index}]}
  end

  def handle_tool_call("get_selected", _args, context) do
    state = context.widget_state
    selected = state[:selected_index] || state[:focused_index]
    options = state[:options] || state[:filtered_options] || []

    case Enum.at(options, selected || 0) do
      nil ->
        {:ok, nil}

      option ->
        {:ok, %{index: selected, label: option[:label] || inspect(option)}}
    end
  end

  def handle_tool_call("get_options", _args, context) do
    options = context.widget_state[:options] || []
    labels = Enum.map(options, fn opt -> opt[:label] || inspect(opt) end)
    {:ok, labels}
  end

  def handle_tool_call(action, _args, _ctx),
    do: {:error, "Unknown action: #{action}"}

  @impl Raxol.Core.Accessibility.Provider
  def a11y_node(node) do
    options = node[:options] || node[:filtered_options] || []
    selected = node[:selected_index] || node[:focused_index]

    children =
      options
      |> Enum.with_index()
      |> Enum.map(fn {opt, index} ->
        %{
          role: :option,
          label: a11y_option_label(opt),
          state: %{selected?: index == selected}
        }
      end)

    %{
      role: :listbox,
      label: node[:aria_label] || node[:label],
      state: %{focused?: node[:focused] == true},
      children: children
    }
  end

  defp a11y_option_label({label, _value}) when is_binary(label), do: label
  defp a11y_option_label(%{} = opt), do: opt[:label] || opt[:name]
  defp a11y_option_label(label) when is_binary(label), do: label
  defp a11y_option_label(other), do: inspect(other)
end
