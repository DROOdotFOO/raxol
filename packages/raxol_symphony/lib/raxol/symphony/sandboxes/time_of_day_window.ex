defmodule Raxol.Symphony.Sandboxes.TimeOfDayWindow do
  @moduledoc """
  `Raxol.Agent.Sandbox` impl that allows `:turn` only during a
  configured hour window (e.g. "business hours").

  ## Configuration

      %Raxol.Symphony.Sandboxes.TimeOfDayWindow{
        start_hour: 9,   # 9am, inclusive
        end_hour: 17,    # 5pm, exclusive
        timezone: "Etc/UTC"  # IANA tz, default Etc/UTC
      }

  ## Behaviour

  On each `:turn` authorization:

  1. Read `DateTime.utc_now/0`, shift to `timezone` if not UTC.
  2. Allow when `start_hour <= hour < end_hour`.
  3. Deny otherwise with `{:deny, :outside_window}`.

  ## Window semantics

  - `start_hour <= end_hour`: a single contiguous daytime window.
    Allow when `start_hour <= hour < end_hour`.
  - `start_hour > end_hour`: a window that crosses midnight
    (e.g. "9pm to 6am" = `start_hour: 21, end_hour: 6`).
    Allow when `hour >= start_hour OR hour < end_hour`.

  ## Timezone

  Timezone shifting requires either Elixir 1.17+ built-in support or
  the `:tz` package. The default `"Etc/UTC"` requires neither. Custom
  timezones fall back to UTC if shifting fails; this is the safe
  default since refusing to run during a tz-resolution failure
  could be more disruptive than running an hour off.

  ## Other actions

  Abstains (`:ok`) for any action other than `:turn`.
  """

  @enforce_keys [:start_hour, :end_hour]
  defstruct [:start_hour, :end_hour, timezone: "Etc/UTC"]

  @type t :: %__MODULE__{
          start_hour: 0..23,
          end_hour: 0..23,
          timezone: String.t()
        }

  @doc """
  Public predicate used by the protocol impl. Exposed so consumers
  can pre-check whether a sandbox would allow a turn at a given
  time (useful for dashboards, dry-run mode).

  ## Examples

      iex> sandbox = %Raxol.Symphony.Sandboxes.TimeOfDayWindow{start_hour: 9, end_hour: 17}
      iex> Raxol.Symphony.Sandboxes.TimeOfDayWindow.allows?(sandbox, 10)
      true

      iex> sandbox = %Raxol.Symphony.Sandboxes.TimeOfDayWindow{start_hour: 9, end_hour: 17}
      iex> Raxol.Symphony.Sandboxes.TimeOfDayWindow.allows?(sandbox, 20)
      false

      iex> sandbox = %Raxol.Symphony.Sandboxes.TimeOfDayWindow{start_hour: 21, end_hour: 6}
      iex> Raxol.Symphony.Sandboxes.TimeOfDayWindow.allows?(sandbox, 22)
      true

      iex> sandbox = %Raxol.Symphony.Sandboxes.TimeOfDayWindow{start_hour: 21, end_hour: 6}
      iex> Raxol.Symphony.Sandboxes.TimeOfDayWindow.allows?(sandbox, 3)
      true

      iex> sandbox = %Raxol.Symphony.Sandboxes.TimeOfDayWindow{start_hour: 21, end_hour: 6}
      iex> Raxol.Symphony.Sandboxes.TimeOfDayWindow.allows?(sandbox, 12)
      false
  """
  @spec allows?(t(), 0..23) :: boolean()
  def allows?(%__MODULE__{start_hour: s, end_hour: e}, hour)
      when s <= e and hour >= s and hour < e,
      do: true

  def allows?(%__MODULE__{start_hour: s, end_hour: e}, hour) when s > e do
    hour >= s or hour < e
  end

  def allows?(_sandbox, _hour), do: false

  @doc false
  @spec current_hour(t()) :: 0..23
  def current_hour(%__MODULE__{timezone: "Etc/UTC"}) do
    DateTime.utc_now().hour
  end

  def current_hour(%__MODULE__{timezone: tz}) do
    case shift_zone(DateTime.utc_now(), tz) do
      {:ok, dt} -> dt.hour
      _ -> DateTime.utc_now().hour
    end
  end

  defp shift_zone(dt, tz) do
    if function_exported?(DateTime, :shift_zone, 2) do
      apply(DateTime, :shift_zone, [dt, tz])
    else
      {:error, :no_tz_support}
    end
  end
end

defimpl Raxol.Agent.Sandbox, for: Raxol.Symphony.Sandboxes.TimeOfDayWindow do
  alias Raxol.Symphony.Sandboxes.TimeOfDayWindow

  def authorize(%TimeOfDayWindow{} = sandbox, :turn, _payload, _ctx) do
    if TimeOfDayWindow.allows?(sandbox, TimeOfDayWindow.current_hour(sandbox)) do
      :ok
    else
      {:deny, :outside_window}
    end
  end

  def authorize(_sandbox, _action, _payload, _ctx), do: :ok
end
