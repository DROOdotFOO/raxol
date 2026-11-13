defmodule Raxol.Journal.Test.ForeignBeam do
  @moduledoc """
  A second BEAM OS process with every application built beside
  `raxol_journal` on its path, for tests of the journal's cross-process writer
  lock: a holder that is really another BEAM.

  It lives until its port closes (it reads its stdin to the end), so it ends
  with the test process that started it. `start_supervised/2` also kills it
  when the test exits, which covers a BEAM stuck before it reads.

  For ExUnit suites: `start_supervised/2` registers an `on_exit` callback, so
  it is called from a test process. Nothing else in this package calls this
  module.
  """

  @type t :: %{port: port(), pid: String.t()}

  @start_ms 60_000

  @doc """
  `start/2`, and the BEAM is killed when the calling test exits.
  """
  @spec start_supervised(String.t(), String.t() | nil) :: t()
  def start_supervised(setup \\ ":ok", on_go \\ nil) do
    beam = start(setup, on_go)
    ExUnit.Callbacks.on_exit(fn -> signal(beam) end)
    beam
  end

  @doc """
  Start a BEAM that evaluates `setup` (Elixir source) and then waits. Returns
  once `setup` has run; `pid` is its OS pid. With `on_go` (Elixir source) it
  evaluates that when `go/1` is called; what `on_go` prints, a line at a time,
  is read with `lines_until/2`.
  """
  @spec start(String.t(), String.t() | nil) :: t()
  def start(setup \\ ":ok", on_go \\ nil) do
    script = """
    {:ok, _} = Application.ensure_all_started(:logger)
    #{setup}
    IO.puts("ready " <> System.pid())
    #{if on_go, do: "IO.read(:stdio, :line)\n" <> on_go, else: ""}
    IO.read(:stdio, :eof)
    """

    code_paths =
      :raxol_journal
      |> Application.app_dir()
      |> Path.dirname()
      |> Path.join("*/ebin")
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
      {^port, {:data, {:eol, "ready " <> pid}}} ->
        %{port: port, pid: pid}

      {^port, {:exit_status, status}} ->
        raise "the foreign BEAM exited with #{status}"
    after
      @start_ms ->
        # Not ready, so its pid was never printed: the port knows it.
        with {:os_pid, os_pid} <- Port.info(port, :os_pid),
             do: signal(%{pid: Integer.to_string(os_pid)})

        raise "the foreign BEAM did not start"
    end
  end

  @doc "The OS pid of a process that has exited and been reaped."
  @spec dead_pid() :: String.t()
  def dead_pid do
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        {:line, 64},
        args: ["-c", "echo $$"]
      ])

    pid =
      receive do
        {^port, {:data, {:eol, pid}}} -> pid
      after
        5_000 -> raise "the short-lived process printed no pid"
      end

    receive do
      {^port, {:exit_status, _status}} -> pid
    after
      5_000 -> raise "the short-lived process did not exit"
    end
  end

  @doc "Let a BEAM started with `on_go` run it."
  @spec go(t()) :: :ok
  def go(%{port: port}) do
    Port.command(port, "go\n")
    :ok
  end

  @doc "The lines the BEAM printed, up to and excluding the line `last`."
  @spec lines_until(t(), String.t()) :: [String.t()]
  def lines_until(%{port: port} = beam, last, lines \\ []) do
    receive do
      {^port, {:data, {:eol, ^last}}} -> Enum.reverse(lines)
      {^port, {:data, {:eol, line}}} -> lines_until(beam, last, [line | lines])
      {^port, {:exit_status, status}} -> raise "the foreign BEAM exited with #{status}"
    after
      @start_ms -> raise "the foreign BEAM never printed #{inspect(last)}"
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
  @spec signal(%{pid: String.t()}) :: :ok
  def signal(%{pid: pid}) do
    _ = System.cmd("kill", ["-9", pid], stderr_to_stdout: true)
    :ok
  end
end
