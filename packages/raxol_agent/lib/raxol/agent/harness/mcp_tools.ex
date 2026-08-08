defmodule Raxol.Agent.Harness.McpTools do
  @moduledoc """
  The coding-agent harness as MCP tools: any MCP client (Claude Code, an
  editor, another agent) can start, drive, and read Raxol agent sessions.

  Four tools register with `Raxol.MCP.Registry`:

    * `harness_start_session` — mint a persisted session, return its id
    * `harness_send_prompt`   — run one synchronous turn in a session
    * `harness_read_transcript` — the session's conversation so far
    * `harness_list_sessions` — saved sessions, most recent first

  Sessions share the TUI's store (`Raxol.Agent.Code.Store`, one JSON file
  per session under `~/.raxol/code_sessions`), so a session started over
  MCP resumes in the TUI with `mix raxol.code --resume <id>`, and a TUI
  session can be continued over MCP.

  Authorization: this surface is read-only on the workspace. Turns get the
  read-file/grep/glob tools plus the read-only skill actions; the mutating
  tools (`write_file`/`edit_file`/`bash`, `skill_manage`) are not in the
  toolset at all. A write-capable MCP surface waits on the MCP authorizer
  wiring (deny-on-ask), so a mutating call can ride the same fail-closed
  discipline every other sensitive MCP tool does — there is no human on
  this surface to answer an approval prompt.

  Each turn runs in an unlinked worker process: the worker owns the
  streamer subscription (so the long-lived MCP server never accumulates
  streamer state), a crashing turn cannot take the server down, and
  `timeout_s` is a total-turn deadline, not an inter-event idle timer.

  Registration rides the main application's MCP seam
  (`maybe_register_mcp_tools`), which fires only when this module is
  loaded — so `mix mcp.server` run from `packages/raxol_agent` serves
  these tools, and a deployment without raxol_agent never sees them.
  """

  alias Raxol.Agent.Backend.Cli
  alias Raxol.Agent.Code.Store
  alias Raxol.Agent.Contract
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Harness.EventBoundary

  @default_timeout_s 120
  @max_timeout_s 600

  @doc "The four harness tool definitions."
  @spec tools() :: [map()]
  def tools do
    [
      %{
        name: "harness_start_session",
        description: """
        Starts a new persisted coding-agent session and returns its id.
        The session is resumable in the TUI: mix raxol.code --resume <id>.
        """,
        inputSchema: %{type: "object", properties: %{}},
        callback: &start_session/1
      },
      %{
        name: "harness_send_prompt",
        description: """
        Runs one synchronous agent turn in a session and returns the
        assistant's answer. Conversation history persists across calls.
        The toolset is read-only on the workspace (read/grep/glob; no
        write_file, edit_file, or bash on this surface).
        """,
        inputSchema: %{
          type: "object",
          required: ["session_id", "prompt"],
          properties: %{
            session_id: %{
              type: "string",
              description: "Session id from harness_start_session"
            },
            prompt: %{
              type: "string",
              description: "The user prompt for this turn"
            },
            backend: %{
              type: "string",
              description: "LLM backend override (auto-detected when omitted)"
            },
            model: %{type: "string", description: "Model override"},
            timeout_s: %{
              type: "integer",
              description:
                "Total turn deadline in seconds (default #{@default_timeout_s}, max #{@max_timeout_s})"
            }
          }
        },
        callback: &send_prompt/1
      },
      %{
        name: "harness_read_transcript",
        description:
          "Returns a session's conversation (role-prefixed messages).",
        inputSchema: %{
          type: "object",
          required: ["session_id"],
          properties: %{
            session_id: %{type: "string", description: "Session id"}
          }
        },
        callback: &read_transcript/1
      },
      %{
        name: "harness_list_sessions",
        description:
          "Lists saved coding-agent sessions, most recently updated first.",
        inputSchema: %{type: "object", properties: %{}},
        callback: &list_sessions/1
      }
    ]
  end

  @doc "Register the harness tools with an MCP registry."
  @spec register(GenServer.server()) :: :ok
  def register(registry \\ Raxol.MCP.Registry) do
    Raxol.MCP.Registry.register_tools(registry, tools())
  end

  # -- callbacks --------------------------------------------------------------

  defp start_session(_args) do
    key = mint_session_key()

    case Store.save(Store.default_dir(), key, %{
           messages: [],
           events: [],
           cwd: Raxol.Agent.Actions.Fs.working_dir()
         }) do
      :ok -> {:ok, key}
      {:error, reason} -> {:error, "cannot create session: #{inspect(reason)}"}
    end
  end

  defp list_sessions(_args) do
    case Store.list(Store.default_dir()) do
      [] ->
        {:ok, "no saved sessions"}

      sessions ->
        {:ok,
         Enum.map_join(sessions, "\n", fn s ->
           "#{s.id}  (#{s.message_count} msgs)"
         end)}
    end
  end

  defp read_transcript(args) do
    with {:ok, key} <- session_key(args) do
      case Store.load(Store.default_dir(), key) do
        {:error, :not_found} ->
          {:error, "unknown session #{inspect(key)}"}

        {:ok, %{messages: []}} ->
          {:ok, "(empty session)"}

        {:ok, session} ->
          {:ok,
           Enum.map_join(session.messages, "\n\n", fn m ->
             "#{m.role}: #{m.content}"
           end)}
      end
    end
  end

  defp send_prompt(args) do
    with {:ok, key} <- session_key(args),
         {:ok, prompt} <- required(args, "prompt") do
      case Store.load(Store.default_dir(), key) do
        {:error, :not_found} ->
          {:error,
           "unknown session #{inspect(key)}; call harness_start_session first"}

        {:ok, session} ->
          run_turn(key, session, prompt, args)
      end
    end
  end

  # -- the synchronous turn ---------------------------------------------------

  defp run_turn(key, session, prompt, args) do
    with {:ok, executor, _source} <- resolve_executor(args) do
      messages = session.messages ++ [%{role: :user, content: prompt}]

      stream_opts =
        [
          executor: executor,
          system_prompt: system_prompt(),
          actions: turn_actions(),
          messages: messages
        ] ++ turn_context(session)

      timeout_ms = timeout_ms(args)

      # The streamer is ensured HERE (the long-lived server process), never
      # in the worker: a killed worker must not take a streamer it happened
      # to have started (and be linked to) down with it, dropping every
      # other consumer's subscriptions.
      ensure_streamer!()

      case await_worker(prompt, stream_opts, timeout_ms) do
        {:ok, state} -> persist_turn(key, session, messages, state)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The whole turn (streamer subscription, pump, collection) runs in an
  # UNLINKED worker: its exit triggers the streamer's monitor cleanup, and a
  # crashing pump kills the worker, never the long-lived MCP server this
  # callback runs in. The deadline here is the belt over the worker's own.
  defp await_worker(prompt, stream_opts, timeout_ms) do
    parent = self()
    tag = make_ref()

    {worker, mref} =
      spawn_monitor(fn ->
        send(parent, {tag, turn_worker(prompt, stream_opts, timeout_ms)})
      end)

    receive do
      {^tag, outcome} ->
        Process.demonitor(mref, [:flush])
        outcome

      {:DOWN, ^mref, :process, ^worker, reason} ->
        {:error, "turn crashed: #{inspect(reason)}"}
    after
      timeout_ms + 5_000 ->
        Process.exit(worker, :kill)
        Process.demonitor(mref, [:flush])
        {:error, "turn timed out after #{div(timeout_ms, 1000)}s"}
    end
  end

  # Runs in the worker process. `release/1` clears the streamer's
  # subscription and history for the throwaway pump id on the success and
  # error paths; a crash path is covered by the worker's exit (monitor
  # cleanup) plus the next release of the same id being a no-op.
  defp turn_worker(prompt, stream_opts, timeout_ms) do
    pump_id = "mcp-#{System.unique_integer([:positive])}"
    :ok = SessionStreamer.subscribe(pump_id)

    runner =
      Task.async(fn ->
        Contract.pump(
          pump_id,
          Raxol.Agent.Stream.react(prompt, stream_opts),
          prompt: prompt
        )
      end)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    outcome = collect(pump_id, runner, deadline, %{answer: "", events: []})
    SessionStreamer.release(pump_id)
    outcome
  end

  # Total-turn deadline: `after` uses the REMAINING budget, so a chatty
  # stream (deltas every few seconds) cannot re-arm the timer forever.
  defp collect(pump_id, runner, deadline, state) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      timeout(runner, deadline)
    else
      receive do
        {:session_event, ^pump_id, %Contract.Event{} = event} ->
          state = state |> accumulate_answer(event) |> record_event(event)

          case event do
            %{type: :turn_completed, payload: %{final: true}} ->
              Task.await(runner, 5_000)
              {:ok, state}

            %{type: :error, payload: payload} ->
              Task.await(runner, 5_000)
              {:error, "turn failed: #{inspect(Map.get(payload, :reason))}"}

            _ ->
              collect(pump_id, runner, deadline, state)
          end
      after
        remaining -> timeout(runner, deadline)
      end
    end
  end

  defp timeout(runner, _deadline) do
    Task.shutdown(runner, :brutal_kill)
    {:error, "turn deadline exceeded"}
  end

  defp accumulate_answer(
         state,
         %{
           type: :item_completed,
           payload: %{item_type: :message, content: content}
         }
       ) do
    %{state | answer: state.answer <> to_string(content)}
  end

  defp accumulate_answer(state, _event), do: state

  # Persist the same shape the TUI persists: EventBoundary-normalized
  # durable events, so `--resume` rebuilds the scrollback for this turn too.
  defp record_event(state, event) do
    case EventBoundary.normalize(event) do
      {:ok, %{tier: :durable} = normalized} ->
        %{state | events: [normalized | state.events]}

      _other ->
        state
    end
  end

  @doc false
  # Public so the shared-store refusal is testable without racing two real
  # turns against each other.
  @spec persist_turn(String.t(), map(), [map()], map()) ::
          {:ok, String.t()} | {:error, String.t()}
  def persist_turn(key, session, messages, state) do
    messages = messages ++ [%{role: :assistant, content: state.answer}]
    events = session.events ++ Enum.reverse(state.events)

    save =
      Store.save(
        Store.default_dir(),
        key,
        %{
          messages: messages,
          events: events,
          cwd: session.cwd,
          # Save rewrites the whole file; the loaded session's title and
          # fork lineage must ride along or an MCP-driven turn erases
          # what /rename and /fork recorded.
          title: Map.get(session, :title, ""),
          parent: Map.get(session, :parent)
        },
        # This store is shared with the TUI. Refuse rather than overwrite if
        # the session moved on since `send_prompt/1` read it — a blind write
        # would silently drop whichever surface persisted in between.
        expect_rev: Map.get(session, :rev)
      )

    case save do
      :ok ->
        {:ok, state.answer}

      {:error, :stale} ->
        {:error,
         "answer produced but not saved: session #{key} was written by " <>
           "another surface during this turn (open elsewhere?)"}

      {:error, reason} ->
        {:error, "answer produced but session save failed: #{inspect(reason)}"}
    end
  end

  defp resolve_executor(args) do
    opts =
      []
      |> maybe_put(:backend, args["backend"])
      |> maybe_put(:model, args["model"])

    case Cli.resolve_executor(opts, nil) do
      {:ok, executor, source} -> {:ok, executor, source}
      {:error, message} -> {:error, message}
    end
  end

  # -- toolset ----------------------------------------------------------------

  # Read-only on the workspace: no write_file/edit_file/bash, and no
  # skill_manage (it writes under ~/.raxol/skills).
  defp turn_actions do
    Raxol.Agent.Actions.Fs.all() ++
      Raxol.Agent.Actions.Code.read_only() ++ read_only_skills()
  end

  defp read_only_skills do
    Raxol.Agent.Skills.enabled_actions() -- [Raxol.Agent.Actions.Skills.Manage]
  end

  # The session records the workspace it was started against; honor it, so a
  # session resumed later reads the tree it was created for instead of
  # whatever directory this long-lived MCP server happens to sit in. A
  # recorded cwd that no longer exists is dropped rather than passed on (the
  # fs tools would refuse every path against a missing root).
  @doc false
  @spec turn_context(map()) :: keyword()
  def turn_context(session) do
    context =
      %{}
      |> put_some(:skills, Raxol.Agent.Skills.default_context())
      |> put_some(:cwd, usable_cwd(session))

    if map_size(context) == 0, do: [], else: [context: context]
  end

  defp usable_cwd(session) do
    case Map.get(session, :cwd) do
      dir when is_binary(dir) and dir != "" -> if File.dir?(dir), do: dir
      _absent -> nil
    end
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  defp system_prompt do
    "You are a helpful coding assistant running headlessly at the user's " <>
      "working directory. Use the available tools to inspect files when " <>
      "the question is about them. Be concise."
  end

  # -- helpers ----------------------------------------------------------------

  defp mint_session_key,
    do:
      "sess-#{System.system_time(:second)}-#{System.unique_integer([:positive])}"

  # Session ids come off the wire: basename-sanitize so a crafted id cannot
  # escape the sessions directory (same rule the TUI store applies).
  defp session_key(args) do
    with {:ok, raw} <- required(args, "session_id") do
      {:ok, Path.basename(raw)}
    end
  end

  defp required(args, name) do
    case Map.get(args, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, "missing required argument #{inspect(name)}"}
    end
  end

  defp timeout_ms(args) do
    seconds =
      case Map.get(args, "timeout_s") do
        n when is_integer(n) and n > 0 -> min(n, @max_timeout_s)
        _other -> @default_timeout_s
      end

    seconds * 1_000
  end

  defp ensure_streamer! do
    case SessionStreamer.start_link([]) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        raise "cannot start SessionStreamer: #{inspect(reason)}"
    end
  end

  defp maybe_put(kw, _key, nil), do: kw

  defp maybe_put(kw, key, value) when is_binary(value) and value != "",
    do: Keyword.put(kw, key, value)

  defp maybe_put(kw, _key, _value), do: kw
end
