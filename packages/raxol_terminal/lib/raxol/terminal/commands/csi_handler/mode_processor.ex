defmodule Raxol.Terminal.Commands.CSIHandler.ModeProcessor do
  @moduledoc false

  # CSI h / CSI l dispatch. `ModeTypes` is the only place a mode number maps to
  # a mode; this module carries no table of its own. A parameter is dropped
  # when it is not a well-formed integer (`\e[?1;h` yields a `nil` slot,
  # `\e[?4:3h` a colon-subparameter list), when its number is unregistered,
  # when the registered mode has no handler (`?12` -> `:att_blink`), or when
  # the handler refuses it. The remaining parameters still apply.
  #
  # Mouse reporting (1000/1002) and mouse encoding (1006) are separate modes
  # with separate fields, so the driver's `\e[?1000h\e[?1006h` handshake and a
  # later `\e[?1006l` each touch only their own field.

  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.ModeManager
  alias Raxol.Terminal.Modes.Types.ModeTypes

  @doc """
  Applies every mode number in `params` as a set (`?h`) or reset (`?l`).
  `intermediates` of `"?"` selects the DEC private table, anything else the
  standard table. Malformed, unregistered and unhandled parameters are
  skipped; the emulator is always returned.
  """
  @spec handle_h_or_l(
          Emulator.t(),
          [integer() | String.t() | nil | list()],
          String.t(),
          char()
        ) :: Emulator.t()
  def handle_h_or_l(emulator, params, intermediates, final_byte) do
    set? = final_byte == ?h

    lookup =
      if intermediates == "?", do: &ModeTypes.lookup_private/1, else: &ModeTypes.lookup_standard/1

    Enum.reduce(params, emulator, fn param, acc ->
      case mode_code(param) do
        nil -> acc
        code -> apply_mode_code(acc, lookup.(code), set?)
      end
    end)
  end

  defp mode_code(param) when is_integer(param), do: param

  defp mode_code(param) when is_binary(param) do
    case Integer.parse(param) do
      {code, ""} -> code
      _ -> nil
    end
  end

  defp mode_code(_), do: nil

  defp apply_mode_code(emulator, nil, _set?), do: emulator

  defp apply_mode_code(emulator, %{name: name, category: category}, set?) do
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
