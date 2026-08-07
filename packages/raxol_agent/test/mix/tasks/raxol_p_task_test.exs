defmodule Mix.Tasks.Raxol.PTaskTest do
  # async: false — the no-provider test clears real provider env vars.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  # Flag-surface tests only: nothing here runs a turn. The mix task is a
  # thin shell over `Raxol.Agent.P` and always exits with its return code,
  # so every path is asserted via catch_exit. Provider resolution fails
  # fast inside the runner, before any streamer or signal trap starts.

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

    store =
      Path.join(
        System.tmp_dir!(),
        "raxol-p-task-#{System.unique_integer([:positive])}.json"
      )

    prev_store = System.get_env("RAXOL_PROVIDERS")
    System.put_env("RAXOL_PROVIDERS", store)

    on_exit(fn ->
      File.rm(store)

      if prev_store,
        do: System.put_env("RAXOL_PROVIDERS", prev_store),
        else: System.delete_env("RAXOL_PROVIDERS")

      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, val} -> System.put_env(key, val)
      end)
    end)

    :ok
  end

  test "--help prints usage on stdout and exits 0" do
    out =
      capture_io(fn ->
        assert catch_exit(Mix.Tasks.Raxol.P.run(["--help"])) == {:shutdown, 0}
      end)

    assert out =~ "Usage: raxol p"
    assert out =~ "--backend"
    assert out =~ "--write"
    assert out =~ "Exit codes:"
  end

  test "-h is an alias for --help" do
    out =
      capture_io(fn ->
        assert catch_exit(Mix.Tasks.Raxol.P.run(["-h"])) == {:shutdown, 0}
      end)

    assert out =~ "Usage: raxol p"
  end

  test "an unknown option prints the error plus usage and exits 64" do
    stderr =
      capture_io(:stderr, fn ->
        assert catch_exit(Mix.Tasks.Raxol.P.run(["--bogus", "hi"])) ==
                 {:shutdown, 64}
      end)

    assert stderr =~ ~s(unknown options: [{"--bogus", nil}])
    assert stderr =~ "Usage: raxol p"
  end

  test "a missing prompt prints the error plus usage and exits 64" do
    stderr =
      capture_io(:stderr, fn ->
        assert catch_exit(Mix.Tasks.Raxol.P.run([])) == {:shutdown, 64}
      end)

    assert stderr =~ "no prompt given"
    assert stderr =~ "Usage: raxol p"
  end

  test "no provider configured exits 1 with a setup hint, before boot" do
    stderr =
      capture_io(:stderr, fn ->
        assert catch_exit(Mix.Tasks.Raxol.P.run(["hello"])) == {:shutdown, 1}
      end)

    assert stderr =~ "no provider configured"
    assert stderr =~ "mix raxol.setup"
    assert stderr =~ "--backend lm_studio"
  end
end
