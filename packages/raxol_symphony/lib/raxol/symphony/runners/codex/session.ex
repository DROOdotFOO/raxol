defmodule Raxol.Symphony.Runners.Codex.Session do
  @moduledoc """
  Port-backed session for the Codex app-server.

  Spawns `bash -lc <codex.command>` inside the workspace via `Port.open/2`,
  performs the `initialize` -> `initialized` -> `thread/start` handshake, and
  then drives one or more `turn/start` cycles over the same stdio session.

  Inbound messages are pushed through `Codex.Framing` (line buffered) and
  decoded with `Codex.Protocol`. Notifications, tool calls, and approval
  requests are emitted to `:on_event` (a 1-arity callback) as Symphony
  event maps; the receive loop continues until a terminal `turn/completed`
  / `turn/failed` / `turn/cancelled` arrives.

  This module owns the calling process's mailbox during `start/3` and
  `run_turn/4`. Run it inside a `Task` (which is what the orchestrator does).
  """

  require Logger

  alias Raxol.Symphony.Runners.Codex.{Framing, Protocol}

  @type session :: %{
          port: port(),
          thread_id: binary(),
          workspace: Path.t(),
          policy: map(),
          turn_id: pos_integer()
        }

  @type policy :: %{
          required(:approval_policy) => binary(),
          required(:thread_sandbox) => binary(),
          required(:turn_sandbox_policy) => map(),
          required(:read_timeout_ms) => pos_integer(),
          required(:turn_timeout_ms) => pos_integer(),
          required(:auto_approve?) => boolean(),
          required(:dynamic_tools) => list()
        }

  @port_line_bytes 1_048_576
  @default_turn_id 100

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts a Codex app-server session in `workspace`.

  `command` is the shell command Codex was launched with (per `codex.command`).
  """
  @spec start(Path.t(), binary(), policy()) :: {:ok, session()} | {:error, term()}
  def start(workspace, command, %{} = policy)
      when is_binary(workspace) and is_binary(command) do
    with {:ok, bash} <- find_bash(),
         {:ok, port} <- open_port(bash, command, workspace),
         :ok <- send_initialize(port, policy.read_timeout_ms),
         {:ok, thread_id} <- send_thread_start(port, workspace, policy) do
      {:ok,
       %{
         port: port,
         thread_id: thread_id,
         workspace: workspace,
         policy: policy,
         turn_id: @default_turn_id
       }}
    else
      {:error, _} = err ->
        err
    end
  end

  @doc """
  Drives one turn against an active session.

  Returns `:ok` when the turn completes, or `{:error, reason}` on
  `turn/failed`, `turn/cancelled`, approval denial, port exit, or timeout.
  """
  @spec run_turn(session(), binary(), map(), (map() -> any())) ::
          {:ok, session()} | {:error, term()}
  def run_turn(%{} = session, prompt, %{} = issue, on_event)
      when is_binary(prompt) and is_function(on_event, 1) do
    send_turn_start(session, prompt, issue)

    case await_response(session.port, session.turn_id, session.policy.read_timeout_ms, "") do
      {:ok, %{"turn" => %{"id" => turn_label}}} ->
        emit_session_started(on_event, session, turn_label)
        receive_turn(session, on_event, "")

      {:ok, _other} ->
        {:error, :invalid_turn_response}

      {:error, _} = err ->
        err
    end
  end

  defp send_turn_start(session, prompt, issue) do
    payload =
      Protocol.turn_start_request(
        session.turn_id,
        session.thread_id,
        session.workspace,
        prompt,
        issue,
        approval_policy: session.policy.approval_policy,
        turn_sandbox_policy: session.policy.turn_sandbox_policy
      )

    send_payload(session.port, payload)
  end

  @doc """
  Closes the Port and drains any residual messages.
  """
  @spec stop(session() | port()) :: :ok
  def stop(%{port: port}), do: stop(port)
  def stop(port) when is_port(port), do: close_port(port)
  def stop(_), do: :ok

  # ---------------------------------------------------------------------------
  # Handshake
  # ---------------------------------------------------------------------------

  defp send_initialize(port, timeout_ms) do
    send_payload(port, Protocol.initialize_request())

    with {:ok, _} <- await_response(port, Protocol.initialize_id(), timeout_ms, "") do
      send_payload(port, Protocol.initialized_notification())
      :ok
    end
  end

  defp send_thread_start(port, workspace, policy) do
    payload =
      Protocol.thread_start_request(workspace,
        approval_policy: policy.approval_policy,
        thread_sandbox: policy.thread_sandbox,
        dynamic_tools: policy.dynamic_tools
      )

    send_payload(port, payload)

    case await_response(port, Protocol.thread_start_id(), policy.read_timeout_ms, "") do
      {:ok, %{"thread" => %{"id" => thread_id}}} when is_binary(thread_id) ->
        {:ok, thread_id}

      {:ok, other} ->
        {:error, {:invalid_thread_payload, other}}

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Receive loops
  # ---------------------------------------------------------------------------

  defp await_response(port, request_id, timeout_ms, buffer) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        case Framing.push(buffer, {:eol, chunk}) do
          {:line, line, _} -> handle_response_line(port, request_id, timeout_ms, line)
        end

      {^port, {:data, {:noeol, chunk}}} ->
        {:partial, new_buffer} = Framing.push(buffer, {:noeol, chunk})
        await_response(port, request_id, timeout_ms, new_buffer)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response_line(port, request_id, timeout_ms, line) do
    case Framing.decode(line) do
      {:ok, :empty} ->
        await_response(port, request_id, timeout_ms, "")

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id, "error" => err}} ->
        {:error, {:response_error, err}}

      {:ok, %{"id" => ^request_id} = response} ->
        {:error, {:response_error, response}}

      {:ok, _other} ->
        await_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json(line, "handshake")
        await_response(port, request_id, timeout_ms, "")
    end
  end

  defp receive_turn(%{port: port, policy: policy} = session, on_event, buffer) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        case Framing.push(buffer, {:eol, chunk}) do
          {:line, line, _} -> handle_turn_line(session, on_event, line)
        end

      {^port, {:data, {:noeol, chunk}}} ->
        {:partial, new_buffer} = Framing.push(buffer, {:noeol, chunk})
        receive_turn(session, on_event, new_buffer)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      policy.turn_timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_turn_line(session, on_event, line) do
    case Framing.decode(line) do
      {:ok, :empty} ->
        receive_turn(session, on_event, "")

      {:ok, payload} ->
        dispatch(session, on_event, payload)

      {:error, _} ->
        log_non_json(line, "turn")
        receive_turn(session, on_event, "")
    end
  end

  defp dispatch(session, on_event, payload),
    do: handle_classification(Protocol.classify(payload), session, on_event)

  defp handle_classification({:turn_completed, event}, session, on_event) do
    on_event.(event)
    {:ok, %{session | turn_id: session.turn_id + 1}}
  end

  defp handle_classification({:turn_failed, event, reason}, _session, on_event) do
    on_event.(event)
    {:error, reason}
  end

  defp handle_classification({:tool_call, id, name, args, event}, session, on_event) do
    on_event.(event)
    result = unsupported_tool_response(name, args)
    send_payload(session.port, Protocol.tool_call_result(id, result))
    receive_turn(session, on_event, "")
  end

  defp handle_classification({:approval, id, decision, event}, session, on_event) do
    on_event.(event)
    handle_approval(session, on_event, id, decision)
  end

  defp handle_classification({:input_required, event, reason}, _session, on_event) do
    on_event.(event)
    {:error, {:input_required, reason}}
  end

  defp handle_classification({:notification, event}, session, on_event) do
    on_event.(event)
    receive_turn(session, on_event, "")
  end

  defp handle_classification({:response, _payload}, session, on_event) do
    # Stray result from an out-of-band request -- ignore and keep listening.
    receive_turn(session, on_event, "")
  end

  defp handle_classification(:ignore, session, on_event),
    do: receive_turn(session, on_event, "")

  defp handle_approval(%{policy: %{auto_approve?: true}} = session, on_event, id, decision) do
    send_payload(session.port, Protocol.approval_result(id, decision))
    receive_turn(session, on_event, "")
  end

  defp handle_approval(_session, _on_event, _id, decision),
    do: {:error, {:approval_required, decision}}

  defp unsupported_tool_response(name, _args) do
    %{
      "success" => false,
      "output" =>
        "Dynamic tool #{inspect(name)} is not registered with this Symphony deployment.",
      "contentItems" => [
        %{"type" => "inputText", "text" => "Unsupported dynamic tool: #{inspect(name)}"}
      ]
    }
  end

  defp emit_session_started(on_event, %{thread_id: thread_id}, turn_label) do
    on_event.(%{
      event: :session_started,
      message: "session #{thread_id}/#{turn_label}",
      payload: %{"thread_id" => thread_id, "turn_id" => turn_label},
      timestamp: DateTime.utc_now()
    })
  end

  # ---------------------------------------------------------------------------
  # Port lifecycle
  # ---------------------------------------------------------------------------

  defp find_bash do
    case System.find_executable("bash") do
      nil -> {:error, :bash_not_found}
      path -> {:ok, path}
    end
  end

  defp open_port(bash, command, workspace) do
    port =
      Port.open(
        {:spawn_executable, bash},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          {:cd, workspace},
          {:line, @port_line_bytes},
          {:args, ["-lc", command]}
        ]
      )

    {:ok, port}
  rescue
    e -> {:error, {:port_open_failed, e}}
  end

  defp close_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end

        flush(port)
        :ok
    end
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp send_payload(port, payload) do
    Port.command(port, Framing.encode!(payload))
  end

  defp log_non_json(line, label) do
    trimmed = line |> String.trim() |> String.slice(0, 200)

    if trimmed != "" do
      Logger.debug("symphony.codex.non_json #{label}: #{trimmed}")
    end
  end
end
