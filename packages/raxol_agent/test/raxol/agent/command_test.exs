defmodule Raxol.Agent.CommandTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Command
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.Records.Checkpoint

  describe "decode/1 — loud typed rejects" do
    test "malformed JSON string is a typed error, no crash" do
      assert {:error, {:invalid_command, {:malformed_json, _}}} =
               Command.decode("{not json")
    end

    test "valid JSON that isn't an object is rejected" do
      assert {:error, {:invalid_command, :not_a_map}} =
               Command.decode("[1, 2, 3]")

      assert {:error, {:invalid_command, :not_a_map}} =
               Command.decode(~s("just a string"))
    end

    test "a non-map, non-binary term is rejected" do
      assert {:error, {:invalid_command, :not_a_command}} = Command.decode(42)
      assert {:error, {:invalid_command, :not_a_command}} = Command.decode(nil)
    end

    test "missing type is rejected" do
      assert {:error, {:invalid_command, :missing_type}} =
               Command.decode(%{"payload" => %{"text" => "hi"}})
    end

    test "unknown type is rejected" do
      assert {:error, {:invalid_command, {:unknown_type, "explode"}}} =
               Command.decode(%{"type" => "explode"})
    end

    test "prompt with missing text is rejected" do
      assert {:error, {:invalid_command, :missing_text}} =
               Command.decode(%{"type" => "prompt", "payload" => %{}})

      assert {:error, {:invalid_command, :missing_text}} =
               Command.decode(~s({"type":"prompt"}))
    end

    test "prompt with empty/whitespace text is rejected" do
      assert {:error, {:invalid_command, :empty_text}} =
               Command.decode(%{
                 "type" => "prompt",
                 "payload" => %{"text" => "   "}
               })
    end

    test "prompt with non-binary text is rejected" do
      assert {:error, {:invalid_command, :invalid_text}} =
               Command.decode(%{
                 "type" => "prompt",
                 "payload" => %{"text" => 123}
               })
    end

    test "decode never raises on arbitrary bad input" do
      for bad <- ["", "{", "null", "true", %{}, %{"type" => 1}, [], {:a, :b}] do
        assert {:error, {:invalid_command, _}} = Command.decode(bad)
      end
    end
  end

  describe "decode/1 — prompt" do
    test "valid prompt JSON decodes to a typed struct" do
      assert {:ok, %Command{type: :prompt, payload: %{text: "hello world"}}} =
               Command.decode(~s({"type":"prompt","payload":{"text":"hello world"}}))
    end

    test "accepts a plain map with atom keys" do
      assert {:ok, %Command{type: :prompt, payload: %{text: "hi"}}} =
               Command.decode(%{type: :prompt, payload: %{text: "hi"}})
    end

    test "carries optional attachments" do
      assert {:ok, %Command{type: :prompt, payload: payload}} =
               Command.decode(%{
                 "type" => "prompt",
                 "payload" => %{"text" => "hi", "attachments" => ["a.txt"]}
               })

      assert payload == %{text: "hi", attachments: ["a.txt"]}
    end
  end

  describe "decode/1 — interrupt" do
    test "interrupt with empty payload decodes" do
      assert {:ok, %Command{type: :interrupt, payload: %{}}} =
               Command.decode(~s({"type":"interrupt","payload":{}}))
    end

    test "interrupt without a payload key decodes" do
      assert {:ok, %Command{type: :interrupt, payload: %{}}} =
               Command.decode(%{"type" => "interrupt"})
    end

    test "interrupt carries an optional turn_id" do
      assert {:ok, %Command{type: :interrupt, payload: %{turn_id: "turn-7"}}} =
               Command.decode(%{
                 "type" => "interrupt",
                 "payload" => %{"turn_id" => "turn-7"}
               })
    end
  end

  describe "decode/1 — steer" do
    test "valid steer JSON decodes to a typed struct" do
      assert {:ok,
              %Command{
                type: :steer,
                payload: %{text: "go left instead", expected_turn_id: "turn-1"}
              }} =
               Command.decode(
                 ~s({"type":"steer","payload":{"text":"go left instead","expected_turn_id":"turn-1"}})
               )
    end

    test "accepts a plain map with atom keys" do
      assert {:ok,
              %Command{
                type: :steer,
                payload: %{text: "hi", expected_turn_id: "turn-9"}
              }} =
               Command.decode(%{
                 type: :steer,
                 payload: %{text: "hi", expected_turn_id: "turn-9"}
               })
    end

    test "missing text is rejected" do
      assert {:error, {:invalid_command, :missing_text}} =
               Command.decode(%{
                 "type" => "steer",
                 "payload" => %{"expected_turn_id" => "turn-1"}
               })
    end

    test "empty/whitespace text is rejected" do
      assert {:error, {:invalid_command, :empty_text}} =
               Command.decode(%{
                 "type" => "steer",
                 "payload" => %{"text" => "   ", "expected_turn_id" => "turn-1"}
               })
    end

    test "non-binary text is rejected" do
      assert {:error, {:invalid_command, :invalid_text}} =
               Command.decode(%{
                 "type" => "steer",
                 "payload" => %{"text" => 123, "expected_turn_id" => "turn-1"}
               })
    end

    test "missing expected_turn_id is rejected" do
      assert {:error, {:invalid_command, :missing_expected_turn_id}} =
               Command.decode(%{
                 "type" => "steer",
                 "payload" => %{"text" => "hi"}
               })
    end

    test "an explicit nil expected_turn_id is rejected the same as missing" do
      assert {:error, {:invalid_command, :missing_expected_turn_id}} =
               Command.decode(%{
                 "type" => "steer",
                 "payload" => %{"text" => "hi", "expected_turn_id" => nil}
               })
    end

    test "carries an optional client_msg_id when present" do
      assert {:ok, %Command{type: :steer, payload: payload}} =
               Command.decode(%{
                 "type" => "steer",
                 "payload" => %{
                   "text" => "hi",
                   "expected_turn_id" => "turn-1",
                   "client_msg_id" => "msg-42"
                 }
               })

      assert payload == %{
               text: "hi",
               expected_turn_id: "turn-1",
               client_msg_id: "msg-42"
             }
    end

    test "omits client_msg_id from the payload when absent" do
      assert {:ok, %Command{type: :steer, payload: payload}} =
               Command.decode(%{
                 "type" => "steer",
                 "payload" => %{"text" => "hi", "expected_turn_id" => "turn-1"}
               })

      refute Map.has_key?(payload, :client_msg_id)
    end
  end

  describe "decode/1 — attach / seek (decode fully)" do
    test "attach decodes to a valid struct with defaulted history_policy" do
      assert {:ok,
              %Command{
                type: :attach,
                payload: %{from_offset: 12, history_policy: :replay}
              }} =
               Command.decode(%{
                 "type" => "attach",
                 "payload" => %{"from_offset" => 12}
               })
    end

    test "attach validates history_policy against the whitelist" do
      assert {:ok, %Command{payload: %{history_policy: :live}}} =
               Command.decode(%{
                 "type" => "attach",
                 "payload" => %{"from_offset" => 0, "history_policy" => "live"}
               })

      assert {:error, {:invalid_command, {:unknown_history_policy, "teleport"}}} =
               Command.decode(%{
                 "type" => "attach",
                 "payload" => %{
                   "from_offset" => 0,
                   "history_policy" => "teleport"
                 }
               })
    end

    test "attach with a missing/invalid offset is rejected" do
      assert {:error, {:invalid_command, {:missing_offset, :from_offset}}} =
               Command.decode(%{"type" => "attach", "payload" => %{}})

      assert {:error, {:invalid_command, {:invalid_offset, :from_offset}}} =
               Command.decode(%{
                 "type" => "attach",
                 "payload" => %{"from_offset" => -1}
               })
    end

    test "seek decodes to a valid struct" do
      assert {:ok, %Command{type: :seek, payload: %{offset: 99}}} =
               Command.decode(%{
                 "type" => "seek",
                 "payload" => %{"offset" => 99}
               })
    end

    test "seek with a missing offset is rejected" do
      assert {:error, {:invalid_command, {:missing_offset, :offset}}} =
               Command.decode(%{"type" => "seek", "payload" => %{}})
    end
  end

  describe "route/2" do
    test "prompt returns the documented start-turn action" do
      {:ok, cmd} =
        Command.decode(%{"type" => "prompt", "payload" => %{"text" => "go"}})

      assert {:start_turn, "sess-1", %{text: "go"}} =
               Command.route(cmd, %{session_id: "sess-1"})
    end

    test "prompt dispatches the action to a live session pid" do
      {:ok, cmd} =
        Command.decode(%{"type" => "prompt", "payload" => %{"text" => "go"}})

      action = Command.route(cmd, %{session_id: "sess-1", pid: self()})

      assert action == {:start_turn, "sess-1", %{text: "go"}}
      assert_receive {:harness_command, {:start_turn, "sess-1", %{text: "go"}}}
    end

    test "prompt accepts a bare session_id binary" do
      {:ok, cmd} =
        Command.decode(%{"type" => "prompt", "payload" => %{"text" => "go"}})

      assert {:start_turn, "bare-id", %{text: "go"}} =
               Command.route(cmd, "bare-id")
    end

    test "interrupt routes to its supervised-kill seam" do
      {:ok, cmd} =
        Command.decode(%{
          "type" => "interrupt",
          "payload" => %{"turn_id" => "turn-3"}
        })

      action = Command.route(cmd, %{session_id: "sess-1", pid: self()})

      assert action == {:interrupt, "sess-1", %{turn_id: "turn-3"}}

      assert_receive {:harness_command, {:interrupt, "sess-1", %{turn_id: "turn-3"}}}
    end

    test "steer routes to the session as {:harness_command, {:steer, ...}}" do
      {:ok, cmd} =
        Command.decode(%{
          "type" => "steer",
          "payload" => %{
            "text" => "go left instead",
            "expected_turn_id" => "turn-1"
          }
        })

      action = Command.route(cmd, %{session_id: "sess-1", pid: self()})

      assert action ==
               {:steer, "sess-1", %{text: "go left instead", expected_turn_id: "turn-1"}}

      assert_receive {:harness_command,
                      {:steer, "sess-1", %{text: "go left instead", expected_turn_id: "turn-1"}}}
    end

    test "attach (:replay) subscribes the session pid and replays durable records from the offset" do
      session_id = "cmd-attach-#{System.unique_integer([:positive])}"
      {:ok, j} = FileStore.open(session_id)

      {:ok, 1} = FileStore.append(j, loop_event("turn_started"))
      {:ok, 2} = FileStore.append(j, loop_event("turn_completed"))

      {:ok, cmd} =
        Command.decode(%{"type" => "attach", "payload" => %{"from_offset" => 1}})

      # :replay is the default policy; :attach performs the reattach directly
      # and does NOT dispatch a {:harness_command, _} action.
      assert {:ok, %{history: []}} =
               Command.route(cmd, %{session_id: session_id, pid: self()})

      refute_receive {:harness_command, _}
      assert_receive {:reattach_live, ^session_id, %{"id" => 1}}, 500
      assert_receive {:reattach_live, ^session_id, %{"id" => 2}}, 500

      FileStore.close(j)
    end

    test "attach (:live) streams only records above the decision-time watermark" do
      session_id = "cmd-live-#{System.unique_integer([:positive])}"
      {:ok, j} = FileStore.open(session_id)
      {:ok, 1} = FileStore.append(j, loop_event("turn_started"))

      # from_offset in the payload is ignored for :live — the watermark (1) is.
      {:ok, cmd} =
        Command.decode(%{
          "type" => "attach",
          "payload" => %{"from_offset" => 0, "history_policy" => "live"}
        })

      assert {:ok, %{history: []}} =
               Command.route(cmd, %{session_id: session_id, pid: self()})

      # The existing record (id 1, at/below the watermark) is NOT streamed.
      refute_receive {:reattach_live, ^session_id, %{"id" => 1}}, 100

      {:ok, 2} = FileStore.append(j, loop_event("turn_completed"))
      assert_receive {:reattach_live, ^session_id, %{"id" => 2}}, 500

      FileStore.close(j)
    end

    test "attach (:snapshot) restores a snapshot-backed model and tails from the record horizon" do
      session_id = "cmd-snap-ref-#{System.unique_integer([:positive])}"
      {:ok, j} = FileStore.open(session_id)
      {:ok, 1} = FileStore.append(j, loop_event("turn_started"))
      {:ok, 2} = FileStore.append(j, loop_event("turn_completed"))

      # A snapshot-backed checkpoint at the turn boundary (tip = 2).
      {:ok, 3} = Checkpoint.write(j, %{"applied" => [1, 2]}, reason: "manual")

      # Conversational tail after the checkpoint (T = 5, the record horizon).
      {:ok, 4} = FileStore.append(j, loop_event("turn_started", "t2"))
      {:ok, 5} = FileStore.append(j, loop_event("turn_completed", "t2"))

      {:ok, cmd} =
        Command.decode(%{
          "type" => "attach",
          "payload" => %{"from_offset" => 0, "history_policy" => "snapshot"}
        })

      assert {:ok, %{snapshot: model, from_offset: 6, history: [], live: live}} =
               Command.route(cmd, %{session_id: session_id, pid: self()})

      assert is_pid(live)

      # Restore folded the post-checkpoint tail forward: fold(0..T) == full fold.
      assert model == %{"applied" => [1, 2, 4, 5]}

      # No record at/below the horizon is delivered live (no dup: 4 and 5 are
      # already folded into the model).
      refute_receive {:reattach_live, ^session_id, %{"id" => 4}}, 100
      refute_receive {:reattach_live, ^session_id, %{"id" => 5}}, 100

      # A record appended above the horizon streams live (no gap).
      {:ok, 6} = FileStore.append(j, loop_event("turn_started", "t3"))
      assert_receive {:reattach_live, ^session_id, %{"id" => 6}}, 500

      FileStore.close(j)
    end

    test "attach (:snapshot) on a tip-only pointer folds 0..tip and tails from tip+1" do
      session_id = "cmd-snap-tip-#{System.unique_integer([:positive])}"
      {:ok, j} = FileStore.open(session_id)
      {:ok, 1} = FileStore.append(j, loop_event("turn_started"))
      {:ok, 2} = FileStore.append(j, loop_event("turn_completed"))

      # A tip-only pointer (nil model, snapshot_ref: nil) at tip = 2.
      {:ok, 3} = Checkpoint.write(j, nil, reason: "manual")

      {:ok, 4} = FileStore.append(j, loop_event("turn_started", "t2"))
      {:ok, 5} = FileStore.append(j, loop_event("turn_completed", "t2"))

      {:ok, cmd} =
        Command.decode(%{
          "type" => "attach",
          "payload" => %{"from_offset" => 0, "history_policy" => "snapshot"}
        })

      # Tip-only restore folds 0..tip only (H = tip_offset = 2), so the tail
      # streams live from tip+1 (= 3), including the checkpoint pointer record.
      assert {:ok, %{snapshot: model, from_offset: 3, history: []}} =
               Command.route(cmd, %{session_id: session_id, pid: self()})

      assert model == %{"applied" => [1, 2]}

      refute_receive {:reattach_live, ^session_id, %{"id" => 2}}, 100
      assert_receive {:reattach_live, ^session_id, %{"id" => 3}}, 500
      assert_receive {:reattach_live, ^session_id, %{"id" => 4}}, 500
      assert_receive {:reattach_live, ^session_id, %{"id" => 5}}, 500

      FileStore.close(j)
    end

    test "attach (:snapshot) with no checkpoint returns {:error, :no_checkpoint}" do
      session_id = "cmd-snap-none-#{System.unique_integer([:positive])}"
      {:ok, j} = FileStore.open(session_id)
      {:ok, 1} = FileStore.append(j, loop_event("turn_started"))
      {:ok, 2} = FileStore.append(j, loop_event("turn_completed"))
      FileStore.close(j)

      {:ok, cmd} =
        Command.decode(%{
          "type" => "attach",
          "payload" => %{"from_offset" => 0, "history_policy" => "snapshot"}
        })

      # A session with events but no checkpoint: :snapshot is the
      # restore-from-checkpoint fast path, so it reports no checkpoint rather
      # than silently degrading (the caller uses :replay/:live instead).
      assert {:error, :no_checkpoint} =
               Command.route(cmd, %{session_id: session_id, pid: self()})

      refute_receive {:reattach_live, ^session_id, _}, 100
    end

    test "attach (:snapshot) surfaces a corrupt snapshot (N-JS3), no silent fallback" do
      session_id = "cmd-snap-corrupt-#{System.unique_integer([:positive])}"
      {:ok, j} = FileStore.open(session_id)
      {:ok, 1} = FileStore.append(j, loop_event("turn_started"))
      {:ok, 2} = FileStore.append(j, loop_event("turn_completed"))
      {:ok, 3} = Checkpoint.write(j, %{"applied" => [1, 2]}, reason: "manual")

      # Flip the snapshot bytes so sha256 no longer matches snapshot_hash.
      {:ok, records} = FileStore.read(j)
      cp = Enum.find(records, &(&1["kind"] == "checkpoint"))
      snap_path = Path.join(FileStore.session_dir(session_id), cp["snapshot_ref"])
      File.write!(snap_path, File.read!(snap_path) <> "corruption")

      {:ok, cmd} =
        Command.decode(%{
          "type" => "attach",
          "payload" => %{"from_offset" => 0, "history_policy" => "snapshot"}
        })

      assert {:error, :snapshot_corrupt} =
               Command.route(cmd, %{session_id: session_id, pid: self()})

      refute_receive {:reattach_live, ^session_id, _}, 100

      FileStore.close(j)
    end

    test "seek folds durable events up to the offset into a projection" do
      session_id = "cmd-seek-#{System.unique_integer([:positive])}"
      {:ok, j} = FileStore.open(session_id)
      {:ok, 1} = FileStore.append(j, loop_event("turn_started"))
      {:ok, 2} = FileStore.append(j, loop_event("turn_completed"))
      {:ok, 3} = FileStore.append(j, loop_event("turn_started", "t2"))
      FileStore.close(j)

      # offset 0 folds nothing.
      {:ok, cmd0} = Command.decode(%{"type" => "seek", "payload" => %{"offset" => 0}})
      assert {:ok, %{source_events: []}} = Command.route(cmd0, %{session_id: session_id})

      # offset 2 folds ids 1..2 (durable, tier-retained in source_events).
      {:ok, cmd2} = Command.decode(%{"type" => "seek", "payload" => %{"offset" => 2}})
      assert {:ok, %{source_events: evs}} = Command.route(cmd2, %{session_id: session_id})
      assert length(evs) == 2

      # offset past the end folds the whole durable stream.
      {:ok, cmd9} = Command.decode(%{"type" => "seek", "payload" => %{"offset" => 9}})
      assert {:ok, %{source_events: all}} = Command.route(cmd9, %{session_id: session_id})
      assert length(all) == 3
    end
  end

  describe "decode/1 |> route/2 — end to end" do
    test "a wire prompt line drives a start turn" do
      assert {:ok, cmd} =
               Command.decode(~s({"type":"prompt","payload":{"text":"hi"}}))

      assert {:start_turn, "s", %{text: "hi"}} =
               Command.route(cmd, %{session_id: "s"})
    end
  end

  defp loop_event(type, turn_id \\ "t1") do
    %{
      "kind" => "event",
      "family" => "loop",
      "type" => type,
      "tier" => "durable",
      "turn_id" => turn_id,
      "payload" => %{}
    }
  end
end
