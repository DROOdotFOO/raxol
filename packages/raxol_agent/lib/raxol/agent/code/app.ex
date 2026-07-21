defmodule Raxol.Agent.Code.App do
  @moduledoc """
  Interactive coding-agent TUI — the `mix raxol.code` surface.

  A TEA app (`use Raxol.Core.Runtime.Application`) that owns a multi-turn
  coding loop and wears the axol face `≡··≡` as its status layer. It is a
  *thin Lifecycle shell*: it drives the loop itself but reuses the harness
  rendering pieces rather than reinventing them —
  `Raxol.Harness.Projection` folds contract events into blocks and
  `Raxol.UI.Components.Harness.Block` renders them; the face comes from
  `Raxol.UI.Components.Harness.AxolFace`.

  ## The loop

  On submit, `update/2` spawns a worker that subscribes to a
  `Raxol.Agent.SessionStreamer` session, runs `Raxol.Agent.Stream.react/2`
  through `Raxol.Agent.Contract.pump/3`, and relays every contract event
  back to this app as `{:command_result, {:contract_event, event}}`. The
  Dispatcher routes those to `update/2`, which normalizes them
  (`Raxol.Harness.EventBoundary.normalize/1`) and appends them to the
  projection source. Because `update/2` runs in the Dispatcher process,
  the worker's `send(app, ...)` lands where the app can fold it.

  ## Tools, authorization, and plan mode

  The agent gets the read-only fs tools plus the mutating coding tools
  (`write_file`/`edit_file`/`bash`), which are `sensitive`. A per-run
  `:tool_authorizer` defers every sensitive call to this app, which runs
  it through `Raxol.Agent.Authorization.Engine` (the ALLOW/ASK/DENY
  reducer):

    * **ALLOW** — the tool was previously approved "always" this session,
      so it runs without prompting.
    * **ASK** — an interactive prompt (allow once / always / deny) that
      BLOCKS the react loop's process until the user answers, so a write
      or a shell command never runs unattended.
    * **DENY** — in **plan mode** any mutating tool is refused; the agent
      can only read and propose.

  **Plan mode** (toggle: Shift+Tab or Ctrl+P) swaps in a planning system
  prompt and has the Engine deny mutations, so a turn researches and lays
  out a plan without touching disk. Toggle it back off to execute.

  ## Keys

    * printable text → prompt buffer (when idle)
    * Enter → submit the prompt
    * `a` / `s` / `d` → answer a pending approval (allow once / always / deny)
    * Shift+Tab or Ctrl+P → toggle plan mode
    * Esc → deny a pending approval, else interrupt a running turn
    * Ctrl+C → quit
  """

  use Raxol.Core.Runtime.Application

  alias Raxol.Agent.Authorization.Engine
  alias Raxol.Agent.Authorization.Policy
  alias Raxol.Agent.Authorization.Verdict
  alias Raxol.Agent.Contract
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Harness.EventBoundary
  alias Raxol.Harness.Projection
  alias Raxol.UI.Components.Harness.AxolFace
  alias Raxol.UI.Components.Harness.Block
  alias Raxol.UI.Harness.InputEvent

  @approval_timeout_ms 300_000

  # -- init -------------------------------------------------------------------

  @impl true
  def init(context) do
    options = Map.get(context, :options, [])
    {sessions_dir, session_key, messages, resume_notice} = init_session(options)

    %{
      input: "",
      # Normalized projection events (durable + ephemeral), arrival order.
      events: [],
      # The LLM conversation carried across turns (persisted per session).
      messages: messages,
      # Assistant text accumulated during the in-flight turn.
      turn_answer: "",
      face_state: :idle,
      face_frame: 0,
      running?: false,
      worker: nil,
      session_id: nil,
      pending_approval: nil,
      status_line: resume_notice,
      notice: nil,
      # Authorization: plan mode + per-tool "always allow" memory. The Engine
      # is the ALLOW/ASK/DENY decision core; per-tool memory is app state fed
      # into the policy context (the Engine's own memory is per-policy).
      plan_mode: false,
      always_allow: MapSet.new(),
      auth_state: Engine.new(),
      # Session persistence.
      session_key: session_key,
      sessions_dir: sessions_dir,
      ascii: Keyword.get(options, :ascii, false),
      executor: Keyword.get(options, :executor),
      backend_opts: Keyword.get(options, :backend_opts, []),
      model_override: Keyword.get(options, :model),
      system: Keyword.get(options, :system, default_system()),
      actions: Keyword.get(options, :actions, default_actions()),
      # Injectable so tests drive the loop without spawning a real turn.
      runner: Keyword.get(options, :runner, &__MODULE__.default_runner/4),
      width: Map.get(context, :width, 80),
      height: Map.get(context, :height, 24)
    }
  end

  # Resolve the session to write to and any conversation to resume. A
  # `:session_key` option (set by `--continue`/`--resume`) reattaches that
  # session's messages; absent, a fresh session is minted.
  defp init_session(options) do
    dir = Keyword.get(options, :sessions_dir) || Raxol.Agent.Code.Store.default_dir()

    case Keyword.get(options, :session_key) do
      nil ->
        {dir, mint_session_key(), [], nil}

      key ->
        case Raxol.Agent.Code.Store.load(dir, key) do
          {:ok, %{messages: messages}} ->
            {dir, key, messages, "resumed #{length(messages)} messages"}

          {:error, _} ->
            {dir, key, [], "session #{key} not found — starting fresh"}
        end
    end
  end

  defp mint_session_key do
    "sess-#{System.system_time(:second)}-#{System.unique_integer([:positive])}"
  end

  # -- update: keyboard -------------------------------------------------------

  @impl true
  def update(%Raxol.Core.Events.Event{} = event, model) do
    norm = InputEvent.normalize(event)

    cond do
      InputEvent.shortcut?(norm) -> handle_shortcut(norm, model)
      InputEvent.text?(norm) -> handle_char(InputEvent.printable_char(norm), model)
      key = InputEvent.key(norm) -> handle_key(key, model)
      true -> {model, []}
    end
  end

  # -- update: async messages from the worker / authorizer --------------------

  def update({:command_result, {:contract_event, event}}, model) do
    case EventBoundary.normalize(event) do
      {:ok, normalized} -> {fold_event(event, normalized, model), []}
      {:error, _invalid} -> {model, []}
    end
  end

  # A sensitive tool call awaiting a verdict: run it through the Engine.
  # ALLOW (remembered) and DENY (plan mode) answer immediately; ASK opens
  # the interactive prompt.
  def update(
        {:command_result, {:authorize_request, ref, from, name}},
        model
      ) do
    context = %{
      tool: name,
      mutating: true,
      plan_mode: model.plan_mode,
      always_allow: model.always_allow
    }

    decision = Engine.evaluate(auth_policies(), :tool_call, context, model.auth_state)

    case decision.action do
      :allow ->
        send(from, {:authorize_decision, ref, :allow})
        {model, []}

      :deny ->
        send(from, {:authorize_decision, ref, {:deny, decision.reason}})
        {%{model | status_line: "denied in plan mode: #{name}"}, []}

      :ask ->
        approval = %{ref: ref, from: from, name: name}
        {%{model | pending_approval: approval, face_state: :working}, []}
    end
  end

  def update(_message, model), do: {model, []}

  # -- key handlers -----------------------------------------------------------

  defp handle_shortcut(%{char: "c", mods: %{ctrl: true}}, model) do
    {model, [Directive.stop()]}
  end

  # Ctrl+P toggles plan mode (Shift+Tab does too — see handle_key/2).
  defp handle_shortcut(%{char: "p", mods: %{ctrl: true}}, model),
    do: {maybe_toggle_plan_mode(model), []}

  defp handle_shortcut(_norm, model), do: {model, []}

  # `a`/`s`/`d` (with `y`/`n` aliases) answer a pending approval; otherwise
  # printable text edits the prompt, but only when idle.
  defp handle_char(char, %{pending_approval: %{}} = model)
       when char in ["a", "A", "y", "Y"],
       do: {allow_once(model), []}

  defp handle_char(char, %{pending_approval: %{}} = model)
       when char in ["s", "S"],
       do: {allow_always(model), []}

  defp handle_char(char, %{pending_approval: %{}} = model)
       when char in ["d", "D", "n", "N"],
       do: {deny_pending(model), []}

  defp handle_char(_char, %{pending_approval: %{}} = model), do: {model, []}

  defp handle_char(_char, %{running?: true} = model), do: {model, []}

  defp handle_char(char, model) do
    {%{model | input: model.input <> char}, []}
  end

  # Shift+Tab toggles plan mode when idle.
  defp handle_key(:backtab, model), do: {maybe_toggle_plan_mode(model), []}

  defp handle_key(:enter, %{pending_approval: %{}} = model), do: {model, []}
  defp handle_key(:enter, %{running?: true} = model), do: {model, []}

  defp handle_key(:enter, model) do
    case String.trim(model.input) do
      "" -> {model, []}
      "/" <> _ = command -> dispatch_slash(%{model | input: ""}, command)
      prompt -> {start_turn(model, prompt), []}
    end
  end

  defp handle_key(:backspace, %{pending_approval: %{}} = model), do: {model, []}
  defp handle_key(:backspace, %{running?: true} = model), do: {model, []}

  defp handle_key(:backspace, model) do
    {%{model | input: String.slice(model.input, 0..-2//1)}, []}
  end

  # Esc denies a pending approval first, then interrupts a running turn.
  defp handle_key(:escape, %{pending_approval: %{}} = model),
    do: {deny_pending(model), []}

  defp handle_key(:escape, %{running?: true} = model),
    do: {interrupt(model), []}

  defp handle_key(_key, model), do: {model, []}

  # Plan mode only toggles when idle — flipping it mid-turn or mid-approval
  # would be surprising (the toolset/prompt are fixed at turn start).
  defp maybe_toggle_plan_mode(%{running?: true} = model), do: model
  defp maybe_toggle_plan_mode(%{pending_approval: %{}} = model), do: model
  defp maybe_toggle_plan_mode(model), do: %{model | plan_mode: not model.plan_mode}

  # -- turn lifecycle ---------------------------------------------------------

  defp start_turn(model, prompt) do
    session_id = "code-#{System.unique_integer([:positive])}"
    ensure_streamer!()
    app = self()

    messages = model.messages ++ [%{role: :user, content: prompt}]

    opts =
      [
        backend_opts: model.backend_opts,
        system_prompt: system_prompt(model),
        actions: model.actions,
        messages: messages,
        context: %{tool_authorizer: tool_authorizer(app)}
      ]
      |> maybe_put(:executor, model.executor)
      |> maybe_put(:model, model.model_override)

    worker = model.runner.(session_id, prompt, opts, app)

    %{
      model
      | running?: true,
        worker: worker,
        session_id: session_id,
        messages: messages,
        turn_answer: "",
        face_state: :thinking,
        face_frame: 0,
        status_line: nil,
        notice: nil,
        input: ""
    }
  end

  # The real worker: subscribe, then relay each contract event to the app.
  # The pump runs in its OWN linked process because `Stream.react/2` sends its
  # react events to whatever process CREATED the stream — so the stream must be
  # created and consumed in the same process. The worker (the subscriber) stays
  # free to run the relay receive-loop; the pump process only produces events
  # into the streamer, which the worker then forwards.
  @doc false
  def default_runner(session_id, prompt, opts, app) do
    spawn(fn ->
      SessionStreamer.subscribe(session_id)

      Task.async(fn ->
        Contract.pump(session_id, Raxol.Agent.Stream.react(prompt, opts), prompt: prompt)
      end)

      relay(session_id, app)
    end)
  end

  defp relay(session_id, app) do
    receive do
      {:session_event, ^session_id, event} ->
        send(app, {:command_result, {:contract_event, event}})
        unless terminal_event?(event), do: relay(session_id, app)
    after
      @approval_timeout_ms -> :ok
    end
  end

  defp interrupt(model) do
    if is_pid(model.worker) and Process.alive?(model.worker) do
      Process.exit(model.worker, :kill)
    end

    reply_pending(model, {:deny, :interrupted})

    %{
      model
      | running?: false,
        worker: nil,
        face_state: :idle,
        pending_approval: nil,
        status_line: "interrupted"
    }
  end

  defp system_prompt(%{plan_mode: true, system: system}),
    do: system <> "\n\n" <> plan_directive()

  defp system_prompt(%{system: system}), do: system

  defp plan_directive do
    "PLAN MODE: You are in read-only planning mode. Investigate with the " <>
      "read-only tools (read_file, list_dir, grep, glob) and then propose a " <>
      "concise, numbered plan. Do NOT call write_file, edit_file, or bash — " <>
      "they are refused until the user leaves plan mode to execute."
  end

  # -- contract-event fold ----------------------------------------------------

  defp fold_event(event, normalized, model) do
    running? = model.running? and not terminal_event?(event)

    model = %{
      model
      | events: model.events ++ [normalized],
        face_state: face_for_event(event, model.face_state),
        face_frame: model.face_frame + 1,
        running?: running?,
        worker: if(running?, do: model.worker, else: nil),
        status_line: if(running?, do: model.status_line, else: nil)
    }

    model
    |> accumulate_answer(event)
    |> finalize_turn(event)
  end

  # A completed message item is assistant answer text — accumulate it so the
  # conversation memory gets the reply when the turn closes.
  defp accumulate_answer(model, %{type: :item_completed, payload: payload}) do
    case item_type(payload) do
      :message ->
        %{model | turn_answer: model.turn_answer <> to_string(payload_content(payload))}

      _other ->
        model
    end
  end

  defp accumulate_answer(model, _event), do: model

  # On a successful turn boundary, append the assistant reply to the
  # conversation and persist it. An error turn persists without appending a
  # (possibly partial) reply.
  defp finalize_turn(model, %{type: :turn_completed, payload: payload}) do
    if final?(payload) do
      messages = append_assistant(model.messages, model.turn_answer)
      persist(%{model | messages: messages, turn_answer: ""})
    else
      model
    end
  end

  defp finalize_turn(model, %{type: :error}), do: persist(%{model | turn_answer: ""})
  defp finalize_turn(model, _event), do: model

  defp append_assistant(messages, answer) do
    case String.trim(answer) do
      "" -> messages
      trimmed -> messages ++ [%{role: :assistant, content: trimmed}]
    end
  end

  defp payload_content(payload),
    do: Map.get(payload, :content) || Map.get(payload, "content") || ""

  defp persist(model) do
    case Raxol.Agent.Code.Store.save(model.sessions_dir, model.session_key, %{
           messages: model.messages
         }) do
      :ok -> model
      {:error, reason} -> %{model | status_line: "session save failed: #{inspect(reason)}"}
    end
  end

  # Map a contract event to the face state it should show.
  defp face_for_event(%{type: :turn_started}, _current), do: :thinking

  defp face_for_event(%{type: :turn_completed, payload: payload}, current) do
    if final?(payload), do: :done, else: current
  end

  defp face_for_event(%{type: :error}, _current), do: :error

  defp face_for_event(%{type: type, payload: payload}, current)
       when type in [:item_started, :item_completed] do
    case item_type(payload) do
      it when it in [:tool_use, :tool_result] -> :working
      it when it in [:message, :reasoning] -> :thinking
      _other -> current
    end
  end

  defp face_for_event(%{type: :item_delta}, current) do
    # A delta during a tool phase (rare) shouldn't yank the face off :working;
    # otherwise streaming text is thinking.
    if current == :working, do: :working, else: :thinking
  end

  defp face_for_event(_event, current), do: current

  defp terminal_event?(%{type: :error}), do: true

  defp terminal_event?(%{type: :turn_completed, payload: payload}),
    do: final?(payload)

  defp terminal_event?(_event), do: false

  defp final?(payload) when is_map(payload),
    do: Map.get(payload, :final) == true or Map.get(payload, "final") == true

  defp item_type(payload) when is_map(payload),
    do: Map.get(payload, :item_type) || Map.get(payload, "item_type")

  # -- authorization ----------------------------------------------------------

  # The `:tool_authorizer`: runs inside the react loop's process and defers
  # every sensitive tool call to the app for an Engine verdict, blocking until
  # the app answers. Non-sensitive tools are allowed without a round-trip.
  defp tool_authorizer(app) do
    fn module, _params, _context ->
      meta = module.__action_meta__()

      if Map.get(meta, :sensitive, false) do
        ref = make_ref()
        send(app, {:command_result, {:authorize_request, ref, self(), meta.name}})

        receive do
          {:authorize_decision, ^ref, :allow} -> :ok
          {:authorize_decision, ^ref, {:deny, reason}} -> {:deny, reason}
        after
          @approval_timeout_ms -> {:deny, :approval_timeout}
        end
      else
        :ok
      end
    end
  end

  # The ALLOW/ASK/DENY policy the Engine folds. Only sensitive (mutating)
  # tools reach it — the closure allows the rest — so the `always_allow` and
  # ASK arms already know the tool is mutating.
  defp auth_policies do
    [
      Policy.new(
        name: :coding_tools,
        phases: [:tool_call],
        scope: :session,
        evaluate: fn ctx ->
          cond do
            ctx.plan_mode and ctx.mutating -> Verdict.deny(:plan_mode_read_only)
            MapSet.member?(ctx.always_allow, ctx.tool) -> Verdict.allow()
            true -> Verdict.ask("Allow #{ctx.tool}?")
          end
        end
      )
    ]
  end

  defp allow_once(model) do
    reply_pending(model, :allow)
    %{model | pending_approval: nil, face_state: :working}
  end

  defp allow_always(%{pending_approval: %{name: name}} = model) do
    reply_pending(model, :allow)

    %{
      model
      | pending_approval: nil,
        always_allow: MapSet.put(model.always_allow, name),
        face_state: :working
    }
  end

  defp deny_pending(model) do
    reply_pending(model, {:deny, :user_denied})
    %{model | pending_approval: nil, face_state: :thinking}
  end

  defp reply_pending(%{pending_approval: %{ref: ref, from: from}}, verdict)
       when is_pid(from) do
    send(from, {:authorize_decision, ref, verdict})
    :ok
  end

  defp reply_pending(_model, _verdict), do: :ok

  # -- slash commands ---------------------------------------------------------

  defp dispatch_slash(model, command) do
    {name, arg} = parse_command(command)

    case name do
      "help" -> {notice(model, help_text()), []}
      "clear" -> {clear_session(model), []}
      "plan" -> {maybe_toggle_plan_mode(model), []}
      "model" -> {set_model(model, arg), []}
      "context" -> {notice(model, context_text(model)), []}
      "compact" -> {compact(model), []}
      "sessions" -> {notice(model, sessions_text(model)), []}
      other -> {notice(model, "unknown command: /#{other} — try /help"), []}
    end
  end

  defp parse_command("/" <> rest) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [name] -> {name, ""}
      [name, arg] -> {name, String.trim(arg)}
    end
  end

  defp notice(model, text), do: %{model | notice: text}

  # A fresh session preserves the old file on disk and starts a new key, so
  # clearing is never destructive to a prior conversation.
  defp clear_session(model) do
    %{
      model
      | messages: [],
        events: [],
        turn_answer: "",
        face_state: :idle,
        face_frame: 0,
        session_key: mint_session_key(),
        notice: "cleared — new session"
    }
  end

  defp set_model(model, "") do
    notice(model, "usage: /model <name>  (current: #{model.model_override || "default"})")
  end

  defp set_model(model, name) do
    notice(%{model | model_override: name}, "model set to #{name}")
  end

  # Heuristic context shrink: keep the last few exchanges, replace the rest
  # with a marker. Not a semantic summary — an honest size reducer.
  defp compact(model) do
    keep = 6
    count = length(model.messages)

    if count <= keep do
      notice(model, "nothing to compact (#{count} messages)")
    else
      {older, recent} = Enum.split(model.messages, count - keep)
      marker = %{role: :system, content: "[#{length(older)} earlier messages compacted]"}
      model = persist(%{model | messages: [marker | recent]})
      notice(model, "compacted #{length(older)} messages")
    end
  end

  defp context_text(model) do
    "messages: #{length(model.messages)} · events: #{length(model.events)} · " <>
      "plan: #{if model.plan_mode, do: "on", else: "off"} · " <>
      "model: #{model.model_override || "default"} · session: #{model.session_key}"
  end

  defp sessions_text(model) do
    case Raxol.Agent.Code.Store.list(model.sessions_dir) do
      [] ->
        "no saved sessions"

      sessions ->
        sessions
        |> Enum.take(10)
        |> Enum.map_join("\n", fn s -> "#{s.id}  (#{s.message_count} msgs)" end)
    end
  end

  defp help_text do
    """
    /help              this help
    /clear             start a fresh session
    /model <name>      switch model for the next turns
    /plan              toggle plan mode
    /compact           shrink the conversation history
    /context           session stats
    /sessions          list saved sessions
    """
    |> String.trim_trailing()
  end

  # -- view -------------------------------------------------------------------

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1} do
      [transcript(model)] ++ notice_block(model) ++ [status_strip(model), footer(model)]
    end
  end

  defp notice_block(%{notice: notice}) when is_binary(notice) do
    lines = String.split(notice, "\n")

    [
      box style: %{border: :single, padding: 0} do
        column style: %{gap: 0} do
          Enum.map(lines, &text(&1, fg: :cyan))
        end
      end
    ]
  end

  defp notice_block(_model), do: []

  defp transcript(model) do
    projection = Projection.project(model.events)
    context = %{theme: Raxol.UI.Theming.Theme.default_theme()}
    blocks = Enum.map(projection.blocks, &Block.render(&1, context))
    tail = tail_lines(projection.tail)

    column style: %{gap: 0} do
      blocks ++ tail
    end
  end

  # In-flight streaming text (the live tail), one dim line per open item.
  defp tail_lines(tail) when is_map(tail) do
    tail
    |> Map.values()
    |> Enum.map(fn %{chunks: chunks} ->
      text(chunks |> Enum.reverse() |> Enum.join(""), style: [:dim])
    end)
  end

  defp status_strip(model) do
    face =
      text(AxolFace.glyph(model.face_state, model.face_frame, model.ascii),
        fg: AxolFace.color(model.face_state),
        style: [:bold]
      )

    status = text(status_label(model), style: [:dim])

    row style: %{gap: 1} do
      [face] ++ plan_chip(model) ++ [status]
    end
  end

  defp plan_chip(%{plan_mode: true}), do: [text("PLAN", fg: :yellow, style: [:bold])]
  defp plan_chip(_model), do: []

  defp status_label(%{status_line: line}) when is_binary(line), do: line
  defp status_label(%{pending_approval: %{name: name}}), do: "awaiting approval: #{name}"
  defp status_label(%{running?: true}), do: "working…"
  defp status_label(%{plan_mode: true}), do: "plan mode — read-only"
  defp status_label(_model), do: "ready"

  defp footer(%{pending_approval: %{name: name}}) do
    box style: %{border: :single, padding: 0} do
      text("Allow #{name}?  [a]llow once · [s]always · [d]eny  ·  Esc denies",
        fg: :yellow
      )
    end
  end

  defp footer(model) do
    box style: %{border: :single, padding: 0} do
      text("> " <> model.input <> cursor(model))
    end
  end

  defp cursor(%{running?: true}), do: ""
  defp cursor(_model), do: "▌"

  # -- helpers ----------------------------------------------------------------

  defp ensure_streamer! do
    case SessionStreamer.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "cannot start SessionStreamer: #{inspect(reason)}"
    end
  end

  defp default_actions do
    Raxol.Agent.Actions.Fs.all() ++ Raxol.Agent.Actions.Code.all()
  end

  defp default_system do
    "You are a coding assistant running in a terminal at the user's " <>
      "current working directory. Read files before editing them. Use " <>
      "write_file/edit_file to change code and bash to run commands. Be concise."
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
