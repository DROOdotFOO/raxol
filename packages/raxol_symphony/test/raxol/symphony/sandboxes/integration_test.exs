defmodule Raxol.Symphony.Sandboxes.IntegrationTest do
  @moduledoc """
  End-to-end: wire `Raxol.Symphony.Sandboxes.{TurnRateLimit,
  TimeOfDayWindow}` through `agent.sandboxes` and run the
  `RaxolAgent` runner. Proves the reference impls compose with
  the per-turn authorization wired in Phase 13.
  """

  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue}
  alias Raxol.Symphony.Runners.RaxolAgent
  alias Raxol.Symphony.Sandboxes.{BudgetCap, TimeOfDayWindow, TurnRateLimit}
  alias Raxol.Symphony.Trackers.Memory

  setup do
    start_supervised!({Memory, []})
    :ok
  end

  defp config(sandboxes, max_turns \\ 1) do
    Config.from_workflow(%{
      config: %{
        tracker: %{
          kind: "memory",
          active_states: ["Todo", "In Progress"],
          terminal_states: ["Done", "Cancelled"]
        },
        agent: %{max_turns: max_turns},
        runner: %{
          kind: "raxol_agent",
          agent: %{
            backend: "mock",
            response: "ok",
            workflow_mode: true,
            sandboxes: sandboxes
          }
        }
      },
      prompt_template: "{{ issue.identifier }}"
    })
  end

  defp issue do
    %Issue{id: "issue-1", identifier: "MT-1", title: "T", state: "Todo"}
  end

  defp attach_denied(test_pid) do
    handler_id = "integ_denied_#{:erlang.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:raxol, :symphony, :sandbox, :denied],
      fn _e, _m, metadata, _ -> send(test_pid, {:denied, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "TurnRateLimit" do
    test "second turn within window is denied" do
      Memory.put_issue(%{issue() | state: "In Progress"})
      attach_denied(self())

      sandbox = %TurnRateLimit{
        max_turns: 1,
        window_ms: 30_000,
        bucket_table: :"integ_trl_#{:erlang.unique_integer([:positive])}"
      }

      cfg = config([sandbox], 3)

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      # Turn 1 is allowed -- mock backend's :turn_completed arrives.
      assert_received {:run_event, "issue-1", %{event: :turn_completed}}

      # Turns 2 and 3 are rate-limited.
      assert_receive {:denied, %{reason: :rate_limited}}, 200
      assert_receive {:denied, %{reason: :rate_limited}}, 200
    end
  end

  describe "TimeOfDayWindow" do
    test "deny outside the window blocks all turns" do
      Memory.put_issue(%{issue() | state: "In Progress"})
      attach_denied(self())

      # Construct a window that excludes "now".
      now =
        TimeOfDayWindow.current_hour(%TimeOfDayWindow{
          start_hour: 0,
          end_hour: 23,
          timezone: "Etc/UTC"
        })

      start_h = rem(now + 6, 24)
      end_h = rem(now + 8, 24)

      sandbox = %TimeOfDayWindow{
        start_hour: start_h,
        end_hour: end_h,
        timezone: "Etc/UTC"
      }

      cfg = config([sandbox], 2)

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      # Both turns are denied with :outside_window.
      assert_receive {:denied, %{reason: :outside_window}}, 200
      assert_receive {:denied, %{reason: :outside_window}}, 200

      # No turns streamed.
      refute_received {:run_event, "issue-1", %{event: :turn_completed}}
    end
  end

  describe "BudgetCap" do
    test "denies once cumulative spend hits the cap" do
      Memory.put_issue(%{issue() | state: "In Progress"})
      attach_denied(self())

      sandbox = %BudgetCap{
        cap: 1,
        cost_per_turn: 1,
        bucket_table: :"integ_bc_#{:erlang.unique_integer([:positive])}"
      }

      cfg = config([sandbox], 3)

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      # First turn allowed; budget hits the cap mid-second-turn.
      assert_received {:run_event, "issue-1", %{event: :turn_completed}}

      assert_receive {:denied, %{reason: :budget_exceeded}}, 200
      assert_receive {:denied, %{reason: :budget_exceeded}}, 200
    end
  end

  describe "Chain composition" do
    test "rate limit + time window: first-deny wins" do
      Memory.put_issue(%{issue() | state: "Done"})
      attach_denied(self())

      rate_limit = %TurnRateLimit{
        max_turns: 0,
        window_ms: 30_000,
        bucket_table: :"integ_chain_#{:erlang.unique_integer([:positive])}"
      }

      time_window = %TimeOfDayWindow{start_hour: 0, end_hour: 23}

      cfg = config([rate_limit, time_window], 1)

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      # Rate limit (first in chain) fires before the time window check
      # is reached.
      assert_receive {:denied, %{reason: :rate_limited}}, 200
    end
  end
end
