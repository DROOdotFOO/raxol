defmodule Raxol.Terminal.Commands.ModeHandler do
  @moduledoc false

  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.ModeManager

  @spec handle_h_or_l(Emulator.t(), list(integer()), String.t(), char()) ::
          {:ok, Emulator.t()} | {:error, atom(), Emulator.t()}
  def handle_h_or_l(emulator, params, intermediates_buffer, final_byte) do
    action = determine_action(final_byte == ?h)

    process_mode_by_buffer(
      intermediates_buffer == "?",
      emulator,
      params,
      action
    )
  end

  defp determine_action(true), do: :set
  defp determine_action(false), do: :reset

  defp process_mode_by_buffer(true, emulator, params, action) do
    apply_mode_func = select_dec_mode_func(action == :set)
    result = handle_dec_private_mode(emulator, params, apply_mode_func)
    {:ok, result}
  end

  defp process_mode_by_buffer(false, emulator, params, action) do
    apply_mode_func = select_standard_mode_func(action == :set)
    result = handle_standard_mode(emulator, params, apply_mode_func)
    {:ok, result}
  end

  defp select_dec_mode_func(true), do: &ModeManager.set_mode/3
  defp select_dec_mode_func(false), do: &ModeManager.reset_mode/3

  defp select_standard_mode_func(true), do: &ModeManager.set_mode/2
  defp select_standard_mode_func(false), do: &ModeManager.reset_mode/2

  @spec handle_dec_private_mode(
          Emulator.t(),
          list(integer()),
          fun()
        ) :: Emulator.t()
  defp handle_dec_private_mode(emulator, params, apply_mode_func) do
    Enum.reduce(
      params,
      emulator,
      &handle_dec_private_mode_param(&1, &2, apply_mode_func)
    )
  end

  @spec handle_dec_private_mode_param(integer(), Emulator.t(), fun()) ::
          Emulator.t()
  defp handle_dec_private_mode_param(param_code, emulator, apply_mode_func) do
    mode_atom = ModeManager.lookup_private(param_code)
    apply_mode_if_found(mode_atom, emulator, apply_mode_func, :dec_private)
  end

  defp apply_mode_if_found(nil, emulator, _apply_mode_func, _type), do: emulator

  defp apply_mode_if_found(mode_atom, emulator, apply_mode_func, :dec_private) do
    case apply_mode_func.(emulator, [mode_atom], :dec_private) do
      {:ok, updated_emulator} -> updated_emulator
      {:error, _reason} -> emulator
    end
  end

  @spec handle_standard_mode(
          Emulator.t(),
          list(integer()),
          fun()
        ) :: Emulator.t()
  defp handle_standard_mode(emulator, params, apply_mode_func) do
    Enum.reduce(
      params,
      emulator,
      &handle_standard_mode_param(&1, &2, apply_mode_func)
    )
  end

  @spec handle_standard_mode_param(integer(), Emulator.t(), fun()) ::
          Emulator.t()
  defp handle_standard_mode_param(param_code, emulator, apply_mode_func) do
    mode_atom = ModeManager.lookup_standard(param_code)

    apply_standard_mode_if_found(
      mode_atom,
      param_code,
      emulator,
      apply_mode_func
    )
  end

  defp apply_standard_mode_if_found(nil, param_code, emulator, _apply_mode_func) do
    handle_unknown_standard_mode(param_code, emulator)
  end

  defp apply_standard_mode_if_found(
         mode_atom,
         _param_code,
         emulator,
         apply_mode_func
       ) do
    case apply_mode_func.(emulator, [mode_atom]) do
      {:ok, updated_emulator} -> updated_emulator
      {:error, _reason} -> emulator
    end
  end

  @spec handle_unknown_standard_mode(integer(), Emulator.t()) :: Emulator.t()
  defp handle_unknown_standard_mode(param_code, emulator) do
    case param_code do
      2 ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "Standard mode code 2 (KAM) not directly in ModeManager's map. Effect depends on ModeManager internals.",
          %{}
        )

        emulator

      12 ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "Standard mode code 12 (SRM) not directly in ModeManager's map. Effect depends on ModeManager internals.",
          %{}
        )

        emulator

      _ ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "Unknown standard mode code: #{param_code}",
          %{}
        )

        emulator
    end
  end

  @spec handle_h(Emulator.t(), list(integer())) ::
          {:ok, Emulator.t()} | {:error, atom(), Emulator.t()}
  def handle_h(emulator, params) do
    handle_h_or_l(emulator, params, "", ?h)
  end

  @spec handle_l(Emulator.t(), list(integer())) ::
          {:ok, Emulator.t()} | {:error, atom(), Emulator.t()}
  def handle_l(emulator, params) do
    handle_h_or_l(emulator, params, "", ?l)
  end
end
