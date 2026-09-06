defmodule Raxol.Agent.CliEntrypointSmokeTest do
  @moduledoc """
  Smoke coverage for the two shell entrypoints that had none: `bin/raxol`
  (one-shot headless run) and `bin/raxol-code` (the interactive TUI). Both are
  launched as REAL subprocesses, the way a human or a benchmark harness invokes
  them, in the spirit of `Raxol.Agent.AcpLoopbackTest` (which does the same for
  `bin/raxol-acp`).

  ## Why a shell script needs a test

  Every defect these scripts have shipped was invisible to the Elixir suite,
  because the suite calls `Raxol.Agent.P.run/1` directly and never goes through
  the shim. The shim is where the process contract lives:

    * `mix <task>` loads the project to find the task module, and that
      loadpaths pass announces dep work on STDOUT (`==> raxol_terminal`,
      `Compiling N files (.ex)`) before the task can install a quiet shell.
      `raxol_terminal`'s `:elixir_make` NIF step never reads as fresh, so this
      is not a first-run-only cost. On `bin/raxol` stdout IS the answer, so
      that chatter corrupted the answer channel; `bin/raxol` used to filter it
      with `grep -v '^==> raxol_terminal$'`, which matched that one exact line
      and let `Compiling N files (.ex)` straight through. Both scripts now run
      the task through `mix run --no-deps-check`, which parses before any
      project loadpaths.
    * that grep filter put the task inside a pipeline, so its exit status had
      to be smuggled out through a temp file. Replacing it with `exec` is the
      kind of change that silently turns every failure into exit 0, so the
      exit code is asserted here, not assumed.
    * `Mix.Tasks.Raxol.P` booted `app.start` before `Raxol.Agent.P` could
      lower the log level, putting the whole startup banner ("Starting in full
      mode", the Endpoint config warning, "Started in ...") on stdout ahead of
      the answer. This test measured that; the task now seeds `:logger` to
      standard_error at level `:error` before boot, the way
      `Mix.Tasks.Raxol.Acp` already did.

  ## How stdout purity is asserted without pinning the answer's wording

  `mix raxol.p` promises stdout = the answer, stderr = one JSON contract event
  per line. Those two channels describe each other: the `item_completed`
  event for the assistant message carries the same text the task printed. So
  the assertion is stdout == the content the event stream reports, which is
  absolute (a single extra byte on stdout fails it) while leaving the mock
  backend free to change its wording. The chatter patterns are asserted
  separately only so a failure names the cause.

  ## What is NOT asserted, and why

  `bin/raxol-code` is a full-screen TUI: with stdout on a pipe it boots,
  renders into the void and never exits, so a test cannot drive it without a
  pty -- and a pty harness here would test the pty, not the shim. This asserts
  the headless path (`--help`), which is the part that answers in-process and
  exits. The alternate-screen handoff under `mix run` was verified by hand
  through a real pty (`ESC[?1049h` + a drawn frame, identical to `mix
  raxol.code` minus the `==> raxol_terminal` line); that is recorded in the
  script's comment rather than faked here.

  No invariant sentinel: these entrypoints run in their own OS processes, so
  their telemetry stays in their own BEAM, where a handler attached here
  cannot see it.

  Run with:
      mix test --include integration test/raxol/agent/cli_entrypoint_smoke_test.exs
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  # Each case boots a full BEAM behind a Mix task, and `setup_all` pre-warms the
  # build they boot from (minutes on a cold tree).
  @moduletag timeout: 900_000

  @agent_dir Path.expand("../../..", __DIR__)
  @repo_root Path.expand("../..", @agent_dir)
  @raxol Path.join(@repo_root, "bin/raxol")
  @raxol_code Path.join(@repo_root, "bin/raxol-code")

  # Lines that may never reach a channel a caller parses.
  @chatter [
    ~r/^==> /m,
    ~r/^Compiling \d+ files?/m,
    ~r/\[(?:debug|info|notice|warning|error)\]/
  ]

  setup_all do
    for script <- [@raxol, @raxol_code] do
      unless File.exists?(script), do: flunk("entrypoint missing: #{script}")
    end

    # WHY pre-warm: both scripts compile quietly before handing off, and on a
    # cold tree that step is minutes. Doing it here turns "the build was cold or
    # broken" into an explicit setup failure carrying the compiler's own output
    # instead of an unexplained timeout inside a test. `mix` resolves from this
    # BEAM's environment, exactly as the spawned scripts resolve it.
    {output, status} =
      System.cmd("mix", ["compile"],
        cd: @agent_dir,
        env: [{"MIX_ENV", "dev"}, {"MAKEFLAGS", "-s"}],
        stderr_to_stdout: true
      )

    if status != 0 do
      flunk("""
      the CLI entrypoints cannot boot: `MIX_ENV=dev mix compile` failed in #{@agent_dir}

      #{String.slice(output, -4_000, 4_000)}
      """)
    end

    :ok
  end

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "raxol_cli_smoke_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, cwd: tmp}
  end

  describe "bin/raxol" do
    test "answers a mock-backed prompt on stdout and puts nothing else there", %{cwd: cwd} do
      prompt = "smoke: name one file"

      run = run_cli(@raxol, ["--backend", "mock", "-p", prompt], cwd)

      assert run.status == 0, """
      bin/raxol exited #{run.status}
      #{report(run)}
      """

      # The event stream is the independent description of what the answer was,
      # so stdout can be pinned exactly without pinning the mock's wording.
      answer = assistant_answer!(run)

      assert String.trim(run.out) == answer
      assert run.out == answer <> "\n"
    end

    test "keeps the prompt one argument when other flags carry spaces", %{cwd: cwd} do
      prompt = "smoke: the whole prompt"

      run =
        run_cli(
          @raxol,
          ["--backend", "mock", "--system", "be very terse", "-p", prompt],
          cwd
        )

      assert run.status == 0, report(run)

      # The shim peels `-p PROMPT` out of the argument list itself. Accumulating
      # the rest into a string (what the rotation idiom replaced) re-split
      # `--system "be very terse"` on spaces, so `terse` arrived as a positional
      # argument and `Raxol.Agent.P` joined it INTO the prompt.
      assert %{"prompt" => ^prompt} = turn_started_payload!(run)
    end

    test "propagates a non-zero task exit and keeps stdout empty", %{cwd: cwd} do
      run = run_cli(@raxol, ["--bogus-flag", "-p", "smoke: unreachable"], cwd)

      # 64, not merely non-zero: the shim now `exec`s the task instead of
      # piping it, and the exact code is what the replaced temp file existed to
      # preserve.
      assert run.status == 64, report(run)
      assert run.out == ""
      assert run.err =~ "unknown options"
    end

    test "rejects a missing prompt before booting anything", %{cwd: cwd} do
      run = run_cli(@raxol, ["--backend", "mock"], cwd)

      assert run.status == 64, report(run)
      assert run.err =~ ~s(missing -p)
      assert run.out == ""
    end
  end

  describe "bin/raxol-code" do
    test "prints usage and exits 0 with no terminal attached", %{cwd: cwd} do
      run = run_cli(@raxol_code, ["--help"], cwd)

      assert run.status == 0, report(run)
      assert run.out =~ "Usage: raxol code"
      assert run.out =~ "--sessions"
    end
  end

  # ==========================================================================
  # Subprocess plumbing
  # ==========================================================================

  # `System.cmd/3` can either capture stdout alone (leaving stderr on the
  # runner's own console) or merge the two -- and this test needs them SEPARATE
  # and both captured, since the whole contract is which line goes where. So
  # the script runs under `sh -c` with stderr redirected to a file.
  defp run_cli(script, args, cwd) do
    err_path = Path.join(cwd, "stderr-#{System.unique_integer([:positive])}.log")

    command =
      [script | args]
      |> Enum.map_join(" ", &shell_quote/1)
      |> Kernel.<>(" 2>#{shell_quote(err_path)}")

    {out, status} =
      System.cmd("sh", ["-c", command],
        cd: cwd,
        env: [
          # The scripts set no MIX_ENV, so dev is what a human gets and dev is
          # what setup_all pre-warmed; inheriting `test` from the runner would
          # send them to a different build tree and a different config.
          {"MIX_ENV", "dev"},
          {"MAKEFLAGS", "-s"},
          # A separate OS process needs its own journal redirect; test_helper's
          # applies to this BEAM only.
          {"RAXOL_SESSIONS_DIR", Path.join(cwd, "sessions")}
        ],
        stderr_to_stdout: false
      )

    run = %{
      out: out,
      err: File.read!(err_path),
      status: status,
      command: command
    }

    for pattern <- @chatter do
      refute Regex.match?(pattern, run.out), """
      build chatter reached stdout, which callers parse as the answer:
      #{inspect(pattern)}
      #{report(run)}
      """
    end

    run
  end

  defp shell_quote(arg), do: "'" <> String.replace(arg, "'", ~S('\'')) <> "'"

  # The last completed assistant message in the JSONL event stream -- the
  # task's own account of what it printed.
  defp assistant_answer!(run) do
    run
    |> events()
    |> Enum.filter(
      &match?(%{"type" => "item_completed", "payload" => %{"item_type" => "message"}}, &1)
    )
    |> List.last()
    |> case do
      %{"payload" => %{"content" => content}} when is_binary(content) and content != "" ->
        content

      other ->
        flunk("""
        no completed assistant message on the event stream (got #{inspect(other)})
        #{report(run)}
        """)
    end
  end

  defp turn_started_payload!(run) do
    case Enum.find(events(run), &match?(%{"type" => "turn_started"}, &1)) do
      %{"payload" => payload} -> payload
      nil -> flunk("no turn_started event\n#{report(run)}")
    end
  end

  # stderr is the machine-readable channel: every line must be one JSON event.
  # A non-JSON line here is itself a defect, so it fails rather than being
  # skipped.
  defp events(run) do
    run.err
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case Jason.decode(line) do
        {:ok, event} -> event
        {:error, _} -> flunk("non-JSON line on the event stream: #{inspect(line)}")
      end
    end)
  end

  defp report(run) do
    """
    command: #{run.command}
    exit:    #{run.status}
    stdout:  #{inspect(run.out)}
    stderr:  #{inspect(String.slice(run.err, 0, 4_000))}
    """
  end
end
