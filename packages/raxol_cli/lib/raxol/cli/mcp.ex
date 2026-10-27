defmodule Raxol.CLI.MCP do
  @moduledoc """
  `raxol mcp`: Raxol apps as MCP tools over stdio, for OMP and any other MCP
  client that spawns its servers.

      raxol mcp [--expect-version X] [--no-derived] [--bench-dump PATH]

    * `--expect-version X` -- refuse to serve unless this binary is version
      `X` (a `+<commit>` build stamp is ignored), so a plugin pinned to one
      release never talks to another.
    * `--no-derived` -- serve the static tools only: a session's derived
      widget tools are neither listed nor callable.
    * `--bench-dump PATH` -- at end of input, write every running session's
      model to `PATH` as `:erlang.term_to_binary(%{session_id => model})`.

  ## Boot

  The release starts every application before `Raxol.CLI.main/1` runs, so
  how `raxol mcp` boots is decided earlier, by the one predicate in
  `config/runtime.exs` (`RAXOL_MODE=mcp`, or the Burrito binary run as
  `raxol mcp`). It starts `:raxol` in `:mcp` mode with the two authorizers
  below, leaves out the coding-agent harness tools, reports this binary's
  version as `serverInfo.version`, and points every later application's
  group leader at stderr. `run/1` refuses to serve when that predicate did
  not fire, and when `RAXOL_CLI_INSTALL_DIR` is set (Burrito's launcher then
  prints to stdout before the VM starts).

  ## Wire

  stdout carries JSON-RPC and nothing else. The transport reads and writes
  the `user` device (not a `{:fd, 0, 1}` port, which loses stdin that arrives
  before it opens under `-noshell`). Logs go to stderr.

  ## End of input

  The transport cancels every request still running and stops once nothing
  is outstanding. Then `run/1` writes the `--bench-dump` file, gives every
  agent journal writer 500 ms in total to flush, and returns 0, which the
  release turns into `System.halt(0)`.
  """

  alias Raxol.Agent.Journal.FileStore.Writer
  alias Raxol.MCP.Transport.Stdio

  @switches [expect_version: :string, no_derived: :boolean, bench_dump: :string]

  @listing_methods ~w(tools/list resources/list prompts/list)

  @journal_flush_ms 500

  @doc "Serve MCP on stdio until end of input. Returns the exit code."
  @spec run([String.t()]) :: non_neg_integer()
  def run(args) do
    with :ok <- refuse_install_dir(),
         {:ok, opts} <- parse(args),
         :ok <- check_boot(),
         :ok <- check_version(Keyword.get(opts, :expect_version)) do
      serve(opts)
    else
      {:error, code, message} -> refuse(code, message)
    end
  end

  @doc """
  The tool authorizer (`config :raxol, :mcp_authorizer`).

  Allows every registered tool, except `raxol_start` given a `"path"`
  (starting from a path compiles the file, which runs code the client chose)
  and, under `--no-derived`, every tool that is not static. Answers only
  `:allow` or `{:deny, reason}`.
  """
  @spec authorize(String.t(), map(), map()) :: :allow | {:deny, String.t()}
  def authorize("raxol_start", %{"path" => _}, _ctx),
    do: {:deny, "raxol mcp starts sessions from \"module\" only; \"path\" is refused"}

  def authorize(tool, _arguments, _ctx) do
    if Application.get_env(:raxol_cli, :mcp_no_derived, false) and not static_tool?(tool),
      do: {:deny, "this server serves static tools only (raxol mcp --no-derived)"},
      else: :allow
  end

  @doc """
  The read authorizer (`config :raxol, :mcp_read_authorizer`).

  Allows the listing methods (`tools/list`, `resources/list`,
  `prompts/list`), and `resources/read` of `raxol://session/<id>` and the
  URIs under it for a session running in this VM: `raxol mcp` is its own OS
  process, and the only thing in it that starts sessions is `raxol_start`
  on this server. Every other read is denied.
  """
  @spec authorize_read(String.t(), map(), map()) :: :allow | {:deny, String.t()}
  def authorize_read(method, _detail, _ctx) when method in @listing_methods, do: :allow

  def authorize_read("resources/read", %{"uri" => "raxol://session/" <> rest}, _ctx) do
    [id | _] = String.split(rest, "/", parts: 2)

    if id in Raxol.Headless.list(),
      do: :allow,
      else: {:deny, "no session #{inspect(id)} was started by this server"}
  end

  def authorize_read(method, _detail, _ctx),
    do: {:deny, "raxol mcp serves #{method} only for the sessions it started"}

  # -- run ----------------------------------------------------------------------

  defp refuse_install_dir do
    if System.get_env("RAXOL_CLI_INSTALL_DIR") == nil,
      do: :ok,
      else:
        {:error, 1,
         "RAXOL_CLI_INSTALL_DIR is set, and the launcher then writes to stdout, " <>
           "which is the MCP wire; unset it"}
  end

  defp parse(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        {:ok, opts}

      {_opts, rest, invalid} ->
        unknown = Enum.map(invalid, &elem(&1, 0)) ++ rest

        {:error, 64,
         "unknown arguments #{Enum.join(unknown, " ")}; usage: raxol mcp " <>
           "[--expect-version X] [--no-derived] [--bench-dump PATH]"}
    end
  end

  defp check_boot do
    if Application.get_env(:raxol_cli, :mcp_boot, false),
      do: :ok,
      else:
        {:error, 1,
         "the VM did not boot for MCP (stdout would not be clean and no tool " <>
           "would be authorized); run it with RAXOL_MODE=mcp"}
  end

  defp check_version(nil), do: :ok

  defp check_version(expected) do
    actual = Raxol.CLI.version()

    if actual == expected or String.starts_with?(actual, expected <> "+"),
      do: :ok,
      else: {:error, 1, "this is raxol #{actual}, not the expected #{expected}"}
  end

  defp refuse(code, message) do
    IO.puts(:stderr, "raxol mcp: " <> message)
    code
  end

  # Read by `authorize/3`. Set before the transport reads its first line.
  defp serve(opts) do
    Application.put_env(:raxol_cli, :mcp_no_derived, Keyword.get(opts, :no_derived, false))

    # The transport is linked; trapping turns its crash into the DOWN below
    # and an exit code, instead of a crash of the release's start.
    Process.flag(:trap_exit, true)

    case Stdio.start_link(server: Raxol.MCP.Server, io_device: :user, output_device: :user) do
      {:ok, transport} -> await(transport, opts)
      {:error, reason} -> refuse(1, "the stdio transport did not start: #{inspect(reason)}")
    end
  end

  defp await(transport, opts) do
    ref = Process.monitor(transport)

    receive do
      {:DOWN, ^ref, :process, ^transport, :normal} ->
        finish(Keyword.get(opts, :bench_dump))

      {:DOWN, ^ref, :process, ^transport, reason} ->
        refuse(1, "the stdio transport stopped: #{inspect(reason)}")
    end
  end

  defp finish(bench_dump) do
    result = dump_models(bench_dump)
    flush_journals()

    case result do
      :ok -> 0
      {:error, code, message} -> refuse(code, message)
    end
  end

  defp dump_models(nil), do: :ok

  defp dump_models(path) do
    models =
      for id <- Raxol.Headless.list(),
          {:ok, model} <- [Raxol.Headless.get_model(id)],
          into: %{},
          do: {id, model}

    case File.write(path, :erlang.term_to_binary(models)) do
      :ok -> :ok
      {:error, reason} -> {:error, 1, "--bench-dump #{path}: #{:file.format_error(reason)}"}
    end
  end

  # One budget for every writer, not one each: OMP gives the server about a
  # second after closing its stdin before it kills it.
  defp flush_journals do
    tasks =
      for {Writer, _dir} = name <- :global.registered_names(),
          pid = :global.whereis_name(name),
          is_pid(pid),
          do: Task.async(fn -> flush_writer(pid) end)

    for {task, nil} <- Task.yield_many(tasks, @journal_flush_ms),
        do: Task.shutdown(task, :brutal_kill)

    :ok
  end

  defp flush_writer(pid) do
    Writer.flush(pid)
  catch
    :exit, _ -> :ok
  end

  defp static_tool?(name) do
    Enum.any?(Raxol.MCP.Registry.static_tools(), fn tool ->
      (Map.get(tool, :name) || Map.get(tool, "name")) == name
    end)
  end
end
