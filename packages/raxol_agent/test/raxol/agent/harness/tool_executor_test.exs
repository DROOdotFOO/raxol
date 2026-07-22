defmodule Raxol.Agent.Harness.ToolExecutorTest do
  @moduledoc """
  Red-first spec for the live harness tool-execution loop
  (`Raxol.Agent.Harness.ToolExecutor`) — the seam whose absence made a
  tool call go unanswered and the turn die.

  Each test scripts a backend that returns a tool call on the first round
  and a text answer on the second, then drains the executor stream and
  asserts the observable event sequence.
  """

  use ExUnit.Case, async: false

  alias Raxol.Agent.Actions.Fs
  alias Raxol.Agent.Actions.Workspace
  alias Raxol.Agent.Contract
  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.Harness.ToolExecutor
  alias Raxol.Agent.SessionStreamer

  # A backend that pops a scripted response per `complete/2` call: each
  # element is `{:tool_calls, list}`, `{:content, text}`, or `{:response,
  # map}` — the last handing the loop a full `complete/2` return map so a
  # test can pin the reasoning channel and truncation metadata verbatim.
  defmodule ScriptBackend do
    @behaviour Raxol.Agent.AIBackend

    @impl true
    def complete(_messages, opts) do
      agent = Keyword.fetch!(opts, :script)

      step =
        Agent.get_and_update(agent, fn
          [head | tail] -> {head, tail}
          [] -> {:eot, []}
        end)

      case step do
        {:tool_calls, tcs} ->
          {:ok, %{content: "", tool_calls: tcs, usage: %{}}}

        {:content, text} ->
          {:ok, %{content: text, usage: %{}}}

        {:response, response} when is_map(response) ->
          {:ok, response}

        :eot ->
          {:ok, %{content: "(end)", usage: %{}}}
      end
    end

    @impl true
    def stream(_messages, _opts), do: {:error, :streaming_not_used}

    @impl true
    def available?, do: true

    @impl true
    def name, do: "script"

    @impl true
    def capabilities, do: [:completion, :tool_use]
  end

  # A backend whose `stream/2` pops a scripted LIST of stream events per
  # round (reasoning/text deltas + a terminal `{:done, response}` carrying
  # content + tool_calls) — exercises the `stream: true` path: reasoning and
  # text must be forwarded LIVE, and a tool call must survive the stream
  # round-trip (the correctness the blocking `complete/2` choice was
  # protecting).
  defmodule StreamBackend do
    @behaviour Raxol.Agent.AIBackend

    @impl true
    def complete(_messages, _opts),
      do: {:ok, %{content: "(complete unused)", usage: %{}}}

    @impl true
    def stream(_messages, opts) do
      agent = Keyword.fetch!(opts, :script)

      events =
        Agent.get_and_update(agent, fn
          [round | tail] -> {round, tail}
          [] -> {[{:done, %{content: "(end)", tool_calls: [], usage: %{}}}], []}
        end)

      {:ok, events}
    end

    @impl true
    def available?, do: true

    @impl true
    def name, do: "stream-script"

    @impl true
    def capabilities, do: [:completion, :streaming, :tool_use]
  end

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "raxol-exec-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    prev = System.get_env("RAXOL_CLI_CWD")
    System.put_env("RAXOL_CLI_CWD", tmp)

    on_exit(fn ->
      if prev,
        do: System.put_env("RAXOL_CLI_CWD", prev),
        else: System.delete_env("RAXOL_CLI_CWD")

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  defp script(steps) do
    {:ok, agent} = Agent.start_link(fn -> steps end)
    agent
  end

  defp run(steps, opts) do
    agent = script(steps)

    ToolExecutor.stream(
      "do the thing",
      Keyword.merge(
        [backend: ScriptBackend, backend_opts: [script: agent]],
        opts
      )
    )
    |> Enum.to_list()
  end

  defp types(events), do: Enum.map(events, &elem(&1, 0))

  describe "read-only tool: auto-allowed, no approval" do
    test "read_file executes and its result feeds back to a text answer", %{
      tmp: tmp
    } do
      File.write!(Path.join(tmp, "hello.txt"), "line one\nline two\n")

      events =
        run(
          [
            {:tool_calls,
             [
               %{
                 "name" => "read_file",
                 "arguments" => %{"path" => "hello.txt"},
                 "id" => "t1"
               }
             ]},
            {:content, "The file has two lines."}
          ],
          actions: Fs.all()
        )

      # No approval events for a read-only tool.
      refute :approval_requested in types(events)

      assert {:tool_use, %{name: "read_file"}} =
               Enum.find(events, &match?({:tool_use, _}, &1))

      assert {:tool_result, %{name: "read_file", result: %{content: content}}} =
               Enum.find(events, &match?({:tool_result, _}, &1))

      assert content =~ "line one"

      assert {:done, %{content: "The file has two lines."}} =
               Enum.find(events, &match?({:done, _}, &1))
    end
  end

  describe "outside-cwd read: escalates to the operator (V's ruling), never a silent escape" do
    # An outside-cwd read_file used to hard-refuse (:outside_cwd). It now
    # ASKS — same gate an edit uses — and only the allow for THIS call
    # grants the one-shot unconfined resolve.
    test "allow → the approval fires and the read returns the outside content" do
      outside_dir =
        Path.join(
          System.tmp_dir!(),
          "rx-outside-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(outside_dir)
      outside = Path.join(outside_dir, "secret.txt")
      File.write!(outside, "OUTSIDE-CONTENT")
      on_exit(fn -> File.rm_rf!(outside_dir) end)

      events =
        run(
          [
            {:tool_calls,
             [
               %{
                 "name" => "read_file",
                 "arguments" => %{"path" => outside},
                 "id" => "r1"
               }
             ]},
            {:content, "done"}
          ],
          actions: Fs.all(),
          await_decision: fn _rid, _meta -> {:allow, "allow"} end
        )

      assert {:approval_requested, %{tool_name: "read_file"}} =
               Enum.find(events, &match?({:approval_requested, _}, &1))

      assert {:tool_result, %{name: "read_file", result: %{content: content}}} =
               Enum.find(events, &match?({:tool_result, _}, &1))

      assert content =~ "OUTSIDE-CONTENT"
    end

    test "deny → refused, file never read" do
      outside_dir =
        Path.join(
          System.tmp_dir!(),
          "rx-outside-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(outside_dir)
      outside = Path.join(outside_dir, "secret.txt")
      File.write!(outside, "OUTSIDE-CONTENT")
      on_exit(fn -> File.rm_rf!(outside_dir) end)

      events =
        run(
          [
            {:tool_calls,
             [
               %{
                 "name" => "read_file",
                 "arguments" => %{"path" => outside},
                 "id" => "r2"
               }
             ]},
            {:content, "done"}
          ],
          actions: Fs.all(),
          await_decision: fn _rid, _meta -> {:deny, "deny", :nope} end
        )

      assert :approval_requested in types(events)

      {:tool_result, %{result: result}} =
        Enum.find(events, &match?({:tool_result, _}, &1))

      refute match?(%{content: _}, result)
    end

    test "gate OFF (--yolo) keeps the HARD sandbox: no ask, no escape" do
      outside_dir =
        Path.join(
          System.tmp_dir!(),
          "rx-outside-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(outside_dir)
      outside = Path.join(outside_dir, "secret.txt")
      File.write!(outside, "OUTSIDE-CONTENT")
      on_exit(fn -> File.rm_rf!(outside_dir) end)

      events =
        run(
          [
            {:tool_calls,
             [
               %{
                 "name" => "read_file",
                 "arguments" => %{"path" => outside},
                 "id" => "r3"
               }
             ]},
            {:content, "done"}
          ],
          actions: Fs.all(),
          gate?: false
        )

      refute :approval_requested in types(events)

      {:tool_result, %{result: result}} =
        Enum.find(events, &match?({:tool_result, _}, &1))

      assert match?({:error, :outside_cwd}, result)
    end

    test "an inside-cwd read stays ungated (no new friction)", %{tmp: tmp} do
      File.write!(Path.join(tmp, "in.txt"), "inside")

      events =
        run(
          [
            {:tool_calls,
             [
               %{
                 "name" => "read_file",
                 "arguments" => %{"path" => "in.txt"},
                 "id" => "r4"
               }
             ]},
            {:content, "done"}
          ],
          actions: Fs.all(),
          await_decision: fn _rid, _meta -> raise "must not ask" end
        )

      refute :approval_requested in types(events)

      assert {:tool_result, %{result: %{content: "inside"}}} =
               Enum.find(events, &match?({:tool_result, _}, &1))
    end
  end

  describe "consequential tool: approval gate" do
    test "allow → edit runs, tool_result carries the ± diff payload", %{
      tmp: tmp
    } do
      path = Path.join(tmp, "code.ex")
      File.write!(path, "defmodule A do\n  def x, do: 1\nend\n")

      events =
        run(
          [
            {:tool_calls,
             [
               %{
                 "name" => "edit_file",
                 "arguments" => %{
                   "path" => "code.ex",
                   "old_string" => "def x, do: 1",
                   "new_string" => "def x, do: 2"
                 },
                 "id" => "e1"
               }
             ]},
            {:content, "Changed x to return 2."}
          ],
          actions: Workspace.all(),
          await_decision: fn _rid, _meta -> {:allow, "allow"} end
        )

      assert {:approval_requested,
              %{tool_name: "edit_file", request_id: rid, options: opts}} =
               Enum.find(events, &match?({:approval_requested, _}, &1))

      assert is_list(opts) and Enum.any?(opts, &(&1.kind == :allow_once))

      assert {:approval_decided, %{request_id: ^rid, decision: :allow}} =
               Enum.find(events, &match?({:approval_decided, _}, &1))

      # The edit actually happened.
      assert File.read!(path) =~ "def x, do: 2"

      # The tool_result carries {path, old, new} — the diff-block shape.
      assert {:tool_result, %{name: "edit_file", result: result}} =
               Enum.find(events, &match?({:tool_result, _}, &1))

      assert %{path: "code.ex", old: old, new: new} = result
      assert old =~ "def x, do: 1"
      assert new =~ "def x, do: 2"

      # approval_requested precedes approval_decided precedes tool_result.
      assert index(events, :approval_requested) <
               index(events, :approval_decided)

      assert index(events, :approval_decided) < index(events, :tool_result)
    end

    test "deny → no file change, honest denial tool_result, model told", %{
      tmp: tmp
    } do
      path = Path.join(tmp, "code.ex")
      original = "defmodule A do\n  def x, do: 1\nend\n"
      File.write!(path, original)

      events =
        run(
          [
            {:tool_calls,
             [
               %{
                 "name" => "edit_file",
                 "arguments" => %{
                   "path" => "code.ex",
                   "old_string" => "def x, do: 1",
                   "new_string" => "def x, do: 2"
                 },
                 "id" => "e1"
               }
             ]},
            {:content, "Understood, I won't change it."}
          ],
          actions: Workspace.all(),
          await_decision: fn _rid, _meta ->
            {:deny, "deny", :operator_declined}
          end
        )

      assert {:approval_decided, %{decision: :deny}} =
               Enum.find(events, &match?({:approval_decided, _}, &1))

      assert {:tool_result,
              %{
                name: "edit_file",
                result: {:error, {:denied, :operator_declined}}
              }} =
               Enum.find(events, &match?({:tool_result, _}, &1))

      # File is untouched.
      assert File.read!(path) == original
    end

    test "yolo (gate?: false) runs the consequential tool with NO approval events",
         %{tmp: tmp} do
      path = Path.join(tmp, "code.ex")
      File.write!(path, "old\n")

      events =
        run(
          [
            {:tool_calls,
             [
               %{
                 "name" => "write_file",
                 "arguments" => %{"path" => "code.ex", "content" => "new\n"},
                 "id" => "w1"
               }
             ]},
            {:content, "Wrote it."}
          ],
          actions: Workspace.all(),
          gate?: false
        )

      refute :approval_requested in types(events)
      refute :approval_decided in types(events)
      assert File.read!(path) == "new\n"
    end
  end

  describe "the approval carries the PROPOSED DIFF (shown == done)" do
    test "edit_file's approval_requested lifts {diff, path, old, new} computed before executing",
         %{tmp: tmp} do
      path = Path.join(tmp, "code.ex")
      File.write!(path, "def x, do: 1\n")

      events =
        run(
          [
            {:tool_calls,
             [
               %{
                 "name" => "edit_file",
                 "arguments" => %{
                   "path" => "code.ex",
                   "old_string" => "def x, do: 1",
                   "new_string" => "def x, do: 2"
                 },
                 "id" => "e1"
               }
             ]},
            {:content, "done"}
          ],
          actions: Workspace.all(),
          await_decision: fn _rid, _meta -> {:allow, "allow"} end
        )

      assert {:approval_requested, payload} =
               Enum.find(events, &match?({:approval_requested, _}, &1))

      assert payload.diff == true
      assert payload.path == "code.ex"
      assert payload.old == "def x, do: 1\n"
      assert payload.new =~ "def x, do: 2"

      # The diff shown at approval time is the diff that executed: the
      # tool_result's old/new equals the approval's old/new.
      assert {:tool_result, %{result: %{old: r_old, new: r_new}}} =
               Enum.find(events, &match?({:tool_result, _}, &1))

      assert {payload.old, payload.new} == {r_old, r_new}
    end

    test "write_file on a NEW file previews an all-adds diff (old is empty)", %{
      tmp: _tmp
    } do
      events =
        run(
          [
            {:tool_calls,
             [
               %{
                 "name" => "write_file",
                 "arguments" => %{
                   "path" => "brand_new.ex",
                   "content" => "a\nb\n"
                 },
                 "id" => "w1"
               }
             ]},
            {:content, "created"}
          ],
          actions: Workspace.all(),
          await_decision: fn _rid, _meta -> {:allow, "allow"} end
        )

      assert {:approval_requested, %{diff: true, old: "", new: "a\nb\n"}} =
               Enum.find(events, &match?({:approval_requested, _}, &1))
    end

    test "a NON-MATCHING edit STILL lifts old/new/path into the approval (best-effort, marked not_found)",
         %{tmp: tmp} do
      path = Path.join(tmp, "code.ex")
      File.write!(path, "def x, do: 1\n")

      events =
        run(
          [
            {:tool_calls,
             [
               %{
                 "name" => "edit_file",
                 "arguments" => %{
                   "path" => "code.ex",
                   # This target is NOT in the file — the old failure mode
                   # returned :none and the operator saw raw args, no diff.
                   "old_string" => "def NOPE, do: 0",
                   "new_string" => "def y, do: 2"
                 },
                 "id" => "e1"
               }
             ]},
            {:content, "tried"}
          ],
          actions: Workspace.all(),
          await_decision: fn _rid, _meta -> {:deny, "deny", :nope} end
        )

      assert {:approval_requested, payload} =
               Enum.find(events, &match?({:approval_requested, _}, &1))

      # The operator sees a renderable diff — the proposed hunk — not raw args.
      assert payload.diff == true
      assert payload.path == "code.ex"
      assert payload.old == "def NOPE, do: 0"
      assert payload.new == "def y, do: 2"
      # ...honestly marked as an un-located target so the UI can note it.
      assert payload.preview_match == :not_found
    end

    test "allowing a non-matching edit executes STRICTLY: honest error result, file untouched, no crash on the absent base_hash",
         %{tmp: tmp} do
      path = Path.join(tmp, "code.ex")
      File.write!(path, "def x, do: 1\n")

      events =
        run(
          [
            {:tool_calls,
             [
               %{
                 "name" => "edit_file",
                 "arguments" => %{
                   "path" => "code.ex",
                   "old_string" => "def NOPE, do: 0",
                   "new_string" => "def y, do: 2"
                 },
                 "id" => "e1"
               }
             ]},
            {:content, "tried"}
          ],
          actions: Workspace.all(),
          await_decision: fn _rid, _meta -> {:allow, "allow"} end
        )

      # The approval carried the best-effort diff...
      assert {:approval_requested, %{preview_match: :not_found}} =
               Enum.find(events, &match?({:approval_requested, _}, &1))

      # ...and apply_after_allow handled the missing base_hash without crashing
      # (a stale-check would have raised) — falling through to a strict
      # execution that fails loudly instead of silently applying.
      assert {:tool_result, %{name: "edit_file", result: {:error, _reason}}} =
               Enum.find(events, &match?({:tool_result, _}, &1))

      # File is untouched — never served something other than the preview.
      assert File.read!(path) == "def x, do: 1\n"
    end
  end

  describe "staleness: the file must not change between question and answer" do
    test "a drift after approval is NOT applied -- the honest stale result fires instead",
         %{tmp: tmp} do
      path = Path.join(tmp, "code.ex")
      File.write!(path, "def x, do: 1\n")

      events =
        run(
          [
            {:tool_calls,
             [
               %{
                 "name" => "edit_file",
                 "arguments" => %{
                   "path" => "code.ex",
                   "old_string" => "def x, do: 1",
                   "new_string" => "def x, do: 2"
                 },
                 "id" => "e1"
               }
             ]},
            {:content, "done"}
          ],
          actions: Workspace.all(),
          await_decision: fn _rid, _meta ->
            # The file drifts under us BETWEEN the previewed diff and the
            # answer -- the old_string is still present (so a naive edit
            # WOULD apply), but the content the operator approved against is
            # gone. The hash guard must catch it.
            File.write!(path, "def x, do: 1\n# sneaked in\n")
            {:allow, "allow"}
          end
        )

      assert {:tool_result,
              %{name: "edit_file", result: {:error, :stale_approval}}} =
               Enum.find(events, &match?({:tool_result, _}, &1))

      # Our edit was NEVER applied -- the file keeps the drifted content.
      assert File.read!(path) == "def x, do: 1\n# sneaked in\n"
      refute File.read!(path) =~ "def x, do: 2"
    end
  end

  describe "honesty: recognized-but-unexecuted tool calls" do
    test "an unknown tool name yields an honest error tool_result, never silence" do
      events =
        run(
          [
            {:tool_calls,
             [%{"name" => "delete_everything", "arguments" => %{}, "id" => "x"}]},
            {:content, "ok"}
          ],
          actions: Workspace.all(),
          gate?: false
        )

      assert {:tool_result,
              %{
                name: "delete_everything",
                result: {:error, {:unknown_tool, "delete_everything"}}
              }} =
               Enum.find(events, &match?({:tool_result, _}, &1))
    end

    test "a tool call with no name is marked unexecuted AND produces an error result" do
      events =
        run(
          [
            {:tool_calls, [%{"arguments" => %{}, "id" => "x"}]},
            {:content, "ok"}
          ],
          actions: Workspace.all(),
          gate?: false
        )

      assert {:tool_unexecuted, %{reason: :missing_tool_name}} =
               Enum.find(events, &match?({:tool_unexecuted, _}, &1))

      assert Enum.any?(events, &match?({:tool_result, _}, &1))
    end
  end

  # RED-FIRST: reasoning is invisible on the LIVE harness path. The loop
  # drives `complete/2`, which (since the LongCat wire fix) exposes
  # `response.reasoning` — but the loop never surfaced it, so the model's
  # thinking was parsed and dropped. Each round with non-empty reasoning
  # must emit a `{:reasoning, _}` event BEFORE that round's tool/text
  # events, so `Contract.pump/3` seals it as a durable ∴ block.
  describe "reasoning: the complete/2 producer surfaces model thinking" do
    defp reasoning_texts(events), do: for({:reasoning, t} <- events, do: t)

    defp indices_of(events, type),
      do: for({e, i} <- Enum.with_index(events), elem(e, 0) == type, do: i)

    test "each round's reasoning is emitted before that round's tool/text events",
         %{tmp: tmp} do
      File.write!(Path.join(tmp, "f.txt"), "hi\n")

      events =
        run(
          [
            {:response,
             %{
               content: "",
               tool_calls: [
                 %{
                   "name" => "read_file",
                   "arguments" => %{"path" => "f.txt"},
                   "id" => "t1"
                 }
               ],
               usage: %{},
               reasoning: "first I plan the read"
             }},
            {:response,
             %{content: "the answer", usage: %{}, reasoning: "now I conclude"}}
          ],
          actions: Fs.all(),
          gate?: false
        )

      # Both rounds' thoughts surfaced, in true order.
      assert reasoning_texts(events) == [
               "first I plan the read",
               "now I conclude"
             ]

      [r1, r2] = indices_of(events, :reasoning)
      [tool_use_i] = indices_of(events, :tool_use)
      [text_i] = indices_of(events, :text_delta)

      # Round 1 thought precedes the tool it reasoned toward.
      assert r1 < tool_use_i
      # Round 2 thought is in the SECOND round (after the tool) and precedes
      # the final answer text.
      assert r2 > tool_use_i
      assert r2 < text_i
    end

    test "blank (whitespace-only) reasoning emits no {:reasoning, _} event" do
      events =
        run(
          [{:response, %{content: "hi", usage: %{}, reasoning: "   \n\t"}}],
          actions: [],
          gate?: false
        )

      refute Enum.any?(events, &match?({:reasoning, _}, &1))
    end

    test "a response with no reasoning channel emits no {:reasoning, _} event" do
      events = run([{:content, "hi"}], actions: [], gate?: false)
      refute Enum.any?(events, &match?({:reasoning, _}, &1))
    end

    test "a non-empty length-truncated round seals its reasoning AND discloses a truncation marker" do
      events =
        run(
          [
            {:response,
             %{
               content: "partial ans",
               usage: %{},
               reasoning: "was thinking hard",
               metadata: %{
                 finish_reason: :length,
                 truncated: true,
                 marker:
                   "⚠ response truncated — hit token limit; raise AI_MAX_TOKENS"
               }
             }}
          ],
          actions: [],
          gate?: false
        )

      assert {:reasoning, "was thinking hard"} in events

      assert {:marker, marker} =
               Enum.find(events, &match?({:marker, _}, &1))

      assert marker =~ "truncated"

      # reasoning → partial content → truncation marker (the marker
      # qualifies the answer, so it lands after it).
      [ri] = indices_of(events, :reasoning)
      [ti] = indices_of(events, :text_delta)
      [mi] = indices_of(events, :marker)
      assert ri < ti and ti < mi
    end
  end

  # RED-FIRST end-to-end: the REAL live path is ToolExecutor → Contract.pump.
  # Scripting `complete/2` with reasoning on the tool round AND the answer
  # round must land TWO durable ∴ reasoning blocks in the run history, each
  # sealed before its round's tool/message block.
  describe "end-to-end: live path (ToolExecutor → Contract.pump) seals ∴ blocks" do
    setup do
      start_supervised!({SessionStreamer, []})
      :ok
    end

    test "think→tool→think→answer seals TWO ∴ blocks, each before its round's items",
         %{tmp: tmp} do
      File.write!(Path.join(tmp, "f.txt"), "hi\n")
      session_id = "exec-e2e-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      agent =
        script([
          {:response,
           %{
             content: "",
             tool_calls: [
               %{
                 "name" => "read_file",
                 "arguments" => %{"path" => "f.txt"},
                 "id" => "t1"
               }
             ],
             usage: %{},
             reasoning: "first, read the file"
           }},
          {:response,
           %{content: "done reading", usage: %{}, reasoning: "now, answer"}}
        ])

      stream =
        ToolExecutor.stream("go",
          backend: ScriptBackend,
          backend_opts: [script: agent],
          actions: Fs.all(),
          gate?: false
        )

      assert {:ok, _} = Contract.pump(session_id, stream, prompt: "go")
      events = drain_events(session_id)

      reasoning_seals =
        for %Event{type: :item_completed, payload: %{item_type: :reasoning} = p} <-
              events,
            do: p

      assert Enum.map(reasoning_seals, & &1.content) == [
               "first, read the file",
               "now, answer"
             ]

      # Round 1: the first ∴ seals BEFORE the tool_use block.
      first_reasoning_seal =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :reasoning)
        )

      tool_use =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :tool_use)
        )

      assert first_reasoning_seal.id < tool_use.id

      # Round 2: the second ∴ seals BEFORE the final answer message.
      second_reasoning_seal =
        Enum.find(
          Enum.reverse(events),
          &(&1.type == :item_completed and &1.payload[:item_type] == :reasoning)
        )

      final_message =
        Enum.find(
          Enum.reverse(events),
          &(&1.type == :item_completed and &1.payload[:item_type] == :message)
        )

      assert second_reasoning_seal.id < final_message.id
      assert tool_use.id < second_reasoning_seal.id
    end
  end

  defp drain_events(session_id, acc \\ []) do
    receive do
      {:session_event, ^session_id, %Event{} = event} ->
        drain_events(session_id, [event | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp index(events, type) do
    Enum.find_index(events, fn e -> elem(e, 0) == type end)
  end

  describe "streaming round (stream: true)" do
    test "forwards reasoning + text deltas LIVE and a tool call survives the round-trip",
         %{tmp: tmp} do
      File.write!(Path.join(tmp, "a.txt"), "hello world")

      steps = [
        # round 1: reasoning streams token-by-token, then :done carries a tool call
        [
          {:reasoning, "let me read "},
          {:reasoning, "the file"},
          {:done,
           %{
             content: "",
             tool_calls: [
               %{
                 "id" => "c1",
                 "name" => "read_file",
                 "arguments" => %{"path" => "a.txt"}
               }
             ],
             usage: %{}
           }}
        ],
        # round 2: reasoning + answer text stream live, no tool call
        [
          {:reasoning, "got it"},
          {:chunk, "the file says "},
          {:chunk, "hello world"},
          {:done,
           %{content: "the file says hello world", tool_calls: [], usage: %{}}}
        ]
      ]

      events =
        ToolExecutor.stream("read a.txt",
          backend: StreamBackend,
          backend_opts: [script: script(steps)],
          actions: Fs.all(),
          gate?: false,
          stream: true
        )
        |> Enum.to_list()

      ts = types(events)

      # reasoning forwarded LIVE -- multiple deltas, not one whole blob
      assert Enum.count(events, &match?({:reasoning, _}, &1)) >= 3

      # answer text streamed LIVE, per chunk (not re-emitted whole at :done)
      assert Enum.any?(events, &match?({:text_delta, "the file says "}, &1))
      assert Enum.any?(events, &match?({:text_delta, "hello world"}, &1))

      # the tool call survived the stream round-trip -> it executed
      assert :tool_use in ts
      assert :tool_result in ts
      assert :done in ts

      # ordering: reasoning precedes the tool it reasoned toward
      assert index(events, :reasoning) < index(events, :tool_use)
    end
  end
end
