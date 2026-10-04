defmodule Raxol.Agent.SpawnedPortTest.Run do
  @moduledoc false
  import ExUnit.Assertions

  def run(spec) do
    port =
      Port.open(
        {:spawn_executable, spec.path},
        [:binary, :exit_status, :stderr_to_stdout, {:args, spec.args}] ++ spec.opts
      )

    collect(port, [])
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, [acc, data])
      {^port, {:exit_status, status}} -> {IO.iodata_to_binary(acc), status}
    after
      10_000 ->
        Raxol.Agent.SpawnedPort.close(port)
        flunk("spawned target never exited; output so far: #{IO.iodata_to_binary(acc)}")
    end
  end
end

defmodule Raxol.Agent.SpawnedPortTest do
  @moduledoc """
  Contract for the shared close path. Every spawner that kills on a deadline
  reaches `close/1` with a port that has usually already died, so both the
  guard and the drain are load-bearing rather than defensive.
  """

  use ExUnit.Case, async: true

  @moduletag :unix_only

  alias Raxol.Agent.SpawnedPort
  alias Raxol.Agent.SpawnedPortTest.Run

  defp spawn_sh(command) do
    Port.open(
      {:spawn_executable, "/bin/sh"},
      [:binary, :in, :exit_status, {:args, ["-c", command]}]
    )
  end

  test "closing a live port returns :ok" do
    assert :ok = SpawnedPort.close(spawn_sh("sleep 5"))
  end

  test "closing a port that already exited does not raise" do
    port = spawn_sh("exit 3")

    # Consume the status so the port is provably gone before the close --
    # `Port.close/1` raises on a dead port, which is what the guard exists for.
    assert_receive {^port, {:exit_status, 3}}, 5_000

    assert :ok = SpawnedPort.close(port)
  end

  test "an exit status queued before the close is drained, not left behind" do
    port = spawn_sh("exit 0")

    # Wait for the port to die on its own without consuming its message, so
    # `close/1` meets exactly the state a killed process leaves behind.
    wait_until_dead(port)

    assert :ok = SpawnedPort.close(port)
    refute_received {^port, {:exit_status, _}}
  end

  defp wait_until_dead(port, budget_ms \\ 3_000)

  defp wait_until_dead(port, budget_ms) when budget_ms <= 0,
    do: flunk("port #{inspect(port)} never exited")

  defp wait_until_dead(port, budget_ms) do
    if Port.info(port) do
      Process.sleep(25)
      wait_until_dead(port, budget_ms - 25)
    else
      :ok
    end
  end

  describe "spawn_spec/2" do
    # No `:in` on Unix, so a lost redirect leaves `cat` on an open pipe and
    # this hangs into the flunk on every host, tty or not.
    test "a target that drains stdin sees EOF and exits cleanly" do
      spec = SpawnedPort.spawn_spec(System.find_executable("cat"), [])

      assert {output, 0} = Run.run(spec)
      assert SpawnedPort.target_output(output, spec) == {:ok, ""}
    end

    test "the target's stdin is /dev/null, not an inherited fd" do
      spec =
        SpawnedPort.spawn_spec("/bin/sh", [
          "-c",
          "if [ /dev/stdin -ef /dev/null ]; then echo null; else echo other; fi"
        ])

      assert {output, 0} = Run.run(spec)
      assert SpawnedPort.target_output(output, spec) == {:ok, "null\n"}
    end

    test "a leading-dash executable is not parsed as an option by exec" do
      spec = SpawnedPort.spawn_spec("-c", ["echo pwned"])

      assert {output, status} = Run.run(spec)
      assert status in [126, 127]
      refute output =~ "pwned"
    end

    test "a bare executable name is not looked up on PATH" do
      spec = SpawnedPort.spawn_spec("echo", ["resolved"])

      assert {output, status} = Run.run(spec)
      assert status in [126, 127]
      refute output =~ "resolved"
    end

    test "on Windows it is a direct spawn with :in" do
      assert SpawnedPort.spawn_spec("op.exe", ["read"], {:win32, :nt}) ==
               %{path: "op.exe", args: ["read"], opts: [:in], exec_marker: nil}
    end
  end

  describe "target_output/2 and exec_marker_line?/2" do
    setup do
      %{spec: SpawnedPort.spawn_spec("/bin/true", [], {:unix, :darwin})}
    end

    test "drops everything the shell wrote before the marker", %{spec: spec} do
      output = "sh: warning: setlocale: LC_ALL: cannot change locale\n<<raxol:exec>>\nsecret"
      assert SpawnedPort.target_output(output, spec) == {:ok, "secret"}
    end

    test "is :error when the wrapper never reached exec", %{spec: spec} do
      assert SpawnedPort.target_output("sh: fork failed\n", spec) == :error
    end

    test "a direct spec's output is already the target's" do
      spec = SpawnedPort.spawn_spec("op.exe", [], {:win32, :nt})
      assert SpawnedPort.target_output("anything", spec) == {:ok, "anything"}
      refute SpawnedPort.exec_marker_line?("<<raxol:exec>>", spec)
    end

    test "matches the marker line, including one sharing a diagnostic's line", %{spec: spec} do
      assert SpawnedPort.exec_marker_line?("<<raxol:exec>>", spec)
      assert SpawnedPort.exec_marker_line?("sh: warning<<raxol:exec>>", spec)
      refute SpawnedPort.exec_marker_line?("sh: warning", spec)
    end
  end
end

defmodule Raxol.Agent.SpawnedPortEnvTest do
  @moduledoc """
  The wrapper shell's own tracing must not reach the target's output. Mutates
  the BEAM's environment, hence not async.
  """

  use ExUnit.Case, async: false

  @moduletag :unix_only

  alias Raxol.Agent.SpawnedPort

  @vars %{
    "SHELLOPTS" => "braceexpand:hashall:interactive-comments:xtrace",
    "PS4" => "+$(echo leaked) "
  }

  setup do
    previous = Map.new(@vars, fn {k, _} -> {k, System.get_env(k)} end)
    Enum.each(@vars, fn {k, v} -> System.put_env(k, v) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  test "SHELLOPTS=xtrace and PS4 in the BEAM's env do not leak into target_output" do
    spec = SpawnedPort.spawn_spec(System.find_executable("echo"), ["secret"])

    assert {output, 0} = Raxol.Agent.SpawnedPortTest.Run.run(spec)
    assert SpawnedPort.target_output(output, spec) == {:ok, "secret\n"}
    refute output =~ "leaked"
  end
end
