defmodule Raxol.System.Updater.Validation do
  @moduledoc """
  Update-check scheduling and version comparison for the Raxol System Updater.
  """

  @default_check_interval 86_400

  @doc """
  Whether an automatic update check is due: automatic checks are on
  (`:auto_check`, default `true`) and `:check_interval` seconds (default one
  day) have passed since `:last_check` (Unix seconds).
  """
  @spec should_check_for_update?(map(), integer()) :: boolean()
  def should_check_for_update?(settings, now \\ :os.system_time(:second)) do
    auto_check = Map.get(settings, :auto_check, true)

    interval =
      positive_integer(
        Map.get(settings, :check_interval),
        @default_check_interval
      )

    last_check = positive_integer(Map.get(settings, :last_check), 0)

    auto_check != false and now - last_check >= interval
  end

  @spec update_last_check(map(), integer()) :: map()
  def update_last_check(settings, now \\ :os.system_time(:second)),
    do: Map.put(settings, :last_check, now)

  @spec compare_versions(String.t(), String.t()) ::
          {:update_available, String.t()} | {:no_update, String.t()}
  def compare_versions(current, latest) do
    if newer?(latest, current),
      do: {:update_available, latest},
      else: {:no_update, current}
  end

  @doc "True when `candidate` is a strictly newer version than `current`."
  @spec newer?(String.t(), String.t()) :: boolean()
  def newer?(candidate, current) do
    case {Version.parse(candidate), Version.parse(current)} do
      {{:ok, c}, {:ok, cur}} -> Version.compare(c, cur) == :gt
      _unparseable -> false
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp positive_integer(_value, default), do: default
end
