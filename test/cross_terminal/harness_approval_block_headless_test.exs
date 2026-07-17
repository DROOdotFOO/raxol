defmodule Raxol.CrossTerminal.HarnessApprovalBlockHeadlessTest do
  @moduledoc """
  End-to-end coverage for `Raxol.Playground.Demos.HarnessApprovalBlockDemo`:
  boots the real transcript approval-block demo headless and drives the
  harness answer vocabulary through the real render pipeline.

  Pins (spec `harness-tea-migration.md` §7, the approval unit):

    * the LIVE approval renders its REFERENT (exact tool + args) and the
      answer AFFORDANCE line built from the request's real options;
    * a proposed edit/write approval renders the Pierre DIFF, not truncated
      args;
    * answering via `send_key` (`y`/digits) transitions the block
      `:live -> :sealed` and shows the decision RECEIPT;
    * the sealed history renders allow / deny / canceled receipts;
    * the referent actually reaches the terminal buffer (cell-level).
  """
  use ExUnit.Case, async: false

  alias Raxol.Headless
  alias Raxol.Playground.Demos.HarnessApprovalBlockDemo

  setup do
    pid =
      case Process.whereis(Headless) do
        nil -> start_supervised!({Headless, [name: Headless]})
        existing -> existing
      end

    on_exit(fn ->
      if Process.alive?(pid) do
        for id <- GenServer.call(pid, :list_sessions) do
          try do
            GenServer.call(pid, {:stop_session, id}, 2_000)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    :ok
  end

  test "the live approval shows its referent and answer affordances" do
    {:ok, id} =
      Headless.start(HarnessApprovalBlockDemo, id: :approval_block_ref)

    {:ok, text} = Headless.screenshot(id)

    # referent: the exact tool + args the agent would run
    assert text =~ "tool: bash"
    assert text =~ "args: rm -rf /tmp/scratch"
    # affordance line from the REAL options (three of them)
    assert text =~ "answer:"
    assert text =~ "1-3 to choose"

    :ok = Headless.stop(id)
  end

  test "the sealed history renders allow / deny / canceled receipts" do
    {:ok, id} =
      Headless.start(HarnessApprovalBlockDemo, id: :approval_block_hist)

    {:ok, text} = Headless.screenshot(id)

    assert text =~ "✓ allowed"
    assert text =~ "✗ denied"
    assert text =~ "canceled before answer"

    :ok = Headless.stop(id)
  end

  test "y answers the live approval: it seals to an allow receipt" do
    {:ok, id} =
      Headless.start(HarnessApprovalBlockDemo, id: :approval_block_allow)

    {:ok, before} = Headless.screenshot(id)
    assert before =~ "answer:"

    :ok = Headless.send_key(id, "y")
    Process.sleep(50)

    {:ok, after_text} = Headless.screenshot(id)
    # the question is answered: no live affordance line remains, and the
    # freshly sealed block carries the operator's receipt
    assert after_text =~ "by you"
    refute after_text =~ "1-3 to choose"

    :ok = Headless.stop(id)
  end

  test "a digit answers by position: 3 picks Reject and seals to a deny receipt" do
    {:ok, id} =
      Headless.start(HarnessApprovalBlockDemo, id: :approval_block_deny)

    :ok = Headless.send_key(id, "3")
    Process.sleep(50)

    {:ok, text} = Headless.screenshot(id)
    assert text =~ "✗ denied"
    assert text =~ "by you"

    :ok = Headless.stop(id)
  end

  test "e opens an edit/write request: the proposed DIFF renders, not truncated args" do
    {:ok, id} =
      Headless.start(HarnessApprovalBlockDemo, id: :approval_block_edit)

    :ok = Headless.send_key(id, "e")
    Process.sleep(50)

    {:ok, text} = Headless.screenshot(id)
    # the diff path renders the PROPOSED DIFF (± path header + the changed
    # source through the Pierre engine), not a truncated `args:` line
    assert text =~ "lib/checkout/cart.ex"
    assert text =~ "def total"
    assert text =~ "Enum.reject"
    refute text =~ "args: %{"

    :ok = Headless.stop(id)
  end

  test "the referent reaches the terminal buffer (cell-level)" do
    {:ok, id} =
      Headless.start(HarnessApprovalBlockDemo, id: :approval_block_buffer)

    {:ok, buffer} = Headless.get_buffer(id)

    row_text = fn row ->
      buffer.cells |> Enum.at(row) |> Enum.map_join("", & &1.char)
    end

    all_rows = Enum.map_join(0..(length(buffer.cells) - 1), "\n", row_text)
    assert all_rows =~ "tool: bash"

    :ok = Headless.stop(id)
  end
end
