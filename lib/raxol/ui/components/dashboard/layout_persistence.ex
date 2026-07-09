defmodule Raxol.UI.Components.Dashboard.LayoutPersistence do
  @moduledoc """
  Handles saving and loading dashboard widget layouts to disk.
  """

  # User-specific config dir
  @layout_file Path.expand("~/.raxol/dashboard_layout.bin")

  @doc """
  Saves the current widget layout (list of widget configs) to a file.

  Only saves fields essential for reconstructing the layout and widget state:
  `:id`, `:type`, `:title`, `:grid_spec`, `:component_opts`, `:data`.
  """
  @spec save_layout(list(map())) :: :ok | {:error, term()}
  def save_layout(widgets) when is_list(widgets) do
    layout_file = @layout_file

    case Raxol.Core.ErrorHandling.safe_call(fn ->
           do_save_layout(widgets, layout_file)
         end) do
      {:ok, result} ->
        result

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "Failed to save dashboard layout to #{layout_file}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp do_save_layout(widgets, layout_file) do
    :ok = File.mkdir_p(Path.dirname(layout_file))

    layout_data =
      Enum.map(widgets, fn w ->
        Map.take(w, [:id, :type, :title, :grid_spec, :component_opts, :data])
      end)

    binary_data = :erlang.term_to_binary(layout_data)
    write_layout_file(layout_file, binary_data)
  end

  defp write_layout_file(layout_file, binary_data) do
    case File.write(layout_file, binary_data) do
      :ok ->
        Raxol.Core.Runtime.Log.info("Dashboard layout saved to #{layout_file}")
        :ok

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "Failed to save dashboard layout to #{layout_file}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Loads the widget layout from the file.
  Returns the list of widget configurations `[map()]` or `nil` if load fails or file doesn't exist.
  """
  @spec load_layout() :: list(map()) | nil
  def load_layout do
    layout_file = @layout_file

    case File.exists?(layout_file) do
      true -> load_existing_layout(layout_file)
      false -> handle_missing_layout(layout_file)
    end
  end

  defp load_existing_layout(layout_file) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           read_and_process_layout(layout_file)
         end) do
      {:ok, result} -> result
      {:error, reason} -> handle_deserialization_error(layout_file, reason)
    end
  end

  defp read_and_process_layout(layout_file) do
    case File.read(layout_file) do
      {:ok, binary_data} -> process_layout_data(binary_data, layout_file)
      {:error, reason} -> handle_read_error(layout_file, reason)
    end
  end

  defp process_layout_data(binary_data, layout_file) do
    layout_data = :erlang.binary_to_term(binary_data, [:safe])

    Raxol.Core.Runtime.Log.info("Dashboard layout loaded from #{layout_file}")

    validate_layout_data(layout_data)
  end

  defp validate_layout_data(layout_data) when is_list(layout_data),
    do: layout_data

  defp validate_layout_data(_layout_data), do: nil

  defp handle_read_error(layout_file, reason) do
    Raxol.Core.Runtime.Log.error(
      "Failed to read dashboard layout file #{layout_file}: #{inspect(reason)}"
    )

    nil
  end

  defp handle_deserialization_error(layout_file, e) do
    Raxol.Core.Runtime.Log.error(
      "Failed to deserialize dashboard layout from #{layout_file}: #{inspect(e)}"
    )

    nil
  end

  defp handle_missing_layout(layout_file) do
    Raxol.Core.Runtime.Log.info(
      "No saved dashboard layout found at #{layout_file}"
    )

    nil
  end
end
