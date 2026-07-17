defmodule Raxol.MCP.HarnessApprovalBlockMcpSeamTest do
  @moduledoc """
  The headless-approval story: an MCP client answers a LIVE harness approval
  programmatically, deriving its answer tools from the real running demo's
  view tree -- no hand-built trees.

  The loop under proof (spec `harness-tea-migration.md` §7, the approval
  pins + the MCP derivation pin):

      start_session(HarnessApprovalBlockDemo)   # real Headless session
      |> get_tools()                            # tools/list: answer_* derived
                                                #   from the LIVE approval node
      |> call_tool("approval-bash-live.answer_allow")
      screenshot                                # the block sealed to a receipt

  Affordance honesty: only a LIVE, direct-mode approval derives answer
  tools, and only for the option classes the request actually offers; a
  sealed approval derives none.
  """
  use ExUnit.Case, async: false

  import Raxol.MCP.Test

  alias Raxol.Headless
  alias Raxol.Playground.Demos.HarnessApprovalBlockDemo

  @settle_ms 250

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

  defp start(id_suffix) do
    start_session(HarnessApprovalBlockDemo,
      width: 90,
      height: 40,
      settle_ms: @settle_ms,
      id: :"approval_block_mcp_#{id_suffix}"
    )
  end

  test "tools/list derives answer tools from the LIVE approval node" do
    session = start(:list)

    names = session |> get_tools() |> Enum.map(& &1[:name])

    # The live bash approval offers allow + deny classes and three options.
    assert "approval-bash-live.answer_allow" in names,
           "expected live-derived approval tools, got: #{inspect(names)}"

    assert "approval-bash-live.answer_deny" in names
    assert "approval-bash-live.answer_option" in names

    # The SEALED history blocks are answered questions -- they derive no
    # answer tools (affordance honesty).
    refute "approval-edit-done.answer_allow" in names
    refute "approval-bash-done.answer_deny" in names

    stop_session(session)
  end

  test "answer_option's schema range matches the live request's real options" do
    session = start(:schema)

    tool =
      session
      |> get_tools()
      |> Enum.find(&(&1[:name] == "approval-bash-live.answer_option"))

    assert tool, "the live approval must derive an answer_option tool"

    option_schema = get_in(tool, [:inputSchema, :properties, :option])
    assert option_schema.minimum == 1
    assert option_schema.maximum == 3

    stop_session(session)
  end

  test "invoking a derived answer tool seals the block: the receipt reaches the screen" do
    session = start(:answer)

    # Before: the live approval's affordance is on screen
    assert screenshot(session) =~ "1-3 to choose"

    # Invoke the derived tool -- the full MCP pipeline: the tool presses the
    # same answer key a human would, the demo update resolves + seals it.
    # call_tool returns the session (it already waits settle_ms).
    session = call_tool(session, "approval-bash-live.answer_allow", %{})

    text = screenshot(session)
    assert text =~ "by you"
    refute text =~ "1-3 to choose"

    stop_session(session)
  end

  test "answer_option by number routes through to a deny receipt" do
    session = start(:option)

    session =
      call_tool(session, "approval-bash-live.answer_option", %{"option" => 3})

    assert screenshot(session) =~ "✗ denied"

    stop_session(session)
  end

  test "the StructuredScreenshot surfaces the live approval node" do
    session = start(:structured)

    component = get_component(session, "approval-bash-live")

    assert component, "the live approval node must appear in the widget tree"
    assert component[:type] == :approval_prompt

    stop_session(session)
  end
end
