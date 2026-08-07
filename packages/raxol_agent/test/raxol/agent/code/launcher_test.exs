defmodule Raxol.Agent.Code.LauncherTest do
  # async: false — tests swap RAXOL_CODE_SESSIONS and provider env vars.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Raxol.Agent.Code.Launcher

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
        "raxol-launcher-#{System.unique_integer([:positive])}"
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

    :ok
  end

  test "--help prints usage and returns 0 without booting" do
    out =
      capture_io(fn ->
        assert Launcher.main(["--help"], boot: fn -> flunk("boot ran") end) == 0
      end)

    assert out =~ "Usage: raxol code"
    assert out =~ "--resume ID"
  end

  test "an unknown option prints the error plus usage and returns 64" do
    stderr =
      capture_io(:stderr, fn ->
        assert Launcher.main(["--bogus"], boot: fn -> flunk("boot ran") end) ==
                 64
      end)

    assert stderr =~ "unknown options"
    assert stderr =~ "Usage: raxol code"
  end

  test "an unknown backend errors before the boot step runs" do
    stderr =
      capture_io(:stderr, fn ->
        assert Launcher.main(["--backend", "nonsense"],
                 boot: fn -> flunk("boot ran") end
               ) == 64
      end)

    assert stderr =~ ~s(unknown backend "nonsense")
  end

  test "--sessions lists the store and returns 0 without booting" do
    out =
      capture_io(fn ->
        assert Launcher.main(["--sessions"], boot: fn -> flunk("boot ran") end) ==
                 0
      end)

    assert out =~ "no saved sessions"
  end

  test "a boot veto prints the message and returns 1, before any UI" do
    stderr =
      capture_io(:stderr, fn ->
        assert Launcher.main(["--backend", "mock"],
                 boot: fn -> {:error, "needs a real terminal"} end
               ) == 1
      end)

    assert stderr =~ "raxol code: needs a real terminal"
  end
end
