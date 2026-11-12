defmodule Raxol.Agent.ForeignBeam do
  @moduledoc """
  A second BEAM OS process with this project's code on its path, for tests of
  the journal's cross-process writer lock: a holder that is really another
  BEAM, alive until it is killed.
  """

  @type t :: %{port: port(), pid: String.t()}

  @doc """
  Start a BEAM that evaluates `setup` (Elixir source, default nothing) and
  then stays alive. Returns once `setup` has run. `pid` is its OS pid.
  """
  @spec start(String.t()) :: t()
  def start(setup \\ ":ok") do
    script = """
    {:ok, _} = Application.ensure_all_started(:logger)
    #{setup}
    IO.puts("ready " <> System.pid())
    Process.sleep(:infinity)
    """

    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(&["-pa", &1])

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        {:line, 4096},
        args: code_paths ++ ["-e", script]
      ])

    receive do
      {^port, {:data, {:eol, "ready " <> pid}}} -> %{port: port, pid: pid}
      {^port, {:exit_status, status}} -> raise "the foreign BEAM exited with #{status}"
    after
      60_000 -> raise "the foreign BEAM did not start"
    end
  end

  @doc "Kill the BEAM (SIGKILL, so nothing it holds is released) and wait for its exit."
  @spec kill(t()) :: :ok
  def kill(%{port: port, pid: pid} = beam) do
    signal(beam)

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      10_000 -> raise "the foreign BEAM #{pid} did not exit"
    end
  end

  @doc "SIGKILL without waiting, for a process that does not own the port (`on_exit`)."
  @spec signal(t()) :: :ok
  def signal(%{pid: pid}) do
    _ = System.cmd("kill", ["-9", pid], stderr_to_stdout: true)
    :ok
  end
end
