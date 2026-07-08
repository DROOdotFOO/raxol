defmodule Raxol.Plugins.VisualizationPlugin do
  @moduledoc """
  Plugin responsible for rendering visualization components like charts and treemaps.
  It receives data structures from the view rendering pipeline and outputs
  actual terminal cells.
  """
  @behaviour Raxol.Plugins.Plugin
  @behaviour Raxol.Plugins.LifecycleBehaviour

  alias Raxol.Plugins.Visualization.ChartRenderer
  alias Raxol.Plugins.Visualization.ImageRenderer


  defstruct name: "visualization",
            version: "0.1.0",
            description: "Renders chart and treemap visualizations.",
            enabled: true,
            config: %{},
            dependencies: [],
            api_version: "1.0.1"

  @impl Raxol.Plugins.Plugin
  def init(config \\ %{}) do
    plugin_meta = struct(__MODULE__, config)
    state = %{meta: plugin_meta, cache: %{}}
    {:ok, state}
  end

  @impl Raxol.Plugins.Plugin
  def get_api_version, do: "0.1.0"

  @doc """
  Returns the API version for compatibility checking.
  """
  def api_version do
    "0.1.0"
  end

  @impl Raxol.Plugins.Plugin
  def get_dependencies, do: []

  @impl Raxol.Plugins.LifecycleBehaviour
  def start(config) do
    {:ok, config}
  end

  @impl Raxol.Plugins.LifecycleBehaviour
  def stop(config) do
    {:ok, config}
  end

  def terminate(_reason, _plugin_meta, _plugin_state) do
    :ok
  end

  def get_commands, do: []

  def handle_command(_command, _args, _plugin_meta, plugin_state) do
    {:error, :unknown_command, plugin_state}
  end

  def handle_event(_event, _plugin_meta, plugin_state) do
    {:noreply, plugin_state}
  end

  def handle_placeholder(
        %{
          type: :placeholder,
          value: value,
          data: data,
          opts: opts,
          bounds: bounds
        },
        _plugin_meta,
        plugin_state
      )
      when value in [:chart, :treemap, :image] do
    case value do
      :chart ->
        ChartRenderer.render_chart_content(data, opts, bounds, plugin_state)

      :treemap ->
        Raxol.Plugins.Visualization.TreemapRenderer.render_treemap_content(
          data,
          opts,
          bounds,
          plugin_state
        )

      :image ->
        ImageRenderer.render_image_content(data, opts, bounds, plugin_state)
    end
  end

  def handle_placeholder(_placeholder, _plugin_meta, plugin_state) do
    {:cont, plugin_state}
  end
end
