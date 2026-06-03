defmodule Raxol.Payments.Telemetry.LoggerHandler do
  @moduledoc """
  Stock `:telemetry` handler that pretty-prints payment events to
  `Logger`. Useful as a starter template -- copy + tailor for Datadog,
  OpenTelemetry, Phoenix.LiveDashboard, etc.

  Handles the three events emitted by `Raxol.Payments.Telemetry`:

    * `[:raxol, :payments, :spend]`       -> `:info`
    * `[:raxol, :payments, :over_budget]` -> `:warning`
    * `[:raxol, :payments, :freeze]`      -> `:warning` (frozen) or `:info` (unfrozen)

  ## Usage

      # In your application start/2:
      Raxol.Payments.Telemetry.LoggerHandler.attach()

  Detach with `Raxol.Payments.Telemetry.LoggerHandler.detach/0`.

  ## Customization

  The default formatter renders one structured line per event. To
  override:

      Raxol.Payments.Telemetry.LoggerHandler.attach(handler_id: "my-pay",
        formatter: &MyApp.format_pay_event/3)

  `formatter/3` receives `(event_name, measurements, metadata)` and
  returns the string passed to `Logger`.
  """

  require Logger

  alias Raxol.Payments.Telemetry

  @default_handler_id "raxol-payments-logger"

  @type formatter :: (event_name :: [atom()], measurements :: map(), metadata :: map() ->
                        iodata())

  @doc """
  Attach the handler to every event emitted by `Raxol.Payments.Telemetry`.

  Returns `:ok` on success or `{:error, :already_exists}` if a handler
  with the same id is already attached.
  """
  @spec attach(keyword()) :: :ok | {:error, :already_exists}
  def attach(opts \\ []) do
    handler_id = Keyword.get(opts, :handler_id, @default_handler_id)
    formatter = Keyword.get(opts, :formatter, &__MODULE__.default_format/3)

    :telemetry.attach_many(
      handler_id,
      Telemetry.events(),
      &__MODULE__.handle_event/4,
      %{formatter: formatter}
    )
  end

  @doc "Detach the default handler. Pass `handler_id` to detach a custom one."
  @spec detach(String.t()) :: :ok | {:error, :not_found}
  def detach(handler_id \\ @default_handler_id),
    do: :telemetry.detach(handler_id)

  @doc false
  def handle_event(event, measurements, metadata, %{formatter: formatter}) do
    line = formatter.(event, measurements, metadata)

    case event do
      [:raxol, :payments, :spend] -> Logger.info(line)
      [:raxol, :payments, :over_budget] -> Logger.warning(line)
      [:raxol, :payments, :freeze] -> log_freeze(metadata, line)
      _ -> Logger.info(line)
    end
  end

  defp log_freeze(%{frozen?: true}, line), do: Logger.warning(line)
  defp log_freeze(_, line), do: Logger.info(line)

  @doc """
  Default formatter: one-line structured rendering with the event name
  followed by sorted key/value pairs.
  """
  @spec default_format([atom()], map(), map()) :: iodata()
  def default_format(event, measurements, metadata) do
    [
      format_event(event),
      ?\s,
      format_measurements(measurements),
      ?\s,
      format_metadata(metadata)
    ]
  end

  defp format_event([:raxol, :payments, kind]), do: ["payments.", Atom.to_string(kind)]
  defp format_event(other), do: inspect(other)

  defp format_measurements(measurements) when map_size(measurements) == 0, do: "{}"

  defp format_measurements(%{amount: %Decimal{} = amount} = m) do
    rest = m |> Map.delete(:amount) |> kv_pairs()
    ["amount=", Decimal.to_string(amount, :normal) | rest]
  end

  defp format_measurements(m), do: kv_pairs(m)

  defp format_metadata(meta) when map_size(meta) == 0, do: ""
  defp format_metadata(meta), do: kv_pairs(meta)

  defp kv_pairs(map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> [?\s, to_string(k), ?=, format_value(v)] end)
  end

  defp format_value(%Decimal{} = v), do: Decimal.to_string(v, :normal)
  defp format_value(v) when is_binary(v), do: v
  defp format_value(v) when is_atom(v), do: Atom.to_string(v)
  defp format_value(v) when is_integer(v) or is_boolean(v), do: to_string(v)
  defp format_value(v), do: inspect(v)
end
