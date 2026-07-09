defmodule Raxol.Terminal.Session.Serializer do
  @moduledoc """
  Handles serialization and deserialization of terminal session state.

  Refactored version with pure functional error handling patterns.
  All try/catch blocks have been replaced with with statements and proper error tuples.
  """

  alias Raxol.Terminal.{Emulator, ScreenBuffer, Session}
  alias Raxol.Terminal.ScreenBuffer.Core, as: ConsolidatedBuffer

  @default_width Raxol.Core.Defaults.terminal_width()
  @default_height Raxol.Core.Defaults.terminal_height()
  @default_scrollback Raxol.Core.Defaults.scrollback_limit()

  @doc """
  Serializes a session state to a map that can be stored and later restored.
  """
  @spec serialize(Session.t()) :: {:ok, map()} | {:error, term()}
  def serialize(%Session{} = session) do
    with {:ok, emulator_data} <- safe_serialize_emulator(session.emulator),
         {:ok, renderer_data} <- safe_serialize_renderer(session.renderer) do
      {:ok,
       %{
         id: session.id,
         width: session.width,
         height: session.height,
         title: session.title,
         theme: session.theme,
         auto_save: session.auto_save,
         emulator: emulator_data,
         renderer: renderer_data
       }}
    else
      {:error, reason} = error ->
        Raxol.Core.Runtime.Log.error("Session serialization failed: #{inspect(reason)}")

        error
    end
  end

  @doc """
  Serializes a session state to a map, returning the map directly for backward compatibility.
  Falls back to empty session data on error.
  """
  @spec serialize!(Session.t()) :: map()
  def serialize!(%Session{} = session) do
    case serialize(session) do
      {:ok, data} ->
        data

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "Session serialization failed, returning fallback: #{inspect(reason)}"
        )

        # Return minimal valid session data
        %{
          id: session.id,
          width: session.width || @default_width,
          height: session.height || @default_height,
          title: session.title || "",
          theme: session.theme || %{},
          auto_save: session.auto_save || false,
          emulator: %{},
          renderer: %{}
        }
    end
  end

  @doc """
  Deserializes a session state from a map.
  """
  @spec deserialize(map()) :: {:ok, Session.t()} | {:error, term()}
  def deserialize(%{
        id: id,
        width: width,
        height: height,
        title: title,
        theme: theme,
        auto_save: auto_save,
        emulator: emulator_data,
        renderer: renderer_data
      }) do
    with {:ok, emulator} <- deserialize_emulator(emulator_data),
         {:ok, renderer} <- deserialize_renderer(renderer_data) do
      session = %Session{
        id: id,
        width: width,
        height: height,
        title: title,
        theme: theme,
        auto_save: auto_save,
        emulator: emulator,
        renderer: renderer
      }

      {:ok, session}
    end
  end

  def deserialize(invalid_data) do
    Raxol.Core.Runtime.Log.error("Invalid session data: #{inspect(invalid_data)}")

    {:error, :invalid_session_data}
  end

  # Safe serialization helpers with error handling

  defp safe_serialize_emulator(%Emulator{} = emulator) do
    with {:ok, main_buffer} <-
           safe_serialize_screen_buffer(emulator.main_screen_buffer),
         {:ok, alt_buffer} <-
           safe_serialize_screen_buffer(emulator.alternate_screen_buffer),
         {:ok, scrollback} <-
           safe_serialize_screen_buffer(emulator.scrollback_buffer) do
      {:ok,
       %{
         main_screen_buffer: main_buffer,
         alternate_screen_buffer: alt_buffer,
         active_buffer_type: emulator.active_buffer_type,
         scrollback_buffer: scrollback,
         cursor: emulator.cursor,
         mode_manager: emulator.mode_manager,
         style: emulator.style,
         charset_state: emulator.charset_state,
         width: emulator.width,
         height: emulator.height,
         window_state: emulator.window_state,
         state_stack: emulator.state_stack,
         output_buffer: emulator.output_buffer,
         scrollback_limit: emulator.scrollback_limit,
         window_title: emulator.window_title,
         plugin_manager: emulator.plugin_manager,
         saved_cursor: emulator.saved_cursor,
         scroll_region: emulator.scroll_region,
         sixel_state: emulator.sixel_state,
         last_col_exceeded: emulator.last_col_exceeded,
         cursor_blink_rate: emulator.cursor_blink_rate,
         cursor_style: emulator.cursor_style,
         session_id: emulator.session_id,
         client_options: emulator.client_options
       }}
    else
      {:error, reason} ->
        Raxol.Core.Runtime.Log.error("Emulator serialization failed: #{inspect(reason)}")

        {:error, {:emulator_serialization_failed, reason}}
    end
  end

  defp safe_serialize_emulator(nil) do
    {:ok, nil}
  end

  defp safe_serialize_emulator(invalid) do
    Raxol.Core.Runtime.Log.error("Invalid emulator structure: #{inspect(invalid)}")

    {:error, :invalid_emulator_structure}
  end

  defp safe_serialize_renderer(renderer) when is_map(renderer) do
    case safe_serialize_screen_buffer(Map.get(renderer, :screen_buffer)) do
      {:ok, buffer} ->
        {:ok,
         %{
           screen_buffer: buffer,
           theme: Map.get(renderer, :theme)
         }}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error("Renderer serialization failed: #{inspect(reason)}")

        {:error, {:renderer_serialization_failed, reason}}
    end
  end

  defp safe_serialize_renderer(nil) do
    {:ok, nil}
  end

  defp safe_serialize_renderer(invalid) do
    Raxol.Core.Runtime.Log.error("Invalid renderer structure: #{inspect(invalid)}")

    {:error, :invalid_renderer_structure}
  end

  defp safe_serialize_screen_buffer(%ScreenBuffer{} = buffer) do
    case safe_serialize_cells(buffer.cells) do
      {:ok, cells} ->
        {:ok,
         %{
           width: buffer.width,
           height: buffer.height,
           cells: cells,
           cursor_position: buffer.cursor_position
         }}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error("ScreenBuffer serialization failed: #{inspect(reason)}")

        {:error, {:buffer_serialization_failed, reason}}
    end
  end

  defp safe_serialize_screen_buffer(%ConsolidatedBuffer{} = buffer) do
    case safe_serialize_cells(buffer.cells) do
      {:ok, cells} ->
        {:ok,
         %{
           width: buffer.width,
           height: buffer.height,
           cells: cells,
           cursor_position: buffer.cursor_position
         }}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "ConsolidatedBuffer serialization failed: #{inspect(reason)}"
        )

        {:error, {:buffer_serialization_failed, reason}}
    end
  end

  defp safe_serialize_screen_buffer([]) do
    {:ok, []}
  end

  defp safe_serialize_screen_buffer(buffers) when is_list(buffers) do
    results = Enum.map(buffers, &safe_serialize_screen_buffer/1)

    errors =
      Enum.filter(results, fn
        {:error, _} -> true
        _ -> false
      end)

    case Enum.empty?(errors) do
      true ->
        serialized = Enum.map(results, fn {:ok, data} -> data end)
        {:ok, serialized}

      false ->
        {:error, {:multiple_buffer_errors, errors}}
    end
  end

  defp safe_serialize_screen_buffer(nil) do
    {:ok, nil}
  end

  defp safe_serialize_screen_buffer(invalid) do
    Raxol.Core.Runtime.Log.error("Invalid screen buffer structure: #{inspect(invalid)}")

    {:error, :invalid_screen_buffer}
  end

  defp safe_serialize_cells(cells) when is_list(cells) do
    result =
      cells
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {row, row_idx}, {:ok, acc} ->
        case safe_serialize_row(row, row_idx) do
          {:ok, serialized_row} ->
            {:cont, {:ok, [serialized_row | acc]}}

          {:error, reason} ->
            {:halt, {:error, {:row_serialization_failed, row_idx, reason}}}
        end
      end)

    case result do
      {:ok, serialized} -> {:ok, Enum.reverse(serialized)}
      error -> error
    end
  end

  defp safe_serialize_cells(nil) do
    {:ok, []}
  end

  defp safe_serialize_row(row, _row_idx) when is_list(row) do
    results = Enum.map(row, &safe_serialize_cell/1)

    errors =
      Enum.filter(results, fn
        {:error, _} -> true
        _ -> false
      end)

    case Enum.empty?(errors) do
      true ->
        serialized = Enum.map(results, fn {:ok, data} -> data end)
        {:ok, serialized}

      false ->
        {:error, {:cell_errors, errors}}
    end
  end

  defp safe_serialize_cell(%Raxol.Terminal.Cell{} = cell) do
    case safe_serialize_style(cell.style) do
      {:ok, style} ->
        {:ok,
         %{
           char: cell.char,
           style: style,
           dirty: cell.dirty,
           wide_placeholder: cell.wide_placeholder
         }}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "Cell serialization failed: #{inspect(reason)}, cell: #{inspect(cell)}"
        )

        {:error, {:cell_serialization_failed, reason}}
    end
  end

  defp safe_serialize_cell(nil) do
    # Return default empty cell
    {:ok,
     %{
       char: " ",
       style: serialize_default_style(),
       dirty: false,
       wide_placeholder: false
     }}
  end

  defp safe_serialize_cell(invalid) do
    Raxol.Core.Runtime.Log.warning("Invalid cell structure: #{inspect(invalid)}")

    # Return default cell instead of failing
    safe_serialize_cell(nil)
  end

  defp safe_serialize_style(%Raxol.Terminal.ANSI.TextFormatting{} = style) do
    serialize_style_struct(style)
  end

  defp safe_serialize_style(nil) do
    {:ok, serialize_default_style()}
  end

  defp safe_serialize_style(style) do
    Raxol.Core.Runtime.Log.warning(
      "Unknown style type encountered during serialization: #{inspect(style)}"
    )

    {:error, {:unknown_style_type, style}}
  end

  defp serialize_style_struct(style) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           {:ok, extract_style_fields(style)}
         end) do
      {:ok, result} ->
        result

      {:error, {error, _stacktrace}} ->
        Raxol.Core.Runtime.Log.error("Style serialization exception: #{inspect(error)}")

        {:error, {:style_serialization_exception, error}}
    end
  end

  defp extract_style_fields(style) do
    %{
      bold: style.bold,
      italic: style.italic,
      underline: style.underline,
      blink: style.blink,
      reverse: style.reverse,
      foreground: style.foreground,
      background: style.background,
      double_width: Map.get(style, :double_width, false),
      double_height: Map.get(style, :double_height, false),
      faint: Map.get(style, :faint, false),
      conceal: Map.get(style, :conceal, false),
      strikethrough: Map.get(style, :strikethrough, false),
      fraktur: Map.get(style, :fraktur, false),
      double_underline: Map.get(style, :double_underline, false),
      framed: Map.get(style, :framed, false),
      encircled: Map.get(style, :encircled, false),
      overlined: Map.get(style, :overlined, false),
      hyperlink: Map.get(style, :hyperlink)
    }
  end

  defp serialize_default_style do
    %{
      bold: false,
      italic: false,
      underline: false,
      blink: false,
      reverse: false,
      foreground: nil,
      background: nil,
      double_width: false,
      double_height: false,
      faint: false,
      conceal: false,
      strikethrough: false,
      fraktur: false,
      double_underline: false,
      framed: false,
      encircled: false,
      overlined: false,
      hyperlink: nil
    }
  end

  # Deserialization functions

  defp deserialize_emulator(emulator_data) when is_map(emulator_data) do
    with {:ok, main_screen_buffer} <-
           deserialize_screen_buffer(Map.get(emulator_data, :main_screen_buffer)),
         {:ok, alternate_screen_buffer} <-
           deserialize_screen_buffer(Map.get(emulator_data, :alternate_screen_buffer)),
         {:ok, scrollback_buffer} <-
           deserialize_screen_buffer(Map.get(emulator_data, :scrollback_buffer)) do
      emulator = %Emulator{
        main_screen_buffer: main_screen_buffer,
        alternate_screen_buffer: alternate_screen_buffer,
        active_buffer_type: Map.get(emulator_data, :active_buffer_type),
        scrollback_buffer: scrollback_buffer,
        cursor: Map.get(emulator_data, :cursor),
        mode_manager: Map.get(emulator_data, :mode_manager),
        style: Map.get(emulator_data, :style),
        charset_state: Map.get(emulator_data, :charset_state),
        width: Map.get(emulator_data, :width),
        height: Map.get(emulator_data, :height),
        window_state: Map.get(emulator_data, :window_state),
        state_stack: Map.get(emulator_data, :state_stack, []),
        output_buffer: Map.get(emulator_data, :output_buffer, ""),
        scrollback_limit: Map.get(emulator_data, :scrollback_limit, @default_scrollback),
        window_title: Map.get(emulator_data, :window_title),
        plugin_manager: Map.get(emulator_data, :plugin_manager),
        saved_cursor: Map.get(emulator_data, :saved_cursor),
        scroll_region: Map.get(emulator_data, :scroll_region),
        sixel_state: Map.get(emulator_data, :sixel_state),
        last_col_exceeded: Map.get(emulator_data, :last_col_exceeded, false),
        cursor_blink_rate: Map.get(emulator_data, :cursor_blink_rate),
        cursor_style: Map.get(emulator_data, :cursor_style),
        session_id: Map.get(emulator_data, :session_id),
        client_options: Map.get(emulator_data, :client_options, %{})
      }

      {:ok, emulator}
    else
      {:error, reason} ->
        {:error, {:emulator_deserialization_failed, reason}}
    end
  end

  defp deserialize_emulator(nil) do
    {:ok, nil}
  end

  defp deserialize_emulator(_invalid) do
    {:error, :invalid_emulator_data}
  end

  defp deserialize_renderer(%{screen_buffer: buffer_data, theme: theme}) do
    case deserialize_screen_buffer(buffer_data) do
      {:ok, screen_buffer} ->
        renderer = %{
          screen_buffer: screen_buffer,
          theme: theme
        }

        {:ok, renderer}

      {:error, reason} ->
        {:error, {:renderer_deserialization_failed, reason}}
    end
  end

  defp deserialize_renderer(nil) do
    {:ok, nil}
  end

  defp deserialize_renderer(_invalid) do
    {:error, :invalid_renderer_data}
  end

  defp deserialize_screen_buffer(%{
         width: width,
         height: height,
         cells: cells,
         cursor_position: cursor_position
       }) do
    {:ok, deserialized_cells} = safe_deserialize_cells(cells)

    screen_buffer = %ScreenBuffer{
      width: width,
      height: height,
      cells: deserialized_cells,
      cursor_position: cursor_position,
      scrollback: [],
      scrollback_limit: @default_scrollback,
      selection: nil,
      scroll_region: nil,
      scroll_position: 0,
      damage_regions: [],
      default_style: Raxol.Terminal.ANSI.TextFormatting.Core.new()
    }

    {:ok, screen_buffer}
  end

  defp deserialize_screen_buffer([]) do
    {:ok, []}
  end

  defp deserialize_screen_buffer(buffers) when is_list(buffers) do
    results = Enum.map(buffers, &deserialize_screen_buffer/1)

    errors =
      Enum.filter(results, fn
        {:error, _} -> true
        _ -> false
      end)

    case Enum.empty?(errors) do
      true ->
        deserialized = Enum.map(results, fn {:ok, data} -> data end)
        {:ok, deserialized}

      false ->
        {:error, {:multiple_buffer_errors, errors}}
    end
  end

  defp deserialize_screen_buffer(nil) do
    {:ok, nil}
  end

  defp deserialize_screen_buffer(_invalid) do
    {:error, :invalid_screen_buffer_data}
  end

  defp safe_deserialize_cells(cells) when is_list(cells) do
    deserialized_rows =
      cells
      |> Enum.with_index()
      |> Enum.map(fn {row, row_idx} ->
        {:ok, deserialized_row} = safe_deserialize_row(row, row_idx)
        deserialized_row
      end)

    {:ok, deserialized_rows}
  end

  defp safe_deserialize_cells(nil) do
    {:ok, []}
  end

  defp safe_deserialize_row(row, _row_idx) when is_list(row) do
    results = Enum.map(row, &safe_deserialize_cell/1)

    errors =
      Enum.filter(results, fn
        {:error, _} -> true
        _ -> false
      end)

    case Enum.empty?(errors) do
      true ->
        deserialized = Enum.map(results, fn {:ok, data} -> data end)
        {:ok, deserialized}

      false ->
        # Log errors but continue with default cells
        Raxol.Core.Runtime.Log.warning("Some cells failed to deserialize: #{inspect(errors)}")

        deserialized =
          Enum.map(results, fn
            {:ok, data} -> data
            {:error, _} -> create_default_cell()
          end)

        {:ok, deserialized}
    end
  end

  defp safe_deserialize_cell(%{
         char: char,
         style: style_data,
         dirty: dirty,
         wide_placeholder: wide_placeholder
       }) do
    case safe_deserialize_style(style_data) do
      {:ok, style} ->
        {:ok,
         %Raxol.Terminal.Cell{
           char: char,
           style: style,
           dirty: dirty,
           wide_placeholder: wide_placeholder
         }}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.warning(
          "Cell deserialization failed: #{inspect(reason)}, using default"
        )

        {:ok, create_default_cell()}
    end
  end

  defp safe_deserialize_cell(_invalid) do
    {:ok, create_default_cell()}
  end

  defp create_default_cell do
    %Raxol.Terminal.Cell{
      char: " ",
      style: Raxol.Terminal.ANSI.TextFormatting.Core.new(),
      dirty: false,
      wide_placeholder: false
    }
  end

  defp safe_deserialize_style(style_data) when is_map(style_data) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           style = %Raxol.Terminal.ANSI.TextFormatting{
             bold: Map.get(style_data, :bold, false),
             italic: Map.get(style_data, :italic, false),
             underline: Map.get(style_data, :underline, false),
             blink: Map.get(style_data, :blink, false),
             reverse: Map.get(style_data, :reverse, false),
             foreground: Map.get(style_data, :foreground),
             background: Map.get(style_data, :background),
             double_width: Map.get(style_data, :double_width, false),
             double_height: Map.get(style_data, :double_height, false),
             faint: Map.get(style_data, :faint, false),
             conceal: Map.get(style_data, :conceal, false),
             strikethrough: Map.get(style_data, :strikethrough, false),
             fraktur: Map.get(style_data, :fraktur, false),
             double_underline: Map.get(style_data, :double_underline, false),
             framed: Map.get(style_data, :framed, false),
             encircled: Map.get(style_data, :encircled, false),
             overlined: Map.get(style_data, :overlined, false),
             hyperlink: Map.get(style_data, :hyperlink)
           }

           {:ok, style}
         end) do
      {:ok, result} ->
        result

      {:error, {error, _stacktrace}} ->
        Raxol.Core.Runtime.Log.warning("Style deserialization exception: #{inspect(error)}")

        {:ok, Raxol.Terminal.ANSI.TextFormatting.Core.new()}
    end
  end

  defp safe_deserialize_style(nil) do
    {:ok, Raxol.Terminal.ANSI.TextFormatting.Core.new()}
  end

  defp safe_deserialize_style(_invalid) do
    {:ok, Raxol.Terminal.ANSI.TextFormatting.Core.new()}
  end
end
