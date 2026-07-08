defmodule Raxol.Plugins.HyperlinkPlugin do
  @moduledoc """
  Plugin that detects URLs in terminal output and makes them clickable.
  """

  @behaviour Raxol.Plugins.Plugin
  @behaviour Raxol.Plugins.LifecycleBehaviour
  alias Raxol.Plugins.Plugin

  # Require Raxol.Core.Runtime.Log for logging macros

  # Define the struct type matching the Plugin behaviour
  @type t :: %Plugin{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          enabled: boolean(),
          config: map(),
          dependencies: list(map()),
          api_version: String.t(),
          state: map()
          # Add plugin-specific fields here if needed
        }

  # Update defstruct to match the Plugin behaviour fields
  defstruct [
    :name,
    :version,
    :description,
    :enabled,
    :config,
    :dependencies,
    :api_version,
    state: %{}
  ]

  @impl Raxol.Plugins.Plugin
  def init(config \\ %{}) do
    # Initialize the plugin struct with required fields
    metadata = get_metadata()

    plugin_state =
      struct(
        __MODULE__,
        Map.merge(
          %{
            name: metadata.name,
            version: metadata.version,
            description:
              "Plugin that detects URLs in terminal output and makes them clickable.",
            enabled: true,
            config: config,
            dependencies: metadata.dependencies,
            api_version: get_api_version(),
            state: %{}
          },
          config
        )
      )

    {:ok, plugin_state}
  end

  @impl Raxol.Plugins.Plugin
  def handle_input(plugin_state, input) do
    # Process input for hyperlink-related commands
    case input do
      "link " <> url ->
        # Create and display a hyperlink
        hyperlink = create_hyperlink(url)
        {:ok, plugin_state, hyperlink}

      _ ->
        {:ok, plugin_state}
    end
  end

  @impl Raxol.Plugins.Plugin
  def handle_output(plugin_state, event) do
    output = extract_output_data(event)

    # Find URLs using a simple regex (could be more robust)
    url_regex = ~r{(https?://[\w./?=&\-]+)}

    case String.contains?(output, "http://") or
           String.contains?(output, "https://") do
      true ->
        modified_output =
          String.replace(output, url_regex, fn url ->
            create_hyperlink(url)
          end)

        {:ok, plugin_state, modified_output}

      false ->
        {:ok, plugin_state}
    end
  end

  @impl Raxol.Plugins.Plugin
  def handle_mouse(plugin_state, rendered_cells, event) do
    case event do
      %{
        type: :mouse,
        button: :click,
        x: click_x,
        y: click_y,
        modifiers: _modifiers
      } ->
        handle_left_click(plugin_state, click_x, click_y, rendered_cells)

      _ ->
        {:ok, plugin_state}
    end
  end

  defp handle_left_click(plugin_state, x, y, rendered_cells) do
    # For now, just log the click and return success
    # In a real implementation, you would check the rendered_cells for hyperlinks
    Raxol.Core.Runtime.Log.debug(
      "[HyperlinkPlugin] Mouse click at (#{x}, #{y}) with rendered_cells: #{inspect(rendered_cells)}"
    )

    # Return the state unchanged for now
    # In a real implementation, you would check the rendered_cells for hyperlinks
    {:ok, plugin_state}
  end

  @impl Raxol.Plugins.Plugin
  def handle_resize(plugin_state, _width, _height) do
    # This plugin might not need to react to resize
    {:ok, plugin_state}
  end

  @impl Raxol.Plugins.Plugin
  def cleanup(%Raxol.Plugins.HyperlinkPlugin{} = _plugin) do
    # No cleanup needed for hyperlink plugin
    :ok
  end

  def cleanup(plugin_state) when is_map(plugin_state) do
    # Handle case where plugin is passed as a map
    :ok
  end

  @impl Raxol.Plugins.Plugin
  def get_dependencies do
    # This plugin has no dependencies
    []
  end

  @impl Raxol.Plugins.Plugin
  def get_api_version do
    "1.0.0"
  end

  @doc """
  Returns the API version for compatibility checking.
  """
  def api_version do
    "1.0.0"
  end

  @impl Raxol.Plugins.LifecycleBehaviour
  def start(config), do: {:ok, config}

  @impl Raxol.Plugins.LifecycleBehaviour
  def stop(config), do: {:ok, config}

  # Private functions

  defp extract_output_data(event) do
    case event do
      output when is_binary(output) ->
        output

      %{data: data} when is_binary(data) ->
        data

      _ ->
        ""
    end
  end

  defp create_hyperlink(url) do
    # OSC 8 escape sequence for hyperlinks
    # Format: \e]8;;URL\e\\text\e]8;;\e\\
    "\e]8;;#{url}\e\\#{url}\e]8;;\e\\"
  end

  @doc """
  Returns metadata for the plugin.
  """
  def get_metadata do
    %{
      name: "hyperlink",
      version: "0.1.0",
      dependencies: []
    }
  end
end
