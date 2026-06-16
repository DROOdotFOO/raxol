defmodule Raxol.ACP.Job.WorkflowTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.ContractClient.InMemory
  alias Raxol.ACP.Job.Workflow, as: JobWorkflow
  alias Raxol.Workflow.Checkpoint.Saver.Ets
  alias Raxol.Workflow.Compiled

  @provider "0x" <> String.duplicate("ab", 20)
  @evaluator "0x" <> String.duplicate("cd", 20)
  @expired_at 9_999_999_999

  setup do
    InMemory.reset()
    :ok
  end

  defp ets_saver do
    table = :"acp_job_wf_#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
    {Ets, %{table: table}}
  end

  defp new_job do
    {:ok, job_id} = ContractClient.create_job(@provider, @evaluator, @expired_at)
    job_id
  end

  defp compiled(opts \\ []) do
    {:ok, compiled} = JobWorkflow.compile(opts)
    compiled
  end

  describe "compile/1" do
    test "produces a Compiled graph with the canonical node set" do
      compiled = compiled()
      node_ids = Map.keys(compiled.nodes) |> Enum.sort()

      assert node_ids == [
               :memo_completed,
               :memo_evaluation,
               :memo_expired,
               :memo_negotiation,
               :memo_rejected,
               :memo_transaction,
               :wait_evaluation,
               :wait_negotiation,
               :wait_request,
               :wait_transaction
             ]
    end

    test "configures the retry policy from defaults" do
      compiled = compiled()
      assert compiled.opts.failure_policy == :retry
      assert compiled.opts.max_attempts == 3
      assert compiled.opts.retry_backoff_ms == 200
    end

    test "max_attempts and retry_backoff_ms can be overridden" do
      compiled = compiled(max_attempts: 5, retry_backoff_ms: 50)
      assert compiled.opts.max_attempts == 5
      assert compiled.opts.retry_backoff_ms == 50
    end

    test "saver is omitted by default and threaded through when provided" do
      assert compiled().opts |> Map.has_key?(:saver) == false

      saver = ets_saver()
      assert compiled(saver: saver).opts.saver == saver
    end
  end

  describe "initial_state/1" do
    test "returns the expected map shape for a fresh job" do
      job_id = new_job()
      state = JobWorkflow.initial_state(job_id)

      assert state.job_id == job_id
      assert state.memos == []
      assert state.current_state == :request
      assert state.next_state == nil
      assert state.pending_event == nil
      assert state.pending_payload == nil
      assert state.pending_signature == nil
    end
  end

  describe "happy path: request -> completed" do
    test "each transition writes one memo and the run ends at :completed" do
      compiled = compiled(saver: ets_saver())
      job_id = new_job()
      state = JobWorkflow.initial_state(job_id)

      # 1) Initial invoke pauses at wait_request
      {:interrupted, run_id, _, :awaiting_request_response} =
        Compiled.invoke(compiled, state)

      assert is_binary(run_id)

      # 2) Buyer accepts the request -> memo_negotiation writes, pauses at wait_negotiation
      {:interrupted, ^run_id, after_neg, :awaiting_payment} =
        Compiled.resume(compiled, run_id, {:accept_request, %{step: 1}, nil})

      assert after_neg.current_state == :negotiation
      assert [m1] = after_neg.memos
      assert m1.next_phase == :negotiation
      assert m1.memo_type == :message

      # 3) Payment accepted -> memo_transaction
      {:interrupted, ^run_id, after_tx, :awaiting_delivery} =
        Compiled.resume(compiled, run_id, {:accept_payment, %{tx: "0xabc"}, "sig"})

      assert after_tx.current_state == :transaction
      assert length(after_tx.memos) == 2
      [_, m2] = after_tx.memos
      assert m2.memo_type == :txhash
      assert m2.signature == "sig"

      # 4) Delivery -> memo_evaluation
      {:interrupted, ^run_id, after_eval, :awaiting_approval} =
        Compiled.resume(compiled, run_id, {:deliver, %{url: "ipfs://x"}, nil})

      assert after_eval.current_state == :evaluation
      assert length(after_eval.memos) == 3

      # 5) Approval -> memo_completed -> __end__
      {:ok, final, meta} =
        Compiled.resume(compiled, run_id, {:approve, %{score: 5}, nil})

      assert final.current_state == :completed
      assert length(final.memos) == 4

      assert Enum.map(final.memos, & &1.next_phase) ==
               [:negotiation, :transaction, :evaluation, :completed]

      assert meta.run_id == run_id
    end
  end

  describe "rejection and expiration" do
    test "reject from :request lands at memo_rejected and ends the run" do
      compiled = compiled(saver: ets_saver())
      job_id = new_job()

      {:interrupted, run_id, _, _} =
        Compiled.invoke(compiled, JobWorkflow.initial_state(job_id))

      {:ok, final, _meta} =
        Compiled.resume(compiled, run_id, {:reject, %{reason: "no inventory"}, nil})

      assert final.current_state == :rejected
      assert [memo] = final.memos
      assert memo.next_phase == :rejected
    end

    test "expire from :request ends the run with a :memo_expired" do
      compiled = compiled(saver: ets_saver())
      job_id = new_job()

      {:interrupted, run_id, _, _} =
        Compiled.invoke(compiled, JobWorkflow.initial_state(job_id))

      {:ok, final, _meta} =
        Compiled.resume(compiled, run_id, {:expire, %{reason: "sla"}, nil})

      assert final.current_state == :expired
      assert [memo] = final.memos
      assert memo.next_phase == :expired
    end

    test "expire from :negotiation also ends with :memo_expired" do
      compiled = compiled(saver: ets_saver())
      job_id = new_job()

      {:interrupted, run_id, _, _} =
        Compiled.invoke(compiled, JobWorkflow.initial_state(job_id))

      {:interrupted, ^run_id, _, _} =
        Compiled.resume(compiled, run_id, {:accept_request, %{}, nil})

      {:ok, final, _} =
        Compiled.resume(compiled, run_id, {:expire, %{}, nil})

      assert final.current_state == :expired
      assert length(final.memos) == 2
      assert Enum.map(final.memos, & &1.next_phase) == [:negotiation, :expired]
    end

    test "expire from :transaction" do
      compiled = compiled(saver: ets_saver())
      job_id = new_job()

      {:interrupted, run_id, _, _} =
        Compiled.invoke(compiled, JobWorkflow.initial_state(job_id))

      Compiled.resume(compiled, run_id, {:accept_request, %{}, nil})
      Compiled.resume(compiled, run_id, {:accept_payment, %{}, nil})

      {:ok, final, _} = Compiled.resume(compiled, run_id, {:expire, %{}, nil})
      assert final.current_state == :expired
      assert length(final.memos) == 3
    end

    test "expire from :evaluation" do
      compiled = compiled(saver: ets_saver())
      job_id = new_job()

      {:interrupted, run_id, _, _} =
        Compiled.invoke(compiled, JobWorkflow.initial_state(job_id))

      Compiled.resume(compiled, run_id, {:accept_request, %{}, nil})
      Compiled.resume(compiled, run_id, {:accept_payment, %{}, nil})
      Compiled.resume(compiled, run_id, {:deliver, %{}, nil})

      {:ok, final, _} = Compiled.resume(compiled, run_id, {:expire, %{}, nil})
      assert final.current_state == :expired
      assert length(final.memos) == 4
    end
  end

  describe "invalid events route to :memo_expired" do
    # Wait nodes never return :error (would conflict with the retry
    # policy on a node whose scratchpad value has been consumed).
    # Unknown events route through the conditional edge's fallback
    # to :memo_expired, ending the run cleanly. The Job.Server facade
    # in Phase A PR 2 will validate events up front via
    # Raxol.ACP.Job.StateMachine.next/2 so unknown events never reach
    # the workflow.

    test "an event not valid for the current phase routes to :memo_expired" do
      compiled = compiled(saver: ets_saver())
      job_id = new_job()

      {:interrupted, run_id, _, _} =
        Compiled.invoke(compiled, JobWorkflow.initial_state(job_id))

      # :deliver is not a valid event for :request; the run expires.
      {:ok, final, _} =
        Compiled.resume(compiled, run_id, {:deliver, %{}, nil})

      assert final.current_state == :expired
      assert [memo] = final.memos
      assert memo.next_phase == :expired
    end

    test "a non-tuple resume value also routes to :memo_expired" do
      compiled = compiled(saver: ets_saver())
      job_id = new_job()

      {:interrupted, run_id, _, _} =
        Compiled.invoke(compiled, JobWorkflow.initial_state(job_id))

      {:ok, final, _} = Compiled.resume(compiled, run_id, :not_a_tuple)
      assert final.current_state == :expired
    end
  end

  describe "memo content encoding" do
    test "string payloads pass through unchanged" do
      compiled = compiled(saver: ets_saver())
      job_id = new_job()

      {:interrupted, run_id, _, _} =
        Compiled.invoke(compiled, JobWorkflow.initial_state(job_id))

      {:interrupted, _, after_neg, _} =
        Compiled.resume(compiled, run_id, {:accept_request, "raw text", nil})

      [memo] = after_neg.memos
      assert memo.content == "raw text"
      # binary payloads do not appear in the memo's payload field
      assert memo.payload == nil
    end

    test "map payloads are JSON-encoded for content and preserved verbatim in payload" do
      compiled = compiled(saver: ets_saver())
      job_id = new_job()

      {:interrupted, run_id, _, _} =
        Compiled.invoke(compiled, JobWorkflow.initial_state(job_id))

      payload = %{foo: "bar"}

      {:interrupted, _, after_neg, _} =
        Compiled.resume(compiled, run_id, {:accept_request, payload, nil})

      [memo] = after_neg.memos
      assert memo.content == ~s({"foo":"bar"})
      assert memo.payload == payload
    end

    test "nil payload encodes as empty string" do
      compiled = compiled(saver: ets_saver())
      job_id = new_job()

      {:interrupted, run_id, _, _} =
        Compiled.invoke(compiled, JobWorkflow.initial_state(job_id))

      {:interrupted, _, after_neg, _} =
        Compiled.resume(compiled, run_id, {:accept_request, nil, nil})

      [memo] = after_neg.memos
      assert memo.content == ""
    end

    test ":accept_payment uses memo_type :txhash" do
      compiled = compiled(saver: ets_saver())
      job_id = new_job()

      {:interrupted, run_id, _, _} =
        Compiled.invoke(compiled, JobWorkflow.initial_state(job_id))

      Compiled.resume(compiled, run_id, {:accept_request, %{}, nil})

      {:interrupted, _, after_tx, _} =
        Compiled.resume(compiled, run_id, {:accept_payment, %{}, "sig"})

      [_, memo] = after_tx.memos
      assert memo.memo_type == :txhash
    end
  end

  describe "checkpoints" do
    test "saver records a checkpoint after every successful memo write" do
      table = :"acp_job_wf_ckpt_#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
      saver_config = %{table: table}
      saver = {Ets, saver_config}

      compiled = compiled(saver: saver)
      job_id = new_job()

      {:interrupted, run_id, _, _} =
        Compiled.invoke(compiled, JobWorkflow.initial_state(job_id))

      Compiled.resume(compiled, run_id, {:accept_request, %{}, nil})
      Compiled.resume(compiled, run_id, {:accept_payment, %{}, nil})

      {:ok, checkpoints} = Ets.list(saver_config, run_id, 50)

      node_ids =
        checkpoints
        |> Enum.map(& &1.metadata.node_id)
        |> Enum.uniq()
        |> Enum.sort()

      assert :__start__ in node_ids
      assert :memo_negotiation in node_ids
      assert :memo_transaction in node_ids
    end

    test "resume picks up after the last memo write across separate compile invocations" do
      table = :"acp_job_wf_resume_#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
      saver = {Ets, %{table: table}}

      job_id = new_job()

      # First "process": drive partway, then drop the compiled handle.
      compiled1 = compiled(saver: saver)

      {:interrupted, run_id, _, _} =
        Compiled.invoke(compiled1, JobWorkflow.initial_state(job_id))

      Compiled.resume(compiled1, run_id, {:accept_request, %{step: 1}, nil})
      Compiled.resume(compiled1, run_id, {:accept_payment, %{step: 2}, nil})

      # Second "process": fresh compile against the same saver table.
      compiled2 = compiled(saver: saver)

      Compiled.resume(compiled2, run_id, {:deliver, %{step: 3}, nil})

      {:ok, final, _} =
        Compiled.resume(compiled2, run_id, {:approve, %{step: 4}, nil})

      assert final.current_state == :completed
      assert length(final.memos) == 4
    end
  end
end
