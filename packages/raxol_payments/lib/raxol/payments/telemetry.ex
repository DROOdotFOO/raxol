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

  ### `[:raxol, :payments, :xochi, :settled]`

  Fires from `Raxol.Payments.Protocols.Xochi.transfer/4` when an intent reaches a
  completed terminal status. Carries everything the accounting layer needs to book
  the settlement; `Raxol.Payments.SettlementAccountant` subscribes to it.

  | Measurement | Type   | Notes                        |
  | ----------- | ------ | ---------------------------- |
  | `:elapsed_ms` | `integer()` \\| nil | settlement latency, if known |

  Metadata: `:intent_id`, `:from_chain_id`, `:to_chain_id`, `:from_token`,
  `:to_token`, `:from_amount`, `:to_amount`, `:xochi_fee`, `:tx_hash`,
  `:settlement_type`.

  ### `[:raxol, :payments, :settlement]`

  Fires when `Raxol.Payments.SettlementLedger` records a completed fill (once per
  intent; never on a duplicate re-record).

  | Measurement   | Type                 | Notes                                 |
  | ------------- | -------------------- | ------------------------------------- |
  | `:fee_atomic` | `Decimal.t/0`        | Fee collected, atomic units           |
  | `:gas_wei`    | `Decimal.t/0` \\| nil | Native gas burned; nil when unknown   |

  Metadata: `:intent_id`, `:from_chain_id`, `:to_chain_id`, `:token_symbol`,
  `:gas_chain_id`, `:gas_symbol`, `:gas_status`, `:settlement_type`.

  ### `[:raxol, :payments, :rebalance, :recommendation]`

  Fires once per `Raxol.Payments.RebalanceAdvisor.advise/4` recommendation.

  | Measurement | Type                 | Notes                            |
  | ----------- | -------------------- | -------------------------------- |
  | `:amount`   | `Decimal.t/0` \\| nil | USDC to convert / move, or deficit |

  Metadata: `:type` (`:refuel_gas` \\| `:rebalance_usdc` \\| `:alert`) plus
  type-specific keys (`:chain_id`, `:from_chain`, `:to_chain`, `:funding`, `:note`).

  ### `[:raxol, :payments, :rebalance, :advice]`

  Fires once per `advise/4` call with the recommendation counts.

  | Measurement | Type   | Notes                       |
  | ----------- | ------ | --------------------------- |
  | `:count`    | `integer()` | total recommendations  |

  Metadata: `:refuel_count`, `:rebalance_count`, `:alert_count`.

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
      [:raxol, :payments, :freeze],
      [:raxol, :payments, :xochi, :settled],
      [:raxol, :payments, :settlement],
      [:raxol, :payments, :rebalance, :recommendation],
      [:raxol, :payments, :rebalance, :advice]
    ]
  end
end
