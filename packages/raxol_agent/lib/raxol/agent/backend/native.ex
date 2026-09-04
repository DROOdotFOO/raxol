defmodule Raxol.Agent.Backend.Native do
  @moduledoc """
  Generic `Raxol.Agent.AIBackend` runtime for native CLI harnesses.

  Spawns a `Raxol.Agent.NativeHarness` driver's CLI via a Port, streams its
  normalized events, and adapts them to the AIBackend stream shape
  (`{:chunk, text}` / `{:done, response}`). Because the CLI owns its own agent
  loop, backends built here report `handles_tools_internally? == true`, and the
  agent's tools are injected into the CLI over MCP (see
  `Raxol.Agent.Harness.McpToolConfig`).

  Define a per-vendor backend with the `__using__/1` macro:

      defmodule Raxol.Agent.Backend.ClaudeCode do
        use Raxol.Agent.Backend.Native, driver: Raxol.Agent.Harness.ClaudeCode
      end

  ## Backend options

  - `:model` -- model id (or omit for the CLI default).
  - `:system_prompt` -- appended system prompt.
  - `:cwd` -- working directory for the CLI.
  - `:timeout` -- per-run timeout in ms (default 120s).
  - `:actions` -- Action modules to expose to the CLI as MCP tools.
  - `:mcp_server_command` / `:mcp_server_args` -- the MCP server launcher; tools
    are injected only when this is set (and `:actions` is non-empty).
  - `:extra_args` -- raw argv appended to the CLI invocation.
  """

  @default_timeout 120_000
  @line_bytes 1_048_576

  alias Raxol.Agent.Harness.McpToolConfig
  alias Raxol.Agent.NativeHarness

  @doc false
  defmacro __using__(macro_opts) do
    driver = Keyword.fetch!(macro_opts, :driver)

    quote bind_quoted: [driver: driver] do
      @behaviour Raxol.Agent.AIBackend
      @native_driver driver

      @impl true
      def complete(messages, opts \\ []),
        do: Raxol.Agent.Backend.Native.complete(@native_driver, messages, opts)

      @impl true
      def stream(messages, opts \\ []),
        do: Raxol.Agent.Backend.Native.stream(@native_driver, messages, opts)

      @impl true
      def available?, do: Raxol.Agent.NativeHarness.available?(@native_driver)

      @impl true
      def name, do: @native_driver.name()

      @impl true
      def capabilities, do: [:completion, :streaming, :tool_use]

      @impl true
      def handles_tools_internally?, do: true

      @doc "The native harness driver backing this backend."
      def driver, do: @native_driver
    end
  end

  # -- Runtime ----------------------------------------------------------------

  @doc "Run one turn and return the final response (drains the stream)."
  @spec complete(module(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def complete(driver, messages, opts) do
    case stream(driver, messages, opts) do
      {:ok, events} -> collect(events)
      {:error, _} = error -> error
    end
  end

  @doc "Run one turn and return `{:ok, stream}` of AIBackend stream events."
  @spec stream(module(), [map()], keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(driver, messages, opts) do
    case System.find_executable(driver.executable()) do
      nil ->
        {:error, {:executable_not_found, driver.executable()}}

      exe ->
        {mcp_path, cleanup} = maybe_build_mcp_config(driver, opts)
        config = run_config(messages, opts, mcp_path)
        args = driver.args(config)
        {:ok, build_stream(driver, exe, args, opts, cleanup)}
    end
  end

  # -- Stream plumbing --------------------------------------------------------

  defp build_stream(driver, exe, args, opts, cleanup) do
    cwd = Keyword.get(opts, :cwd)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    caller = self()
    ref = make_ref()

    reader =
      spawn_link(fn ->
        run_port(exe, args, cwd, driver, timeout, caller, ref)
      end)

    Stream.resource(
      fn -> %{ref: ref, reader: reader, done: false} end,
      &next_event/1,
      fn _ ->
        if Process.alive?(reader), do: Process.exit(reader, :normal)
        cleanup.()
      end
    )
  end

  defp next_event(%{done: true} = state), do: {:halt, state}

  defp next_event(%{ref: ref} = state) do
    receive do
      {^ref, {:done, _} = event} -> {[event], %{state | done: true}}
      {^ref, {:error, _} = event} -> {[event], %{state | done: true}}
      {^ref, event} -> {[event], state}
    end
  end

  # `:in` makes the port input-only, so the CLI's stdin is closed instead of
  # inheriting a write pipe this module never writes to. Nothing here calls
  # `Port.command/2` -- the prompt goes over argv, built by `driver.args/1` --
  # so an open pipe carries nothing and only ever signals "more input is
  # coming". A CLI that reads stdin before doing its work then blocks until the
  # run times out, having produced nothing. The one case `:in` would break is a
  # child whose parent-death signal is EOF on stdin, which needs a pipe held
  # open; no driver here works that way.
  defp run_port(exe, args, cwd, driver, timeout, caller, ref) do
    port =
      Port.open(
        {:spawn_executable, exe},
        [
          :binary,
          :in,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          {:line, @line_bytes},
          {:args, args}
        ] ++ cd_opt(cwd)
      )

    drain(port, driver, timeout, caller, ref, %{buffer: "", content: "", usage: %{}, done: false})
  end

  defp drain(port, driver, timeout, caller, ref, state) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = state.buffer <> chunk
        state = handle_line(driver, line, caller, ref, %{state | buffer: ""})
        if state.done, do: close(port), else: drain(port, driver, timeout, caller, ref, state)

      {^port, {:data, {:noeol, chunk}}} ->
        drain(port, driver, timeout, caller, ref, %{state | buffer: state.buffer <> chunk})

      {^port, {:exit_status, status}} ->
        finalize_exit(status, state, caller, ref)
    after
      timeout ->
        close(port)
        send(caller, {ref, {:error, :timeout}})
    end
  end

  defp handle_line(driver, line, caller, ref, state) do
    driver.parse_line(line)
    |> Enum.reduce(state, fn event, acc -> apply_event(event, caller, ref, acc) end)
  end

  defp apply_event(_event, _caller, _ref, %{done: true} = state), do: state

  defp apply_event({:text, text}, caller, ref, state) do
    send(caller, {ref, {:chunk, text}})
    %{state | content: state.content <> text}
  end

  defp apply_event({:reasoning, _text}, _caller, _ref, state), do: state
  defp apply_event({:tool_call, _info}, _caller, _ref, state), do: state

  defp apply_event({:done, %{content: content, usage: usage}}, caller, ref, state) do
    final = if content == "", do: state.content, else: content
    send(caller, {ref, {:done, response(final, usage)}})
    %{state | done: true}
  end

  defp apply_event({:error, reason}, caller, ref, state) do
    send(caller, {ref, {:error, reason}})
    %{state | done: true}
  end

  # Driver never emitted a terminal :done -- synthesize one from accumulated text
  # on a clean exit, or surface a non-zero exit as an error.
  defp finalize_exit(_status, %{done: true}, _caller, _ref), do: :ok

  defp finalize_exit(0, state, caller, ref) do
    send(caller, {ref, {:done, response(state.content, state.usage)}})
  end

  defp finalize_exit(status, _state, caller, ref) do
    send(caller, {ref, {:error, {:exit, status}}})
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp response(content, usage) do
    %{content: content, usage: usage, metadata: %{backend: :native}}
  end

  # -- complete/2 drain -------------------------------------------------------

  defp collect(events) do
    Enum.reduce_while(events, {:ok, %{content: "", usage: %{}, metadata: %{backend: :native}}}, fn
      {:chunk, _text}, acc ->
        {:cont, acc}

      {:done, response}, _acc ->
        {:halt, {:ok, response}}

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}

      _other, acc ->
        {:cont, acc}
    end)
  end

  # -- run config + MCP injection ---------------------------------------------

  defp run_config(messages, opts, mcp_path) do
    %{
      prompt: prompt_from(messages),
      model: Keyword.get(opts, :model),
      system_prompt: system_prompt_from(messages, opts),
      mcp_config_path: mcp_path,
      cwd: Keyword.get(opts, :cwd),
      extra_args: Keyword.get(opts, :extra_args, [])
    }
  end

  defp prompt_from(messages) do
    messages
    |> Enum.filter(&(role(&1) == :user))
    |> Enum.map_join("\n\n", &content_of/1)
  end

  defp system_prompt_from(messages, opts) do
    case Keyword.get(opts, :system_prompt) do
      sp when is_binary(sp) and sp != "" ->
        sp

      _ ->
        messages
        |> Enum.filter(&(role(&1) == :system))
        |> Enum.map_join("\n\n", &content_of/1)
        |> blank_to_nil()
    end
  end

  defp role(%{role: r}), do: normalize_role(r)
  defp role(%{"role" => r}), do: normalize_role(r)
  defp role(_), do: :user

  defp normalize_role(r) when is_atom(r), do: r
  defp normalize_role("system"), do: :system
  defp normalize_role("assistant"), do: :assistant
  defp normalize_role(_), do: :user

  defp content_of(%{content: c}), do: to_string(c)
  defp content_of(%{"content" => c}), do: to_string(c)
  defp content_of(_), do: ""

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(other), do: other

  # Build the --mcp-config artifact when actions + a server command are supplied.
  defp maybe_build_mcp_config(driver, opts) do
    actions = Keyword.get(opts, :actions, [])
    command = Keyword.get(opts, :mcp_server_command)

    if NativeHarness.injects_mcp_tools?(driver) and actions != [] and is_binary(command) do
      case McpToolConfig.write(
             actions: actions,
             command: command,
             args: Keyword.get(opts, :mcp_server_args, [])
           ) do
        {:ok, path} -> {path, mcp_cleanup(path)}
        {:error, _} -> {nil, &noop/0}
      end
    else
      {nil, &noop/0}
    end
  end

  defp mcp_cleanup(config_path) do
    fn -> File.rm_rf(Path.dirname(config_path)) end
  end

  defp noop, do: :ok

  defp cd_opt(nil), do: []
  defp cd_opt(cwd), do: [{:cd, cwd}]
end
