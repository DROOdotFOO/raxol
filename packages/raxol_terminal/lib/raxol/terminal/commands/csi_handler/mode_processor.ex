defmodule Raxol.Terminal.Commands.CSIHandler.ModeProcessor do
  @moduledoc false

  # CSI h / CSI l dispatch. `ModeTypes` is the only place a mode number maps to
  # a mode; this module carries no table of its own. An unregistered number is
  # ignored, as is a registered mode the handler refuses.
  #
  # Mouse reporting (1000/1002) and mouse encoding (1006) are separate modes
  # with separate fields, so the driver's `\e[?1000h\e[?1006h` handshake and a
  # later `\e[?1006l` each touch only their own field.

  alias Raxol.Terminal.ModeManager
  alias Raxol.Terminal.Modes.Types.ModeTypes

  def handle_h_or_l(emulator, params, intermediates, final_byte) do
    set? = final_byte == ?h

    lookup =
      if intermediates == "?", do: &ModeTypes.lookup_private/1, else: &ModeTypes.lookup_standard/1

    Enum.reduce(params, emulator, fn param, acc ->
      code = if is_integer(param), do: param, else: String.to_integer(param)

      case lookup.(code) do
        nil -> acc
        mode_def -> apply_mode_change(acc, mode_def, set?)
      end
    end)
  end

  defp apply_mode_change(emulator, %{name: name, category: category}, set?) do
    result =
      if set?,
        do: ModeManager.set_mode(emulator, [name], category),
        else: ModeManager.reset_mode(emulator, [name], category)

    case result do
      {:ok, emu} -> emu
      {:error, _reason} -> emulator
    end
  end
end
