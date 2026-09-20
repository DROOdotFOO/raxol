defmodule Raxol.REPL.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Raxol.REPL.Evaluator
  alias Raxol.REPL.CaptureIO

  describe "new/0" do
    test "creates evaluator with empty state" do
      eval = Evaluator.new()
      assert Evaluator.bindings(eval) == []
      assert Evaluator.history(eval) == []
    end
  end

  describe "eval/3" do
    test "evaluates simple expression" do
      eval = Evaluator.new()
      assert {:ok, result, _eval} = Evaluator.eval(eval, "1 + 2")
      assert result.value == 3
      assert result.formatted == "3"
    end

    test "persists bindings across calls" do
      eval = Evaluator.new()
      {:ok, _result, eval} = Evaluator.eval(eval, "x = 42")
      {:ok, result, _eval} = Evaluator.eval(eval, "x * 2")
      assert result.value == 84
    end

    test "captures IO output" do
      eval = Evaluator.new()
      {:ok, result, _eval} = Evaluator.eval(eval, ~S[IO.puts("hello")])
      assert result.output == "hello\n"
    end

    test "returns error for invalid syntax" do
      eval = Evaluator.new()
      {:error, reason, _eval} = Evaluator.eval(eval, "def +++ end")
      assert is_binary(reason)
    end

    test "returns error for runtime exceptions" do
      eval = Evaluator.new()
      {:error, reason, _eval} = Evaluator.eval(eval, "raise \"boom\"")
      assert reason =~ "boom"
    end

    test "times out on long-running code" do
      eval = Evaluator.new()

      {:error, reason, _eval} =
        Evaluator.eval(eval, ":timer.sleep(10_000)", timeout: 100)

      assert reason =~ "timed out"
    end

    test "an evaluation that traps exits still dies at its timeout" do
      # The timeout used to signal `:brutal_kill`, which is an ordinary
      # trappable reason: `Process.flag(:trap_exit, true)` turned it into a
      # message, and the evaluation kept running with full node authority after
      # `eval/3` had already reported the timeout and demonitored it. `:kill`
      # is the only reason the VM delivers untrappably.
      #
      # The evaluation reports its own pid through a registered name because
      # `eval/3` does not return it: what is asserted is that THAT process is
      # gone, not merely that the caller stopped waiting for it.
      Process.register(self(), :repl_trapped_eval_probe)

      code = """
      Process.flag(:trap_exit, true)
      send(:repl_trapped_eval_probe, {:eval_pid, self()})
      Process.sleep(:infinity)
      """

      assert {:error, reason, _eval} =
               Evaluator.eval(Evaluator.new(), code, timeout: 100)

      assert reason =~ "timed out"

      assert_received {:eval_pid, eval_pid}

      # Fires immediately with `:noproc` if it is already dead, and on the kill
      # otherwise -- so this waits for the death rather than timing it.
      ref = Process.monitor(eval_pid)
      assert_receive {:DOWN, ^ref, :process, ^eval_pid, _reason}, 2_000
    end

    test "kills evaluation that exceeds its heap budget" do
      eval = Evaluator.new()

      assert {:error, reason, ^eval} =
               Evaluator.eval(eval, "List.duplicate(0, 1_000_000)",
                 max_heap_bytes: 128_000
               )

      assert reason =~ "memory limit"
    end

    test "rejects oversized results before copying them to the owner" do
      eval = Evaluator.new()

      assert {:error, reason, ^eval} =
               Evaluator.eval(eval, "String.duplicate(\"x\", 10_000)",
                 max_result_bytes: 1_000
               )

      assert reason =~ "result limit"
    end

    test "preserves evaluator on error" do
      eval = Evaluator.new()
      {:ok, _result, eval} = Evaluator.eval(eval, "x = 10")
      {:error, _reason, eval} = Evaluator.eval(eval, "raise \"fail\"")
      assert Keyword.get(Evaluator.bindings(eval), :x) == 10
    end

    test "records history" do
      eval = Evaluator.new()
      {:ok, _result, eval} = Evaluator.eval(eval, "1 + 1")
      {:ok, _result, eval} = Evaluator.eval(eval, "2 + 2")
      history = Evaluator.history(eval)
      assert length(history) == 2
      assert {"2 + 2", _} = hd(history)
    end

    test "evaluates pattern matching" do
      eval = Evaluator.new()
      {:ok, _result, eval} = Evaluator.eval(eval, "{a, b} = {1, 2}")
      {:ok, result, _eval} = Evaluator.eval(eval, "a + b")
      assert result.value == 3
    end

    test "evaluates pipe chains" do
      eval = Evaluator.new()

      {:ok, result, _eval} =
        Evaluator.eval(eval, "[1,2,3] |> Enum.map(& &1 * 2) |> Enum.sum()")

      assert result.value == 12
    end

    test "handles multi-line code" do
      eval = Evaluator.new()

      code = """
      list = [1, 2, 3, 4, 5]
      Enum.filter(list, &(rem(&1, 2) == 0))
      """

      {:ok, result, _eval} = Evaluator.eval(eval, code)
      assert result.value == [2, 4]
    end
  end

  describe "reset_bindings/1" do
    test "clears bindings but keeps history" do
      eval = Evaluator.new()
      {:ok, _result, eval} = Evaluator.eval(eval, "x = 1")
      eval = Evaluator.reset_bindings(eval)
      assert Evaluator.bindings(eval) == []
      assert length(Evaluator.history(eval)) == 1
    end
  end

  describe "clear_history/1" do
    test "clears history but keeps bindings" do
      eval = Evaluator.new()
      {:ok, _result, eval} = Evaluator.eval(eval, "x = 1")
      eval = Evaluator.clear_history(eval)
      assert Evaluator.history(eval) == []
      assert Keyword.get(Evaluator.bindings(eval), :x) == 1
    end
  end

  describe "limits the heap cap alone does not cover" do
    test "captured output stops accumulating at the limit" do
      # Output goes to a SEPARATE process, so it never counted against the
      # evaluation's own max_heap_size: this loop allocates almost nothing
      # locally while growing that process without bound. Nor could the caller
      # measure it -- output arrives as refc binaries, which live off-heap and
      # are invisible to process_info(:memory). So the cap is enforced where
      # the bytes are accepted.
      eval = Evaluator.new()
      limit = 100_000

      assert {:ok, result, _eval} =
               Evaluator.eval(
                 eval,
                 ~s|Enum.each(1..50_000, fn _ -> IO.puts(String.duplicate("x", 1024)) end)|,
                 max_result_bytes: limit,
                 timeout: 30_000
               )

      # 50MB was written; what is kept is bounded, and says it was cut.
      assert byte_size(result.output) < limit + 100
      assert result.output =~ "output truncated"
    end

    test "output under the limit is captured whole, unannotated" do
      eval = Evaluator.new()

      assert {:ok, result, _eval} =
               Evaluator.eval(eval, ~s|IO.puts("hello"); IO.puts("world")|)

      assert result.output == "hello\nworld\n"
      refute result.output =~ "truncated"
    end

    test "another evaluation's result is never consumed as this one's" do
      # The child's reply used to be untagged, and `demonitor(ref, [:flush])`
      # flushes only the :DOWN. So a reply that raced its timeout stayed in the
      # mailbox and the NEXT eval's receive matched it, attributing one
      # expression's value to another.
      #
      # The race itself is not reproducible on demand, so this asserts the
      # invariant that makes it impossible instead: a result this evaluation
      # did not mint is not eligible, whatever it looks like.
      send(self(), {:eval_result, {:ok, :stale_untagged, [], ""}})
      send(self(), {:eval_result, make_ref(), {:ok, :stale_tagged, [], ""}})

      eval = Evaluator.new()

      assert {:ok, result, _eval} = Evaluator.eval(eval, ":mine")
      assert result.value == :mine

      # Both plants are still queued: neither was mistaken for this result.
      assert_received {:eval_result, {:ok, :stale_untagged, [], ""}}
      assert_received {:eval_result, _, {:ok, :stale_tagged, [], ""}}
    end

    test "a killed evaluation leaves no capture server behind" do
      # Cleanup lives in an `after` block, which does NOT run when the process
      # is killed by `Process.exit(pid, :kill)` on timeout or by the VM
      # on a max_heap_size breach -- the two paths hostile input is designed to
      # take. `CaptureIO` is started unlinked, so each of those orphaned one
      # server holding up to the output limit, on an anonymous SSH surface.
      #
      # Counted rather than tracked by pid: the capture is private to the
      # evaluation, and what matters is that the count comes back, not which
      # process went.
      eval = Evaluator.new()
      before = capture_server_count()

      assert {:error, timed_out, _eval} =
               Evaluator.eval(eval, "Process.sleep(:infinity)", timeout: 100)

      assert timed_out =~ "timed out"

      assert {:error, over_heap, _eval} =
               Evaluator.eval(
                 eval,
                 "Enum.reduce(1..10_000_000, [], fn i, acc -> [i | acc] end)",
                 max_heap_bytes: 2 * 1024 * 1024,
                 timeout: 30_000
               )

      assert over_heap =~ "memory limit"

      # The servers stop asynchronously on the owner's :DOWN.
      Process.sleep(200)
      assert capture_server_count() == before
    end
  end

  defp capture_server_count do
    Enum.count(Process.list(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} ->
          Keyword.get(dict, :"$initial_call") ==
            {Raxol.REPL.CaptureIO, :init, 1}

        nil ->
          false
      end
    end)
  end

  # `:io.format/2` does not send the finished bytes -- it sends
  # `{put_chars, unicode, io_lib, format, [Format, Args]}` and asks the GROUP
  # LEADER to build them. `CaptureIO` applied that in its own process, which
  # has no `max_heap_size`, so the expansion escaped both the evaluation's heap
  # cap and the capture's byte cap: `~1000000000c` allocated a gigabyte before
  # anything counted it.
  describe "output built by the group leader is bounded too" do
    test "an expansion far over the cap is killed by a heap cap, not built" do
      # Proof is the VM's own `gc_max_heap_size` event, observed through the
      # evaluator's real wiring: `set_on_spawn` on this process propagates the
      # trace flag to the evaluation, its capture server, and whatever the
      # capture spawns to expand the format. A VM-wide `:erlang.memory/1`
      # delta cannot tell this apart from other async tests allocating at the
      # same time; a bare truncation note cannot tell "killed at the cap"
      # from "built 100 MB, then dropped".
      max_heap_bytes = 8 * 1024 * 1024
      :erlang.trace(self(), true, [:set_on_spawn, :garbage_collection])

      eval = Evaluator.new()

      assert {:ok, result, _eval} =
               Evaluator.eval(
                 eval,
                 ~S|:io.format("~100000000c", [?x]); :done|,
                 timeout: 15_000,
                 max_result_bytes: 4_096,
                 max_heap_bytes: max_heap_bytes
               )

      :erlang.trace(self(), false, [:all])

      # The evaluation itself survived, so the process the VM killed for its
      # heap cap is the one working on its behalf -- and that cap is the
      # small one CaptureIO sets from the byte limit, not the evaluation's.
      assert result.value == :done
      assert result.output =~ "[output truncated at 4096 bytes]"

      assert_received {:trace, expander, :gc_max_heap_size, info}
      assert expander != self()

      words_at_kill =
        Keyword.fetch!(info, :heap_block_size) +
          Keyword.fetch!(info, :old_heap_block_size) +
          Keyword.fetch!(info, :mbuf_size)

      assert words_at_kill * :erlang.system_info(:wordsize) < max_heap_bytes,
             "expansion reached #{words_at_kill} words before the cap fired"
    end

    test "output within the cap still arrives" do
      eval = Evaluator.new()

      assert {:ok, result, _eval} =
               Evaluator.eval(eval, ~S|:io.format("~s", ["hello"]); :ok|,
                 max_result_bytes: 4_096
               )

      assert result.output =~ "hello"
      assert result.value == :ok
    end

    # The monitor on the expansion process covers one that DIES. One that
    # neither answers nor dies left the capture server parked in a receive
    # with no `after` -- and since the wedge also swallowed the owner's
    # `:DOWN`, killing the evaluation on timeout did not reclaim it: one
    # capture server (holding up to the output limit) plus its expander
    # leaked per wedge, on a surface served anonymously over SSH.
    #
    # Driven through `CaptureIO` directly with the IO protocol, because no
    # Elixir expression makes `io_lib` hang: the wedge is a property of the
    # expander, and the request shape is what `:io.format/2` sends.
    # The `:DOWN` below is a scheduling event, so the window is a hang
    # detector rather than a deadline: `@tag timeout:` is what fails a real
    # wedge, and a loaded runner that takes two seconds to deliver a monitor
    # message is not the bug under test (it failed at the suite's 1s default
    # on macos-latest in run 35517528499).
    @tag timeout: 30_000
    test "an expander that never answers does not wedge the capture server" do
      before = capture_server_count()
      test_pid = self()

      owner =
        spawn(fn ->
          {:ok, capture} = CaptureIO.start(4_096, mfa_timeout: 50)
          send(test_pid, {:capture, capture})
          reply_as = make_ref()

          send(
            capture,
            {:io_request, self(), reply_as,
             {:put_chars, :unicode, __MODULE__, :never_answers, [:x]}}
          )

          receive do
            {:io_reply, ^reply_as, reply} -> send(test_pid, {:io_reply, reply})
          end

          # Stay alive so the server's exit can only come from the owner's
          # :DOWN below, never from this process ending early.
          receive do
            :done -> :ok
          end
        end)

      assert_receive {:capture, capture}

      # The write is answered rather than hanging, and it is refused: the
      # unexpanded text is not in the buffer, and the capture says so.
      assert_receive {:io_reply, :ok}
      assert CaptureIO.contents(capture) == {"", true}

      # And the server is still a server: it answers, and it still goes when
      # its owner does.
      ref = Process.monitor(capture)
      Process.exit(owner, :brutal_kill)
      assert_receive {:DOWN, ^ref, :process, ^capture, :normal}, 10_000
      assert capture_server_count() == before
    end

    # Bounding ONE wedge is not enough. Evaluated code can read the capture
    # server's pid (it is the group leader) and hand it to a process the
    # evaluator's kill never reaches, then queue as many wedging MFA writes
    # as it likes. At one `:mfa_timeout` each, N writes held the server --
    # and starved the owner's `:DOWN` behind them -- for N x the bound,
    # with N attacker-chosen. After the first wedge the capture is latched
    # truncated, so there is nothing left to record and nothing to wait for.
    test "a second wedged write costs nothing: the bound is per server, not per write" do
      {:ok, capture} = CaptureIO.start(4_096, mfa_timeout: 200)

      elapsed_for = fn ->
        reply_as = make_ref()

        send(
          capture,
          {:io_request, self(), reply_as,
           {:put_chars, :unicode, __MODULE__, :never_answers, [:x]}}
        )

        {us, :ok} =
          :timer.tc(fn ->
            receive do
              {:io_reply, ^reply_as, reply} -> reply
            end
          end)

        us
      end

      first = elapsed_for.()
      second = elapsed_for.()
      third = elapsed_for.()

      # The first write pays the bound (it is the one that discovers the
      # wedge); the two after it are refused without spawning an expander at
      # all, so they cannot each pay it again. Compared to the code's OWN
      # bound rather than to a wall-clock constant: the claim is "these did
      # not wait", and 200_000us is what waiting costs here.
      assert first >= 200_000
      assert second < 200_000
      assert third < 200_000

      assert CaptureIO.contents(capture) == {"", true}
      CaptureIO.close(capture)
    end

    # `:infinity` is a legitimate evaluation timeout, and the two halves of
    # this fix have to agree about it: `start/2` now REFUSES a non-integer
    # bound, so an evaluator that forwarded `:infinity` verbatim would fail
    # every evaluation outright. This pins that it resolves it instead.
    test "an infinite evaluation timeout still bounds the expansion" do
      eval = Evaluator.new()

      assert {:ok, result, _eval} =
               Evaluator.eval(eval, ~S|:io.format("~s", ["hi"]); :ok|,
                 timeout: :infinity,
                 max_result_bytes: 4_096
               )

      assert result.output =~ "hi"
    end

    test "a non-integer :mfa_timeout is refused rather than silently unbounded" do
      assert_raise ArgumentError,
                   ~r/:mfa_timeout must be a positive integer/,
                   fn ->
                     CaptureIO.start(4_096, mfa_timeout: :infinity)
                   end

      assert_raise ArgumentError, fn ->
        CaptureIO.start(4_096, mfa_timeout: 0)
      end
    end

    # Public because the capture applies it by module/function/arguments.
    def never_answers(_arg) do
      receive do
        :never -> :never
      end
    end
  end
end
