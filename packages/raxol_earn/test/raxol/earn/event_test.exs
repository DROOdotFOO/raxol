defmodule Raxol.Earn.EventTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.Event

  describe "decode_type/1" do
    test "round-trips every canonical type" do
      for str <- Event.all_types() do
        assert {:ok, atom} = Event.decode_type(str)
        assert Event.encode_type(atom) == str
      end
    end

    test "rejects unknown strings" do
      assert {:error, :unknown_event_type} = Event.decode_type("nope")
      assert {:error, :unknown_event_type} = Event.decode_type("")
    end
  end

  describe "terminal?/1" do
    test "completed, rejected, expired are terminal" do
      assert Event.terminal?(:job_completed)
      assert Event.terminal?(:job_rejected)
      assert Event.terminal?(:job_expired)
    end

    test "lifecycle events are not terminal" do
      refute Event.terminal?(:job_created)
      refute Event.terminal?(:budget_set)
      refute Event.terminal?(:job_funded)
      refute Event.terminal?(:job_submitted)
    end
  end

  describe "all_types/0" do
    test "returns the canonical 7 event types" do
      assert Event.all_types() == [
               "job.created",
               "budget.set",
               "job.funded",
               "job.submitted",
               "job.completed",
               "job.rejected",
               "job.expired"
             ]
    end
  end
end
