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
  alias Raxol.Agent.Harness.ToolExecutor

  # A backend that pops a scripted response per `complete/2` call: each
  # element is `{:tool_calls, list}` or `{:content, text}`.
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

  defp index(events, type) do
    Enum.find_index(events, fn e -> elem(e, 0) == type end)
  end
end
