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

  describe "--ssh" do
    test "without --authorized-keys is a fail-closed usage error" do
      stderr =
        capture_io(:stderr, fn ->
          assert Launcher.main(["--ssh"], boot: fn -> flunk("boot ran") end) ==
                   64
        end)

      assert stderr =~ "--authorized-keys"
      assert stderr =~ "never serves anonymously"
    end

    test "rejects --resume: sessions are per-connection" do
      stderr =
        capture_io(:stderr, fn ->
          assert Launcher.main(
                   ["--ssh", "--authorized-keys", "/tmp/k", "--resume", "s1"],
                   boot: fn -> flunk("boot ran") end
                 ) == 64
        end)

      assert stderr =~ "fresh session"
    end

    test "serves Code.App with the resolved app opts and blocks on the server" do
      test_pid = self()

      serve = fn app, opts ->
        send(test_pid, {:served, app, opts})
        # A server that exits immediately, so main/2 returns instead of
        # blocking the test.
        {:ok, spawn(fn -> :ok end)}
      end

      out =
        capture_io(fn ->
          assert Launcher.main(
                   [
                     "--ssh",
                     "--authorized-keys",
                     "/tmp/keys",
                     "--ssh-port",
                     "2200",
                     "--backend",
                     "mock"
                   ],
                   boot: fn -> :ok end,
                   serve: serve
                 ) == 0
        end)

      assert out =~ "port 2200"
      assert_received {:served, Raxol.Agent.Code.App, opts}
      assert opts[:port] == 2200
      assert opts[:authorized_keys_dir] == "/tmp/keys"
      assert opts[:app_opts][:provider_status] == {:ready, :mock, :explicit}
      refute Keyword.has_key?(opts[:app_opts], :session_key)
    end

    test "the resolved executor never leaks its api key through app_opts inspect" do
      System.put_env("ANTHROPIC_API_KEY", "sk-secret-leak-probe")
      on_exit(fn -> System.delete_env("ANTHROPIC_API_KEY") end)

      serve = fn _app, opts ->
        send(self(), {:opts, opts}) && {:ok, spawn(fn -> :ok end)}
      end

      capture_io(fn ->
        Launcher.main(
          ["--ssh", "--authorized-keys", "/tmp/k", "--backend", "anthropic"],
          boot: fn -> :ok end,
          serve: serve
        )
      end)

      assert_received {:opts, opts}
      executor = opts[:app_opts][:executor]
      # The key resolved into the executor's auth, but inspect must not show it.
      assert executor.auth == %{api_key: "sk-secret-leak-probe"}
      refute inspect(opts) =~ "sk-secret-leak-probe"
      refute inspect(executor) =~ "sk-secret-leak-probe"
    end

    test "a serve failure prints the reason and returns 1" do
      stderr =
        capture_io(:stderr, fn ->
          assert Launcher.main(
                   [
                     "--ssh",
                     "--authorized-keys",
                     "/tmp/k",
                     "--backend",
                     "mock"
                   ],
                   boot: fn -> :ok end,
                   serve: fn _app, _opts -> {:error, :eaddrinuse} end
                 ) == 1
        end)

      assert stderr =~ "eaddrinuse"
    end
  end
end
