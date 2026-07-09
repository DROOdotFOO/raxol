defmodule Raxol.Terminal.Window.WindowServer do
  @moduledoc """
  A unified window manager for terminal applications.

  This module provides a GenServer-based window management system that handles
  window creation, splitting, resizing, and other window operations.
  """

  use Raxol.Core.Behaviours.BaseManager

  @type window_id :: non_neg_integer()
  @type window_state :: %{
          id: window_id(),
          title: String.t() | nil,
          icon_name: String.t() | nil,
          size: {non_neg_integer(), non_neg_integer()},
          position: {non_neg_integer(), non_neg_integer()},
          maximized: boolean(),
          iconified: boolean(),
          previous_size: {non_neg_integer(), non_neg_integer()} | nil,
          stacking_order: :normal | :above | :below,
          parent_id: window_id() | nil,
          children: [window_id()],
          split_type: :horizontal | :vertical | :none,
          buffer_id: String.t() | nil,
          renderer_id: String.t() | nil
        }

  @type t :: window_state()

  @type state :: %{
          windows: %{window_id() => window_state()},
          active_window: window_id() | nil,
          next_id: non_neg_integer(),
          config: %{
            default_size: {non_neg_integer(), non_neg_integer()},
            max_size: {non_neg_integer(), non_neg_integer()},
            default_buffer_id: String.t() | nil,
            default_renderer_id: String.t() | nil
          }
        }

  # Client API

  def create_window(opts \\ []) do
    GenServer.call(__MODULE__, {:create_window, opts})
  end

  def split_window(window_id, direction) do
    GenServer.call(__MODULE__, {:split_window, window_id, direction})
  end

  def close_window(window_id) do
    GenServer.call(__MODULE__, {:close_window, window_id})
  end

  def set_title(window_id, title) do
    GenServer.call(__MODULE__, {:set_title, window_id, title})
  end

  def set_icon_name(window_id, name) do
    GenServer.call(__MODULE__, {:set_icon_name, window_id, name})
  end

  def resize(window_id, width, height) do
    GenServer.call(__MODULE__, {:resize, window_id, width, height})
  end

  def move(window_id, x, y) do
    GenServer.call(__MODULE__, {:move, window_id, x, y})
  end

  def set_stacking_order(window_id, order) do
    GenServer.call(__MODULE__, {:set_stacking_order, window_id, order})
  end

  def set_maximized(window_id, maximized) do
    GenServer.call(__MODULE__, {:set_maximized, window_id, maximized})
  end

  def set_active_window(window_id) do
    GenServer.call(__MODULE__, {:set_active_window, window_id})
  end

  def get_window_state(window_id) do
    GenServer.call(__MODULE__, {:get_window_state, window_id})
  end

  def get_active_window do
    GenServer.call(__MODULE__, :get_active_window)
  end

  def update_config(config) do
    GenServer.call(__MODULE__, {:update_config, config})
  end

  def cleanup do
    GenServer.call(__MODULE__, :cleanup)
  end

  # Server callbacks

  @impl true
  def init_manager(opts) do
    # Handle both keyword lists and maps
    opts_map =
      case is_map(opts) do
        true -> opts
        false -> Map.new(opts || [])
      end

    config = %{
      default_size: Map.get(opts_map, :default_size, {80, 24}),
      max_size: Map.get(opts_map, :max_size, {200, 50}),
      default_buffer_id: Map.get(opts_map, :default_buffer_id),
      default_renderer_id: Map.get(opts_map, :default_renderer_id)
    }

    {:ok,
     %{
       windows: %{},
       active_window: nil,
       next_id: 1,
       config: config
     }}
  end

  @impl true
  def handle_manager_call({:create_window, opts}, _from, state) do
    {window_id, new_state} = do_create_window(opts, state)
    {:reply, {:ok, window_id}, new_state}
  end

  @impl true
  def handle_manager_call({:split_window, window_id, direction}, _from, state) do
    case Map.get(state.windows, window_id) do
      nil ->
        {:reply, {:error, :window_not_found}, state}

      window ->
        handle_split_window_request(window, direction, state)
    end
  end

  @impl true
  def handle_manager_call(:get_active_window, _from, state) do
    {:reply, {:ok, state.active_window}, state}
  end

  @impl true
  def handle_manager_call({:get_window_state, window_id}, _from, state) do
    case Map.get(state.windows, window_id) do
      nil -> {:reply, {:error, :window_not_found}, state}
      window -> {:reply, {:ok, window}, state}
    end
  end

  @impl true
  def handle_manager_call({:set_title, window_id, title}, _from, state) do
    case Map.get(state.windows, window_id) do
      nil ->
        {:reply, {:error, :window_not_found}, state}

      window ->
        updated_window = %{window | title: title}

        new_state = %{
          state
          | windows: Map.put(state.windows, window_id, updated_window)
        }

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_manager_call({:set_icon_name, window_id, icon_name}, _from, state) do
    case Map.get(state.windows, window_id) do
      nil ->
        {:reply, {:error, :window_not_found}, state}

      window ->
        updated_window = %{window | icon_name: icon_name}

        new_state = %{
          state
          | windows: Map.put(state.windows, window_id, updated_window)
        }

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_manager_call({:resize, window_id, width, height}, _from, state) do
    case Map.get(state.windows, window_id) do
      nil ->
        {:reply, {:error, :window_not_found}, state}

      window ->
        updated_window = %{window | size: {width, height}}

        new_state = %{
          state
          | windows: Map.put(state.windows, window_id, updated_window)
        }

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_manager_call({:move, window_id, x, y}, _from, state) do
    case Map.get(state.windows, window_id) do
      nil ->
        {:reply, {:error, :window_not_found}, state}

      window ->
        updated_window = %{window | position: {x, y}}

        new_state = %{
          state
          | windows: Map.put(state.windows, window_id, updated_window)
        }

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_manager_call({:set_stacking_order, window_id, order}, _from, state) do
    case Map.get(state.windows, window_id) do
      nil ->
        {:reply, {:error, :window_not_found}, state}

      window ->
        updated_window = %{window | stacking_order: order}

        new_state = %{
          state
          | windows: Map.put(state.windows, window_id, updated_window)
        }

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_manager_call({:set_maximized, window_id, maximized}, _from, state) do
    case Map.get(state.windows, window_id) do
      nil ->
        {:reply, {:error, :window_not_found}, state}

      window ->
        {new_size, new_previous_size} =
          case maximized do
            true -> {state.config.max_size, window.size}
            false -> {window.previous_size || state.config.default_size, nil}
          end

        updated_window = %{
          window
          | maximized: maximized,
            size: new_size,
            previous_size: new_previous_size
        }

        new_state = %{
          state
          | windows: Map.put(state.windows, window_id, updated_window)
        }

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_manager_call({:set_active_window, window_id}, _from, state) do
    case Map.get(state.windows, window_id) do
      nil -> {:reply, {:error, :window_not_found}, state}
      _window -> {:reply, :ok, %{state | active_window: window_id}}
    end
  end

  @impl true
  def handle_manager_call({:close_window, window_id}, _from, state) do
    case do_close_window(window_id, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, new_state} -> {:reply, {:error, :window_not_found}, new_state}
    end
  end

  @impl true
  def handle_manager_call({:update_config, config}, _from, state) do
    new_state = %{state | config: Map.merge(state.config, config)}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_manager_call(:cleanup, _from, state) do
    # Clean up all windows
    new_state = %{state | windows: %{}, active_window: nil}
    {:reply, :ok, new_state}
  end

  defp calculate_split_sizes({width, height}, :horizontal) do
    half = div(width, 2)
    {{half, height}, {half, height}}
  end

  defp calculate_split_sizes({width, height}, :vertical) do
    half = div(height, 2)
    {{width, half}, {width, half}}
  end

  # Private helper functions

  defp do_create_window(opts, state) when is_list(opts) do
    window_id = state.next_id

    window = %{
      id: window_id,
      title: Keyword.get(opts, :title, ""),
      icon_name: Keyword.get(opts, :icon_name),
      size: Keyword.get(opts, :size, state.config.default_size),
      position: Keyword.get(opts, :position, {0, 0}),
      maximized: Keyword.get(opts, :maximized, false),
      iconified: Keyword.get(opts, :iconified, false),
      previous_size: nil,
      stacking_order: :normal,
      parent_id: Keyword.get(opts, :parent_id),
      children: [],
      split_type: :none,
      buffer_id: Keyword.get(opts, :buffer_id, state.config.default_buffer_id),
      renderer_id: Keyword.get(opts, :renderer_id, state.config.default_renderer_id)
    }

    new_state = %{
      state
      | windows: Map.put(state.windows, window_id, window),
        next_id: state.next_id + 1,
        active_window: window_id
    }

    {window_id, new_state}
  end

  defp do_create_window(opts, state) when is_map(opts) do
    window_id = state.next_id

    window = %{
      id: window_id,
      title: Map.get(opts, :title, ""),
      icon_name: Map.get(opts, :icon_name),
      size: Map.get(opts, :size, state.config.default_size),
      position: Map.get(opts, :position, {0, 0}),
      maximized: Map.get(opts, :maximized, false),
      iconified: Map.get(opts, :iconified, false),
      previous_size: nil,
      stacking_order: :normal,
      parent_id: Map.get(opts, :parent_id),
      children: [],
      split_type: :none,
      buffer_id: Map.get(opts, :buffer_id, state.config.default_buffer_id),
      renderer_id: Map.get(opts, :renderer_id, state.config.default_renderer_id)
    }

    new_state = %{
      state
      | windows: Map.put(state.windows, window_id, window),
        next_id: state.next_id + 1,
        active_window: window_id
    }

    {window_id, new_state}
  end

  defp do_close_window(window_id, state) do
    case Map.get(state.windows, window_id) do
      nil ->
        {:error, state}

      window ->
        new_state = close_child_windows(window, state)
        new_state = update_parent_window(window, new_state)
        final_state = remove_window_and_update_active(window_id, new_state)
        {:ok, final_state}
    end
  end

  defp close_child_windows(window, state) do
    Enum.reduce(window.children, state, fn child_id, acc ->
      case do_close_window(child_id, acc) do
        {:ok, acc2} -> acc2
        {:error, acc2} -> acc2
      end
    end)
  end

  defp update_parent_window(window, state) do
    case window.parent_id do
      nil ->
        state

      parent_id ->
        case Map.get(state.windows, parent_id) do
          nil -> state
          parent -> update_parent_children(parent, window.id, state)
        end
    end
  end

  defp update_parent_children(parent, window_id, state) do
    updated_parent = %{
      parent
      | children: List.delete(parent.children, window_id)
    }

    %{state | windows: Map.put(state.windows, parent.id, updated_parent)}
  end

  defp remove_window_and_update_active(window_id, state) do
    state = %{state | windows: Map.delete(state.windows, window_id)}

    case state.active_window == window_id do
      true ->
        next_window_id = Map.keys(state.windows) |> List.first()
        %{state | active_window: next_window_id}

      false ->
        state
    end
  end

  defp do_split_window(window, direction, state) do
    {parent_size, child_size} = calculate_split_sizes(window.size, direction)

    {new_window_id, state1} =
      do_create_window(
        %{
          size: child_size,
          position: window.position,
          buffer_id: Map.get(state.config, :default_buffer_id),
          renderer_id: Map.get(state.config, :default_renderer_id)
        },
        state
      )

    updated_window = %{
      window
      | size: parent_size,
        split_type: direction,
        children: [new_window_id | window.children]
    }

    new_window = Map.get(state1.windows, new_window_id)
    updated_new_window = %{new_window | parent_id: window.id}

    new_state = %{
      state1
      | windows:
          state1.windows
          |> Map.put(window.id, updated_window)
          |> Map.put(new_window_id, updated_new_window)
    }

    {:ok, new_window_id, new_state}
  end

  defp handle_split_window_request(window, direction, state) do
    case direction do
      direction when direction in [:horizontal, :vertical] ->
        {:ok, new_window_id, new_state} =
          do_split_window(window, direction, state)

        {:reply, {:ok, new_window_id}, new_state}

      _ ->
        {:reply, {:error, :invalid_direction}, state}
    end
  end
end
