defmodule Raxol.Agent.Harness.McpToolsTest do
  # async: false — the no-provider test clears real provider env vars, and
  # every test swaps the session store via RAXOL_CODE_SESSIONS.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Harness.McpTools

  @managed_env ~w(
    ANTHROPIC_API_KEY OPENAI_API_KEY KIMI_API_KEY MOONSHOT_API_KEY
    OPENROUTER_API_KEY LONGCAT_API_KEY PROTON_ACCESS_TOKEN AI_API_KEY
    RAXOL_ANTHROPIC_OP RAXOL_OPENAI_OP RAXOL_KIMI_OP RAXOL_OPENROUTER_OP
    RAXOL_LONGCAT_OP RAXOL_LUMO_OP RAXOL_OLLAMA_OP RAXOL_LM_STUDIO_OP
    RAXOL_LLM7_OP RAXOL_MOCK_OP
  )

  setup do
    # The named streamer under the test supervisor, so a turn's
    # ensure_streamer! finds it running and no test-linked instance leaks
    # into later suites (the keystone tests start_supervised! the same name).
    start_supervised!(Raxol.Agent.SessionStreamer)

    saved = Map.new(@managed_env, fn key -> {key, System.get_env(key)} end)
    Enum.each(@managed_env, &System.delete_env/1)

    sessions =
      Path.join(
        System.tmp_dir!(),
        "raxol-harness-mcp-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(sessions)

    prev = %{
      "RAXOL_CODE_SESSIONS" => System.get_env("RAXOL_CODE_SESSIONS"),
      "RAXOL_PROVIDERS" => System.get_env("RAXOL_PROVIDERS")
    }

    System.put_env("RAXOL_CODE_SESSIONS", sessions)
    System.put_env("RAXOL_PROVIDERS", Path.join(sessions, "providers.json"))

    on_exit(fn ->
      Enum.each(Map.merge(saved, prev), fn
        {key, nil} -> System.delete_env(key)
        {key, val} -> System.put_env(key, val)
      end)

      File.rm_rf(sessions)
    end)

    %{sessions: sessions}
  end

  defp call(name, args) do
    tool = Enum.find(McpTools.tools(), &(&1.name == name))
    tool.callback.(args)
  end

  test "tool definitions validate against the MCP tool-def contract" do
    tools = McpTools.tools()

    assert Enum.map(tools, & &1.name) == [
             "harness_start_session",
             "harness_send_prompt",
             "harness_read_transcript",
             "harness_list_sessions"
           ]

    Enum.each(tools, fn tool ->
      assert :ok = Raxol.MCP.ToolDef.validate(tool)
    end)
  end

  test "start, list, and read compose over the shared session store" do
    assert {:ok, key} = call("harness_start_session", %{})
    assert key =~ ~r/^sess-\d+-\d+$/

    assert {:ok, listing} = call("harness_list_sessions", %{})
    assert listing =~ key
    assert listing =~ "(0 msgs)"

    assert {:ok, "(empty session)"} =
             call("harness_read_transcript", %{"session_id" => key})
  end

  test "send_prompt runs a turn, persists history, and stays TUI-resumable",
       ctx do
    {:ok, key} = call("harness_start_session", %{})

    assert {:ok, answer} =
             call("harness_send_prompt", %{
               "session_id" => key,
               "prompt" => "hello there",
               "backend" => "mock"
             })

    assert is_binary(answer) and answer != ""

    # Persisted in the same store and shape the TUI resumes from.
    assert {:ok, session} = Raxol.Agent.Code.Store.load(ctx.sessions, key)

    assert [%{role: :user, content: "hello there"}, %{role: :assistant}] =
             session.messages

    assert session.events != []
    assert Enum.all?(session.events, &(&1.tier == :durable))

    # A second turn carries the history forward.
    assert {:ok, _answer2} =
             call("harness_send_prompt", %{
               "session_id" => key,
               "prompt" => "and again",
               "backend" => "mock"
             })

    assert {:ok, session2} = Raxol.Agent.Code.Store.load(ctx.sessions, key)
    assert length(session2.messages) == 4

    assert {:ok, transcript} =
             call("harness_read_transcript", %{"session_id" => key})

    assert transcript =~ "user: hello there"
    assert transcript =~ "user: and again"
  end

  test "an MCP-driven turn preserves the session's title and fork parent",
       ctx do
    {:ok, key} = call("harness_start_session", %{})

    # A /rename'd, forked session: title + parent already on disk.
    {:ok, saved} = Raxol.Agent.Code.Store.load(ctx.sessions, key)

    :ok =
      Raxol.Agent.Code.Store.save(ctx.sessions, key, %{
        messages: saved.messages,
        events: saved.events,
        cwd: saved.cwd,
        title: "titled by rename",
        parent: "sess-parent"
      })

    assert {:ok, _answer} =
             call("harness_send_prompt", %{
               "session_id" => key,
               "prompt" => "hello",
               "backend" => "mock"
             })

    {:ok, after_turn} = Raxol.Agent.Code.Store.load(ctx.sessions, key)
    assert after_turn.title == "titled by rename"
    assert after_turn.parent == "sess-parent"
  end

  test "an unknown session errors instead of minting one" do
    assert {:error, message} =
             call("harness_send_prompt", %{
               "session_id" => "sess-0-0",
               "prompt" => "hi",
               "backend" => "mock"
             })

    assert message =~ "unknown session"
  end

  test "a crafted session id cannot escape the sessions directory" do
    assert {:error, message} =
             call("harness_read_transcript", %{
               "session_id" => "../../etc/passwd"
             })

    assert message =~ ~s(unknown session "passwd")
  end

  test "no provider configured surfaces the actionable resolver error" do
    {:ok, key} = call("harness_start_session", %{})

    assert {:error, message} =
             call("harness_send_prompt", %{
               "session_id" => key,
               "prompt" => "hi"
             })

    assert message =~ "no provider configured"
    assert message =~ "mix raxol.setup"
  end

  test "missing required arguments error by name" do
    assert {:error, message} = call("harness_send_prompt", %{"prompt" => "hi"})
    assert message =~ ~s(missing required argument "session_id")
  end

  test "a concurrent write is refused rather than clobbered", ctx do
    {:ok, key} = call("harness_start_session", %{})

    # What `send_prompt` holds: the session as it read it before running the
    # turn. A save rewrites the WHOLE file, so persisting this blindly after
    # another surface has written would discard that surface's turn.
    {:ok, read_before_turn} = Raxol.Agent.Code.Store.load(ctx.sessions, key)

    :ok =
      Raxol.Agent.Code.Store.save(ctx.sessions, key, %{
        messages: [%{role: :user, content: "from the other surface"}],
        events: [],
        cwd: read_before_turn.cwd
      })

    assert {:error, message} =
             McpTools.persist_turn(
               key,
               read_before_turn,
               [%{role: :user, content: "mine"}],
               %{answer: "mine too", events: []}
             )

    assert message =~ "another surface"

    # The other surface's turn survived.
    {:ok, after_save} = Raxol.Agent.Code.Store.load(ctx.sessions, key)
    assert [%{content: "from the other surface"}] = after_save.messages
  end

  test "an uncontended turn still persists", ctx do
    {:ok, key} = call("harness_start_session", %{})
    {:ok, session} = Raxol.Agent.Code.Store.load(ctx.sessions, key)

    assert {:ok, "answer"} =
             McpTools.persist_turn(
               key,
               session,
               [%{role: :user, content: "q"}],
               %{answer: "answer", events: []}
             )

    {:ok, saved} = Raxol.Agent.Code.Store.load(ctx.sessions, key)
    assert [%{content: "q"}, %{content: "answer"}] = saved.messages
  end

  test "turns run against the session's recorded workspace", ctx do
    # `start_session` records the cwd it was created against; a turn must
    # honor it rather than whatever directory this long-lived server sits in,
    # or a resumed session silently reads a different tree.
    workspace = Path.join(ctx.sessions, "workspace")
    File.mkdir_p!(workspace)

    {:ok, key} = call("harness_start_session", %{})
    {:ok, session} = Raxol.Agent.Code.Store.load(ctx.sessions, key)

    :ok =
      Raxol.Agent.Code.Store.save(ctx.sessions, key, %{
        messages: session.messages,
        events: session.events,
        cwd: workspace
      })

    {:ok, reloaded} = Raxol.Agent.Code.Store.load(ctx.sessions, key)
    assert [context: context] = McpTools.turn_context(reloaded)
    assert context.cwd == workspace

    # A recorded cwd that no longer exists is dropped, not passed on: the fs
    # tools would refuse every path against a missing root. (With no skills
    # configured, dropping it leaves no context at all.)
    File.rm_rf!(workspace)

    refute reloaded
           |> McpTools.turn_context()
           |> Keyword.get(:context, %{})
           |> Map.has_key?(:cwd)
  end
end
