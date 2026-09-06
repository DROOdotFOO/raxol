defmodule Raxol.Payments.Telemetry do
  @moduledoc """
  Telemetry event surface for the payment subsystem.

  Every event is emitted via `:telemetry.execute/3` with no caller-supplied
  config -- attach a handler from your application's start-up code to forward
  to Phoenix.LiveDashboard, Datadog, OpenTelemetry, a plain `IO.inspect`,
  or anywhere else.

  ## Classification

  Every event below is also classified as exactly one of `:invariant`, `:peer`
  or `:operational` (see `events/0`), because an event nothing fails on is not
  a guard. `:invariant` events -- ones that can only fire if this library
  itself is wrong -- are armed by `Raxol.Core.Telemetry.InvariantSentinel`,
  which fails any test in which they fire. `:peer` and `:operational` events
  are not enforced.

  This package currently declares NO `:invariant` events, and that is a
  finding rather than an omission. Its telemetry watches money crossing a
  chain through a third-party solver, so every alarming name here resolves to
  the solver, the chain, the network, the clock, or a deployment choice --
  causes the criterion puts outside our control. The registry still earns its
  place: it forces the next event added to this package to be classified
  before it can ship, which is exactly the step that was missing when an
  emitted-and-logged impossible state shipped anyway.

  `events/0` is the complete list. The sections below document the
  longest-standing seven in detail; the rest are documented at their emit
  sites.

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

  # Each verdict below was read off the emit site, never off the event name --
  # the two scariest names here (`:intent_stranded`, `:unchecked_settlement`)
  # are not invariants, and the reasons are recorded per entry so the next
  # reader does not have to re-derive them.
  use Raxol.Core.Telemetry.Invariants,
    events: %{
      # OPERATIONAL. The spend gate admitting a charge: routine bookkeeping.
      [:raxol, :payments, :spend] => :operational,

      # OPERATIONAL. `try_spend` denied because a policy cap was hit or the
      # ledger is frozen. The caps come from a caller-supplied policy, so this
      # is the gate WORKING, and the negative spend-gate tests drive it on
      # purpose.
      [:raxol, :payments, :over_budget] => :operational,

      # OPERATIONAL. An operator (or a kill switch) flipped the freeze flag.
      # A state transition somebody asked for.
      [:raxol, :payments, :freeze] => :operational,

      # OPERATIONAL. `release_by_intent/2` reversed a reservation because the
      # solver refunded the origin funds. The refund is upstream; the emit is
      # our ledger reconciling correctly, and it is idempotent by the presence
      # of the reservation tag.
      [:raxol, :payments, :refund_reconciled] => :operational,

      # OPERATIONAL. `SettlementLedger` booked a completed fill, once per
      # intent. The success path of accounting.
      [:raxol, :payments, :settlement] => :operational,

      # OPERATIONAL x2. `RebalanceAdvisor`'s per-recommendation rows and the
      # per-call summary. Pure output of a function over observed balances --
      # including the `:alert` recommendations, because an underfunded chain
      # is a fact about the wallet, not a defect in this library.
      [:raxol, :payments, :rebalance, :recommendation] => :operational,
      [:raxol, :payments, :rebalance, :advice] => :operational,

      # OPERATIONAL. `Protocols.Xochi.transfer/4` reached a completed terminal
      # status. The happy path; `SettlementAccountant` subscribes to it.
      [:raxol, :payments, :xochi, :settled] => :operational,

      # OPERATIONAL. `AgentStream` got HTTP 202 back for an announce: success.
      [:raxol, :payments, :xochi, :agent_stream, :announced] => :operational,

      # PEER. The announce reached the Xochi agent-stream endpoint and was
      # refused -- 429 rate limit, any other non-202, or a transport error.
      # That is the remote endpoint or the network talking, and the announce is
      # best-effort by construction, so a drop never affects the swap.
      [:raxol, :payments, :xochi, :agent_stream, :dropped] => :peer,

      # OPERATIONAL. The layer ABOVE an attempted announce: no announce was
      # made at all because the topic, wallet or host is unconfigured, the
      # mandate binding did not hold, or the stashed route is missing or
      # expired. Configuration and TTL, i.e. a user and the clock.
      [:raxol, :payments, :xochi, :agent_stream, :announce_skipped] => :operational,

      # PEER, despite the name. `PollXochiStatus` emits this on
      # `{:error, :timeout}`: the intent never reached a terminal status inside
      # the poll budget, so the origin pull may have moved funds while delivery
      # stayed unconfirmed. The cause is the solver or the chain being slow,
      # unreachable or refusing -- issue #772 (funded ACP jobs never settling
      # behind a Xochi 502 `validation_failed`) is exactly this shape. Our
      # bookkeeping is behaving correctly when it fires: it refuses to report
      # success and hands the operator an intent id to reconcile.
      [:raxol, :payments, :xochi, :intent_stranded] => :peer,

      # OPERATIONAL, despite the name. `resolve_checkpoint/2` found no
      # idempotency store while `require_checkpoint?/1` was false, so the
      # settlement proceeds with a double-settle exposure on a crash-retry.
      # Fail-closed is the PRODUCTION default; development and tests are
      # deliberately permissive, so every settlement test that does not pass a
      # `:checkpoint` store fires this on its happy path. It discloses a
      # deployment choice. Enforcing it would fail the ordinary path, which is
      # precisely how a false invariant gets the whole mechanism deleted.
      [:raxol, :payments, :xochi, :unchecked_settlement] => :operational
    }
end
