defmodule Raxol.Terminal.Driver.TerminalSize do
  @moduledoc """
  Terminal size detection: termbox, stty, and fallback strategies.
  """

  # Suppressed: @termbox2_available is false at compile time in test env,
  # making NIF branches unreachable for dialyzer analysis.
  @dialyzer :no_match

  alias Raxol.Terminal.IOTerminal

  import Raxol.Terminal.TerminalUtils, only: [has_terminal_device?: 0]

  @termbox2_available Code.ensure_loaded?(:termbox2_nif)
  alias Raxol.Terminal.Env

  @doc """
  Returns the current terminal size as {:ok, width, height}.
  """
  def get_terminal_size do
    determine_terminal_size()
  end

  defp determine_terminal_size do
    cond do
      Env.test?() -> {:ok, 80, 24}
      has_terminal_device?() -> get_termbox_size()
      true -> stty_size_fallback()
    end
  end

  defp get_termbox_size do
    Raxol.Core.ErrorHandling.safe_call(fn ->
      width = get_termbox_width()
      height = get_termbox_height()

      case width > 0 and height > 0 do
        true -> {:ok, width, height}
        false -> stty_size_fallback()
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, _reason} -> stty_size_fallback()
    end
  end

  @dialyzer {:nowarn_function, get_termbox_width: 0}
  defp get_termbox_width do
    if @termbox2_available do
      :termbox2_nif.tb_width()
    else
      case IOTerminal.get_terminal_size() do
        {:ok, {width, _height}} -> width
      end
    end
  end

  @dialyzer {:nowarn_function, get_termbox_height: 0}
  defp get_termbox_height do
    if @termbox2_available do
      :termbox2_nif.tb_height()
    else
      case IOTerminal.get_terminal_size() do
        {:ok, {_width, height}} -> height
      end
    end
  end

  defp stty_size_fallback do
    case {:io.columns(), :io.rows()} do
      {{:ok, cols}, {:ok, rows}} ->
        {:ok, cols, rows}

      _ ->
        # In -noshell mode, :io.columns/rows fail. Use stty via /dev/tty.
        case Raxol.Terminal.Driver.Stty.size() do
          {:ok, cols, rows} -> {:ok, cols, rows}
          :error -> {:ok, 80, 24}
        end
    end
  end
end
