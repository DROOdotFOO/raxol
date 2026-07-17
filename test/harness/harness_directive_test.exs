defmodule Raxol.Harness.DirectiveTest do
  @moduledoc """
  The directive half of the frozen A0 contract
  (`Raxol.Harness.Directive.Lane` / `.Editor`,
  `docs/proposals/in-flight/harness-tea-migration.md` §3):

    1. constructors freeze the payload shapes the pump mechanics rely on
       (the model's belief travels IN the directive);
    2. the Executor impls are accepted by the Dispatcher's sanctioned
       extension point (`Directive.Executor.impl_for/1` — the same gate
       `dispatcher.ex` `directive?/1` uses);
    3. execution reaches a pump pid as `{:harness_directive, struct}`
       with telemetry, and nothing else (thin by contract — the
       mechanics land with the pump reshape).
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Runtime.Directive.Executor
  alias Raxol.Harness.Directive
  alias Raxol.Harness.Directive.{Editor, Lane}

  # The Dispatcher context shape (build_command_context/1) — the
  # executors must not depend on any harness-specific key in it.
  defp context, do: %{pid: self(), runtime_pid: self()}

  describe "1. frozen payload shapes" do
    test "submit carries the text" do
      assert %Lane{action: :submit, payload: %{text: "hi"}, pump: pump} =
               Directive.submit(self(), "hi")

      assert pump == self()
    end

    test "interrupt: nil turn id is the EMPTY payload (today's lane wire shape)" do
      assert %Lane{action: :interrupt, payload: payload} =
               Directive.interrupt(self())

      assert payload == %{}

      assert %Lane{action: :interrupt, payload: %{turn_id: "t-9"}} =
               Directive.interrupt(self(), "t-9")
    end

    test "steer carries the model's CAS belief; the pump mints client_msg_id (absent here)" do
      assert %Lane{action: :steer, payload: payload} =
               Directive.steer(self(), "go left", "t-3")

      assert payload == %{text: "go left", expected_turn_id: "t-3"}
      refute Map.has_key?(payload, :client_msg_id)

      # nil belief is expressible — the lane answers :no_live_turn honestly.
      assert %Lane{payload: %{expected_turn_id: nil}} =
               Directive.steer(self(), "go", nil)
    end

    test "approval_answer freezes the referent triple and validates the decision class" do
      answer = %{
        request_id: "req-1",
        option_id: "opt-2",
        decision: :allow,
        stray: :dropped
      }

      assert %Lane{action: :approval_answer, payload: payload} =
               Directive.approval_answer(self(), answer)

      assert payload == %{
               request_id: "req-1",
               option_id: "opt-2",
               decision: :allow
             }

      assert_raise FunctionClauseError, fn ->
        Directive.approval_answer(self(), %{
          request_id: "r",
          option_id: "o",
          decision: :maybe
        })
      end
    end

    test "halt carries no payload — teardown ordering is the pump's (PumpContract §8)" do
      assert %Lane{action: :halt, payload: %{}} = Directive.halt(self())
    end

    test "edit_draft carries the current composer draft" do
      assert %Editor{draft: "dear diary", pump: pump} =
               Directive.edit_draft(self(), "dear diary")

      assert pump == self()
    end
  end

  describe "2. the Dispatcher's directive gate accepts these structs" do
    test "Executor.impl_for/1 is non-nil for both (dispatcher.ex directive?/1)" do
      assert Executor.impl_for(Directive.halt(self())) != nil
      assert Executor.impl_for(Directive.edit_draft(self(), "")) != nil
    end
  end

  describe "3. execution: send + telemetry, nothing else" do
    test "a Lane directive reaches the pump pid as {:harness_directive, struct}" do
      directive = Directive.submit(self(), "prompt text")
      Executor.execute(directive, context())

      assert_receive {:harness_directive, ^directive}
    end

    test "every Lane action reaches the pump with its struct intact" do
      directives = [
        Directive.submit(self(), "t"),
        Directive.interrupt(self(), "t-1"),
        Directive.steer(self(), "s", "t-1"),
        Directive.approval_answer(self(), %{
          request_id: "r",
          option_id: "o",
          decision: :deny
        }),
        Directive.halt(self())
      ]

      for directive <- directives do
        Executor.execute(directive, context())
        assert_receive {:harness_directive, ^directive}
      end
    end

    test "an Editor directive reaches the pump with the draft" do
      directive = Directive.edit_draft(self(), "the draft")
      Executor.execute(directive, context())

      assert_receive {:harness_directive, %Editor{draft: "the draft"}}
    end

    test "execution emits the dispatch telemetry with kind + action metadata" do
      handler_id = "harness-directive-test-#{inspect(self())}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :harness, :directive, :dispatched],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_seen, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Executor.execute(Directive.interrupt(self(), "t-2"), context())

      assert_receive {:telemetry_seen, %{system_time: _},
                      %{kind: :lane, action: :interrupt, pump: pump}}

      assert pump == self()

      Executor.execute(Directive.edit_draft(self(), "d"), context())

      assert_receive {:telemetry_seen, %{system_time: _},
                      %{kind: :editor, action: :editor_bracket}}
    end

    test "the executor sends to the STRUCT's pump, not the context pid" do
      other = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(other, :kill) end)

      directive = Directive.submit(other, "elsewhere")

      Executor.execute(directive, %{
        pid: self(),
        runtime_pid: self()
      })

      # Nothing lands here: addressing is struct-carried (Lane moduledoc
      # "Addressing"), so the same app code runs under any pump.
      refute_receive {:harness_directive, _}, 50
    end
  end
end
