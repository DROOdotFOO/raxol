defmodule :termbox2_nif do
  @moduledoc """
  Termbox2 NIF for Elixir - A terminal UI library.
  """

  @on_load :load_nif

  def load_nif do
    # Skip NIF loading on Windows - use pure Elixir driver instead
    case :os.type() do
      {:win32, _} ->
        :ok

      {:unix, _} ->
        case load_unix_nif() do
          :ok ->
            :ok

          {:error, reason} ->
            IO.puts(:stderr, "[termbox2_nif] NIF load failed: #{inspect(reason)}")
            # Return :ok so module loads with stubs (web/SSH deployments don't need NIF)
            :ok
        end
    end
  end

  defp load_unix_nif do
    # Try raxol_terminal's priv directory first (NIF lives in this package)
    priv_dir =
      case :code.priv_dir(:raxol_terminal) do
        {:error, _} ->
          # Fallback to raxol app's priv directory
          case :code.priv_dir(:raxol) do
            {:error, _} ->
              # Fallback to termbox2_nif app priv directory
              case :code.priv_dir(:termbox2_nif) do
                {:error, _} ->
                  # Final fallback: construct path relative to current module
                  case :code.which(__MODULE__) do
                    :non_existing ->
                      Path.join([File.cwd!(), "priv"])

                    path ->
                      path
                      |> List.to_string()
                      |> Path.dirname()
                      |> Path.dirname()
                      |> Path.dirname()
                      |> Path.join("priv")
                  end

                dir ->
                  List.to_string(dir)
              end

            dir ->
              List.to_string(dir)
          end

        dir ->
          List.to_string(dir)
      end

    nif_path = Path.join(priv_dir, "termbox2_nif")

    case :erlang.load_nif(String.to_charlist(nif_path), 0) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Initialize the termbox2 library.
  Returns 0 on success, -1 on error.
  """
  def tb_init, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Shutdown the termbox2 library.
  """
  def tb_shutdown, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Get the width of the terminal.
  """
  def tb_width, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Get the height of the terminal.
  """
  def tb_height, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Clear the terminal.
  """
  def tb_clear, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Present the changes to the terminal.
  """
  def tb_present, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Set the cursor position.
  """
  def tb_set_cursor(_x, _y), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Hide the cursor.
  Returns 0 on success, -1 on error.
  """
  def tb_hide_cursor, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Set a cell in the terminal.
  Returns 0 on success, -1 on error.
  """
  def tb_set_cell(_x, _y, _ch, _fg, _bg), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Set the input mode.
  Returns the previous mode.
  """
  def tb_set_input_mode(_mode), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Set the output mode.
  Returns the previous mode.
  """
  def tb_set_output_mode(_mode), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Print a string at the specified position.
  Returns 0 on success, -1 on error.
  """
  def tb_print(_x, _y, _fg, _bg, _str), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Read back the back buffer as a row-major list of `{ch, fg, bg}` tuples.

  One tuple per cell, `tb_width() * tb_height()` in total, indexed
  `(y * width) + x`. Reflects drawing calls (`tb_set_cell`, `tb_print`) before
  `tb_present`. Used by the reference-oracle equivalence tests.
  """
  def tb_cell_buffer, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Set the terminal title.
  Returns {:ok, "set"} on success, {:error, reason} on failure.
  """
  def tb_set_title(_title), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Set the terminal window position.
  Returns {:ok, "set"} on success, {:error, reason} on failure.
  """
  def tb_set_position(_x, _y), do: :erlang.nif_error(:nif_not_loaded)
end
