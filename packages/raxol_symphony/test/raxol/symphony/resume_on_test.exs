defmodule Raxol.Symphony.ResumeOnTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.ResumeOn

  doctest ResumeOn

  describe "acp_transition/2" do
    test "builds a resume_on map for the default ACP transition event" do
      assert %{
               telemetry: [:raxol, :acp, :job, :transition],
               match: %{job_id: "j-1", to: :transaction}
             } = ResumeOn.acp_transition("j-1", to: :transaction)
    end

    test "supports integer job ids (canonical ACP shape from on-chain)" do
      assert %{match: %{job_id: 42, to: :completed}} =
               ResumeOn.acp_transition(42, to: :completed)
    end

    test ":from constrains the source state too" do
      assert %{match: %{job_id: "j-2", from: :evaluation, to: :completed}} =
               ResumeOn.acp_transition("j-2", to: :completed, from: :evaluation)
    end

    test "raises when :to is missing" do
      assert_raise KeyError, fn -> ResumeOn.acp_transition("j-1", []) end
    end
  end

  describe "acp_pause/2" do
    test "returns a {:pause, reason, token} tuple with a nested resume_on" do
      assert {:pause, :awaiting_buyer_payment, token} =
               ResumeOn.acp_pause("j-1",
                 waiting_for: :transaction,
                 reason: :awaiting_buyer_payment
               )

      assert %{
               resume_on: %{
                 telemetry: [:raxol, :acp, :job, :transition],
                 match: %{job_id: "j-1", to: :transaction}
               }
             } = token
    end

    test ":meta is merged into the token alongside :resume_on" do
      {:pause, _reason, token} =
        ResumeOn.acp_pause("j-1",
          waiting_for: :evaluation,
          reason: :awaiting_delivery,
          meta: %{step: "post-payment", request_id: "req-7"}
        )

      assert token.step == "post-payment"
      assert token.request_id == "req-7"
      assert is_map(token.resume_on)
    end

    test ":from is threaded through to the inner match map" do
      {:pause, _, %{resume_on: resume_on}} =
        ResumeOn.acp_pause("j-3",
          waiting_for: :completed,
          reason: :awaiting_evaluator_approval,
          from: :evaluation
        )

      assert resume_on.match == %{job_id: "j-3", from: :evaluation, to: :completed}
    end

    test "raises when :waiting_for or :reason is missing" do
      assert_raise KeyError, fn ->
        ResumeOn.acp_pause("j-1", reason: :awaiting_buyer_payment)
      end

      assert_raise KeyError, fn ->
        ResumeOn.acp_pause("j-1", waiting_for: :transaction)
      end
    end
  end

  describe "composes with Raxol.Symphony.Resumer" do
    test "the produced resume_on matches the metadata shape the Resumer checks" do
      {:pause, _reason, token} =
        ResumeOn.acp_pause("j-1",
          waiting_for: :transaction,
          reason: :awaiting_buyer_payment
        )

      # Simulate the metadata an ACP Job.Server transition telemetry
      # would emit: it MUST be a superset of the match map for the
      # Resumer's subset check to fire resume_run/3.
      acp_event_metadata = %{
        job_id: "j-1",
        from: :negotiation,
        to: :transaction,
        memo_type: :txhash,
        next_phase: :transaction,
        tx_hash: "tx-1"
      }

      match = token.resume_on.match
      assert Enum.all?(match, fn {k, v} -> Map.get(acp_event_metadata, k) == v end)

      # Confirm a non-matching event (wrong job_id) does NOT match.
      assert match.job_id == "j-1"
      refute match.job_id == "j-2"
    end
  end
end
