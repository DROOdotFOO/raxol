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

  test "send_prompt runs a turn, persists history, and stays TUI-resumable", ctx do
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
    assert [%{role: :user, content: "hello there"}, %{role: :assistant}] = session.messages
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
end
