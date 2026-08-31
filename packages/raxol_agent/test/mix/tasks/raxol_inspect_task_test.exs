defmodule Mix.Tasks.Raxol.InspectTaskTest do
  # async: false — the task resolves the workspace via RAXOL_CLI_CWD and the
  # session store via RAXOL_CODE_SESSIONS; both are swapped in setup.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    cwd =
      Path.join(
        System.tmp_dir!(),
        "raxol-inspect-task-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(cwd)
    sessions = Path.join(cwd, "sessions")
    File.mkdir_p!(sessions)

    saved = %{
      "RAXOL_CLI_CWD" => System.get_env("RAXOL_CLI_CWD"),
      "RAXOL_CODE_SESSIONS" => System.get_env("RAXOL_CODE_SESSIONS")
    }

    System.put_env("RAXOL_CLI_CWD", cwd)
    System.put_env("RAXOL_CODE_SESSIONS", sessions)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, val} -> System.put_env(key, val)
      end)

      File.rm_rf(cwd)
    end)

    %{cwd: cwd}
  end

  test "--help prints usage and exits 0" do
    out = capture_io(fn -> assert :ok = Mix.Tasks.Raxol.Inspect.run(["--help"]) end)
    assert out =~ "Usage: mix raxol.inspect"
    assert out =~ "--json"
  end

  test "an unknown option prints the error plus usage and exits 64" do
    stderr =
      capture_io(:stderr, fn ->
        assert catch_exit(Mix.Tasks.Raxol.Inspect.run(["--bogus"])) ==
                 {:shutdown, 64}
      end)

    assert stderr =~ "unknown options"
    assert stderr =~ "Usage: mix raxol.inspect"
  end

  test "prints the human snapshot for the workspace", ctx do
    out = capture_io(fn -> Mix.Tasks.Raxol.Inspect.run([]) end)

    assert out =~ "inspecting: #{ctx.cwd}"
    assert out =~ "providers (op CLI:"
    assert out =~ "sessions:"
  end

  test "--json prints one decodable JSON object", ctx do
    out = capture_io(fn -> Mix.Tasks.Raxol.Inspect.run(["--json"]) end)

    decoded = Jason.decode!(out)

    assert decoded["cwd"] == ctx.cwd

    assert Map.keys(decoded) |> Enum.sort() ==
             ~w(cwd hooks instructions lsp mcp_servers project provider sessions skills)
  end
end
