defmodule Raxol.Payments.Telemetry do
  @moduledoc """
  Telemetry event surface for the payment subsystem.

  Every event is emitted via `:telemetry.execute/3` with no caller-supplied
  config -- attach a handler from your application's start-up code to forward
  to Phoenix.LiveDashboard, Datadog, OpenTelemetry, a plain `IO.inspect`,
  or anywhere else.

  ## Events

  ### `[:raxol, :payments, :spend]`

  Fires when `Raxol.Payments.Ledger` records a successful spend (either via
  `record_spend/4` or the atomic `try_spend/5`).

  | Measurement | Type          | Notes                                 |
  | ----------- | ------------- | ------------------------------------- |
  | `:amount`   | `Decimal.t/0` | Human-decimal units (e.g. `0.01`)     |

  | Metadata    | Type          | Notes                                 |
  | ----------- | ------------- | ------------------------------------- |
  | `:agent_id` | `term()`      | Caller-supplied identifier            |
  | `:currency` | `String.t()`  | E.g. `"USDC"`                         |
  | `:metadata` | `map()`       | Whatever the caller attached          |

  ### `[:raxol, :payments, :over_budget]`

  Fires when a `try_spend` or `check_budget` call denies because the policy
  cap was exceeded or the ledger was frozen.

  | Measurement | Type          |
  | ----------- | ------------- |
  | `:amount`   | `Decimal.t/0` |

  | Metadata      | Type    | Values                                                   |
  | ------------- | ------- | -------------------------------------------------------- |
  | `:agent_id`   | `term()` |                                                          |
  | `:limit_type` | atom    | `:per_request` \\| `:session` \\| `:lifetime` \\| `:frozen` |

  ### `[:raxol, :payments, :freeze]`

  Fires when the ledger transitions between frozen and unfrozen. Use this
  to alert operators or kick off a pause-confirmation flow elsewhere.

  | Metadata    | Type      | Values                  |
  | ----------- | --------- | ----------------------- |
  | `:frozen?`  | `boolean()` | new freeze state        |

  ## Attaching a handler

      :telemetry.attach_many(
        "my-pay-watcher",
        [
          [:raxol, :payments, :spend],
          [:raxol, :payments, :over_budget],
          [:raxol, :payments, :freeze]
        ],
        &MyApp.PayWatcher.handle/4,
        nil
      )
  """

  @doc "Convenience list of every event name this subsystem emits."
  @spec events() :: [[atom()]]
  def events do
    [
      [:raxol, :payments, :spend],
      [:raxol, :payments, :over_budget],
      [:raxol, :payments, :freeze]
    ]
  end
end
