defmodule Raxol.Plugins.ImagePlugin do
  @moduledoc """
  Plugin that enables displaying images in the terminal using the iTerm2 image protocol.
  Supports various image formats and provides options for image display.
  """

  @behaviour Raxol.Plugins.Plugin
  @behaviour Raxol.Plugins.LifecycleBehaviour
  alias Raxol.Plugins.Plugin


  # Suppress Dialyzer warning about argument type mismatch for handle_cells/3
  @dialyzer {:nowarn_function, handle_cells: 3}

  # Define the struct type matching the Plugin behaviour
  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          enabled: boolean(),
          config: map(),
          dependencies: list(map()),
          api_version: String.t(),
          image_escape_sequence: String.t() | nil,
          sequence_just_generated: boolean(),
          state: map()
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
    :image_escape_sequence,
    :sequence_just_generated,
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
              "Plugin that displays images in the terminal using iTerm2 protocol.",
            enabled: true,
            config: config,
            dependencies: metadata.dependencies,
            api_version: get_api_version(),
            image_escape_sequence: nil,
            sequence_just_generated: false,
            state: %{}
          },
          config
        )
      )

    {:ok, plugin_state}
  end

  @impl Raxol.Plugins.Plugin
  def handle_input(%__MODULE__{} = plugin, _input) do
    # This plugin doesn't handle input
    {:ok, plugin}
  end

  @impl Raxol.Plugins.Plugin
  def handle_output(%__MODULE__{} = plugin, _output) do
    # This plugin doesn't modify output, just passes it through
    {:ok, plugin}
  end

  @impl Raxol.Plugins.Plugin
  def handle_mouse(%__MODULE__{} = plugin, _event, _emulator_state) do
    # This plugin doesn't handle mouse events
    {:ok, plugin}
  end

  @impl Raxol.Plugins.Plugin
  def handle_resize(%__MODULE__{} = plugin, _width, _height) do
    # This plugin doesn't need to react to resize
    {:ok, plugin}
  end

  @impl Raxol.Plugins.Plugin
  def cleanup(%__MODULE__{} = _plugin) do
    :ok
  end

  @impl Raxol.Plugins.Plugin
  def get_dependencies do
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
  def start(config) do
    {:ok, config}
  end

  @impl Raxol.Plugins.LifecycleBehaviour
  def stop(config) do
    {:ok, config}
  end

  @impl Plugin
  def handle_cells(placeholder_cell, _emulator_state, %__MODULE__{} = plugin) do
    Raxol.Core.Runtime.Log.debug(
      "[ImagePlugin.handle_cells START] Received placeholder: #{inspect(placeholder_cell)}, plugin state: #{inspect(plugin)}"
    )

    case placeholder_cell do
      %{type: :placeholder, value: :image} = _cell ->
        handle_image_placeholder(plugin)

      _ ->
        {:cont, plugin}
    end
  end

  defp handle_image_placeholder(plugin) do
    case plugin.sequence_just_generated do
      true ->
        Raxol.Core.Runtime.Log.debug(
          "[ImagePlugin.handle_cells] sequence_just_generated=true. Resetting flag and declining."
        )

        {:cont, %{plugin | sequence_just_generated: false}}

      false ->
        generate_and_return_sequence(plugin)
    end
  end

  defp generate_and_return_sequence(plugin) do
    Raxol.Core.Runtime.Log.debug(
      "[ImagePlugin.handle_cells] sequence_just_generated=false. BEFORE generate_sequence_from_path for path: @static/static/images/logo.png"
    )

    case generate_sequence_from_path("@static/static/images/logo.png") do
      {:ok, sequence} ->
        Raxol.Core.Runtime.Log.debug(
          "[ImagePlugin.handle_cells] Sequence generated successfully."
        )

        {:ok, %{plugin | sequence_just_generated: true}, [],
         [{:direct_output, sequence}]}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "[ImagePlugin.handle_cells] Failed to generate sequence for @static/static/images/logo.png: #{inspect(reason)}"
        )

        {:cont, plugin}
    end
  end

  defp generate_sequence_from_path(image_path) do
    with {:ok, content} <- File.read(image_path),
         base64_data = Base.encode64(content),
         sequence =
           generate_image_escape_sequence(base64_data, default_params()),
         true <- sequence != "" do
      {:ok, sequence}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :base64_decode_failed}
    end
  end

  defp default_params, do: %{width: 0, height: 0, preserve_aspect: true}

  defp generate_image_escape_sequence(base64_data, params) do
    width = get_dimension(params, :width)
    height = get_dimension(params, :height)

    width_param =
      case width == 0 do
        true -> "auto"
        false -> "#{width}"
      end

    height_param =
      case height == 0 do
        true -> "auto"
        false -> "#{height}"
      end

    preserve_aspect_flag = get_preserve_aspect_flag(params)

    case Base.decode64(base64_data) do
      {:ok, decoded_data} ->
        size = byte_size(decoded_data)

        "\e]1337;File=inline=1;width=#{width_param};height=#{height_param};preserveAspectRatio=#{preserve_aspect_flag};size=#{size};name=image.png;base64,#{base64_data}\a"

      :error ->
        ""
    end
  end

  defp get_dimension(params, dimension) do
    case {params, dimension} do
      {params, :width} when is_map(params) -> Map.get(params, :width, 0)
      {params, :height} when is_map(params) -> Map.get(params, :height, 0)
    end
  end

  defp get_preserve_aspect_flag(params) do
    case Map.get(params, :preserve_aspect) do
      true -> "1"
      false -> "0"
      _ -> "1"
    end
  end

  @doc """
  Returns metadata for the plugin.
  """
  def get_metadata do
    %{
      name: "image",
      version: "0.1.0",
      dependencies: []
    }
  end
end
