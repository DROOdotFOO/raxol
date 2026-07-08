defmodule Raxol.Terminal.Commands.CommandServer.DeviceOps do
  @moduledoc false
  @compile {:no_warn_undefined, Raxol.Terminal.Commands.CommandServer.Helpers}


  alias Raxol.Terminal.Commands.CommandServer.Helpers
  alias Raxol.Terminal.OutputManager

  def handle_device_attributes(
        emulator,
        %{params: params, intermediates: intermediates},
        _context
      ) do
    case {params, intermediates} do
      {[], ""} ->
        response = generate_primary_da_response()
        {:ok, OutputManager.write(emulator, response)}

      {[0], ""} ->
        response = generate_primary_da_response()
        {:ok, OutputManager.write(emulator, response)}

      {[], ">"} ->
        response = generate_secondary_da_response()
        {:ok, OutputManager.write(emulator, response)}

      {[0], ">"} ->
        response = generate_secondary_da_response()
        {:ok, OutputManager.write(emulator, response)}

      _ ->
        {:ok, emulator}
    end
  end

  def handle_device_status_report(emulator, %{params: params}, _context) do
    code = Helpers.get_param(params, 0, 5)
    Raxol.Core.Runtime.Log.debug("DSR request: code=#{code}")

    response =
      case code do
        5 -> "\e[0n"
        6 -> generate_cursor_position_report(emulator)
        _ -> nil
      end

    Raxol.Core.Runtime.Log.debug("DSR response: #{inspect(response)}")

    case response do
      nil -> {:ok, emulator}
      _ -> {:ok, OutputManager.write(emulator, response)}
    end
  end

  defp generate_primary_da_response, do: "\e[?6c"

  defp generate_secondary_da_response, do: "\e[>0;0;0c"

  defp generate_cursor_position_report(emulator) do
    {row, col} =
      case Helpers.get_cursor_position(emulator) do
        {r, c} when is_integer(r) and is_integer(c) -> {r, c}
        _ -> {0, 0}
      end

    "\e[#{row + 1};#{col + 1}R"
  end
end
