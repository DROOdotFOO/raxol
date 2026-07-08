defmodule Raxol.UI.Theming.ThemeManager do
  @moduledoc """
  Unified manager for themes and color palettes in the UI system.
  Consolidates ThemeManager and ColorManager functionality.
  """

  use Raxol.Core.Behaviours.BaseManager


  defstruct [
    :current_theme,
    :available_themes,
    :theme_cache,
    :current_palette,
    :palettes,
    :contrast_ratio
  ]

  @type t :: %__MODULE__{
          current_theme: String.t() | nil,
          available_themes: map(),
          theme_cache: map(),
          current_palette: map() | nil,
          palettes: map(),
          contrast_ratio: float()
        }

  ## Client API - Theme Management

  def get_theme(manager \\ __MODULE__, theme_id) do
    GenServer.call(manager, {:get_theme, theme_id})
  end

  def set_theme(manager \\ __MODULE__, theme_id) do
    GenServer.call(manager, {:set_theme, theme_id})
  end

  def list_themes(manager \\ __MODULE__) do
    GenServer.call(manager, :list_themes)
  end

  ## Client API - Color Management

  def update_palette(manager \\ __MODULE__, palette) do
    GenServer.call(manager, {:update_palette, palette})
  end

  def get_palette(manager \\ __MODULE__) do
    GenServer.call(manager, :get_palette)
  end

  def set_contrast_ratio(manager \\ __MODULE__, ratio) do
    GenServer.call(manager, {:set_contrast_ratio, ratio})
  end

  def get_contrast_ratio(manager \\ __MODULE__) do
    GenServer.call(manager, :get_contrast_ratio)
  end

  ## GenServer Implementation

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    state = %__MODULE__{
      current_theme: nil,
      available_themes: %{},
      theme_cache: %{},
      current_palette: nil,
      palettes: %{},
      contrast_ratio: Keyword.get(opts, :contrast_ratio, 4.5)
    }

    {:ok, state}
  end

  ## Theme Handlers

  @impl true
  def handle_call({:get_theme, theme_id}, _from, state) do
    theme = Map.get(state.available_themes, theme_id)
    {:reply, theme, state}
  end

  def handle_call({:set_theme, theme_id}, _from, state) do
    case Map.get(state.available_themes, theme_id) do
      nil ->
        {:reply, {:error, :theme_not_found}, state}

      theme ->
        new_state = %{state | current_theme: theme_id}
        {:reply, {:ok, theme}, new_state}
    end
  end

  def handle_call(:list_themes, _from, state) do
    themes = Map.keys(state.available_themes)
    {:reply, themes, state}
  end

  ## Color Handlers

  def handle_call({:update_palette, palette}, _from, state) do
    new_state = %{state | current_palette: palette}
    {:reply, :ok, new_state}
  end

  def handle_call(:get_palette, _from, state) do
    {:reply, state.current_palette, state}
  end

  def handle_call({:set_contrast_ratio, ratio}, _from, state) do
    new_state = %{state | contrast_ratio: ratio}
    {:reply, :ok, new_state}
  end

  def handle_call(:get_contrast_ratio, _from, state) do
    {:reply, state.contrast_ratio, state}
  end

  @impl true
  def handle_call(_request, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_info, state) do
    {:noreply, state}
  end
end
