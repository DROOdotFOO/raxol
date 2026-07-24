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

    {sessions_dir, session_key, messages, events, resume_notice} =
      init_session(options)

    cwd = Keyword.get(options, :cwd) || Raxol.Agent.Actions.Fs.working_dir()
    {hooks, hooks_note} = load_hooks(cwd)
    {mcp_servers, mcp_note} = load_mcp(cwd)

    config(options, context)
    |> Map.merge(%{
      # Seeded from a resumed session so the transcript + conversation
      # rebuild immediately; a fresh session starts these empty.
      events: events,
      messages: messages,
      status_line: combine_notes([resume_notice, hooks_note, mcp_note]),
      session_key: session_key,
      sessions_dir: sessions_dir,
      cwd: cwd,
      hooks: hooks,
      mcp_servers: mcp_servers
    })
    |> maybe_open_initial_wizard()
    |> maybe_arm_launch_validation()
  end

  # No provider connected at boot -> open the onboarding wizard on its
  # selectable provider list.
  defp maybe_open_initial_wizard(model) do
    if provider_ready?(model), do: model, else: open_browse(model)
  end

  # A provider connected at boot (auto-detected or --harness) -> validate it on
  # the first update, so a stale key surfaces before the first prompt.
  defp maybe_arm_launch_validation(%{executor: %{} = executor} = model) do
    if provider_ready?(model),
      do: %{model | pending_validation: executor},
      else: model
  end

  defp maybe_arm_launch_validation(model), do: model

  # Static + option-derived fields; the session and loaded config are merged
  # over these in init/1.
  defp config(options, context) do
    %{
      input: "",
      turn_answer: "",
      face_state: :idle,
      face_frame: 0,
      running?: false,
      worker: nil,
      session_id: nil,
      pending_approval: nil,
      notice: nil,
      # Authorization: plan mode + per-tool "always allow" memory. The Engine
      # is the ALLOW/ASK/DENY decision core; per-tool memory is app state fed
      # into the policy context (the Engine's own memory is per-policy).
      plan_mode: false,
      always_allow: MapSet.new(),
      auth_state: Engine.new(),
      ascii: Keyword.get(options, :ascii, false),
      executor: Keyword.get(options, :executor),
      # How the provider was resolved: `:ready` / `{:ready, harness, source}`
      # start straight into the loop; `{:no_key, harness}` / `:no_provider`
      # open on the setup panel and gate turns until `/login` connects one.
      provider_status: Keyword.get(options, :provider_status, :ready),
      # The most recent `/login` validation token; a ping result is applied
      # only when its ref still matches (a re-login supersedes an in-flight
      # check). Injectable so tests drive validation without a network call.
      login_ref: nil,
      login_validator:
        Keyword.get(
          options,
          :login_validator,
          &__MODULE__.default_login_validator/3
        ),
      # The onboarding wizard overlay: nil (connected), or a step map
      # (`:browse` selectable list, `:credential` masked entry, `:confirm_save`
      # save-to-1Password prompt). Set in init when no provider is connected.
      wizard: nil,
      # An executor armed in init to validate on the first update (which runs
      # in the dispatcher, so the ping's reply lands where update can fold it).
      pending_validation: nil,
      # Injectable so the save-to-1Password flow is testable without mutating a
      # real vault; the default shells out to `op item create`.
      op_saver: Keyword.get(options, :op_saver, &__MODULE__.default_op_saver/2),
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
    dir =
      Keyword.get(options, :sessions_dir) ||
        Raxol.Agent.Code.Store.default_dir()

    case Keyword.get(options, :session_key) do
      nil ->
        {dir, mint_session_key(), [], [], nil}

      key ->
        case Raxol.Agent.Code.Store.load(dir, key) do
          {:ok, %{messages: messages, events: events}} ->
            {dir, key, messages, events, "resumed #{length(messages)} messages"}

          {:error, _} ->
            {dir, key, [], [], "session #{key} not found — starting fresh"}
        end
    end
  end

  defp mint_session_key do
    "sess-#{System.system_time(:second)}-#{System.unique_integer([:positive])}"
  end

  defp load_hooks(cwd) do
    case Raxol.Agent.Code.Hooks.load(cwd) do
      {:ok, config} -> {config, "#{Raxol.Agent.Code.Hooks.count(config)} hooks"}
      :none -> {nil, nil}
      {:error, reason} -> {nil, "hooks config error: #{inspect(reason)}"}
    end
  end

  defp load_mcp(cwd) do
    case Raxol.Agent.Code.McpConfig.load(cwd) do
      {:ok, []} -> {[], nil}
      {:ok, servers} -> {servers, "#{length(servers)} MCP servers"}
      :none -> {[], nil}
      {:error, reason} -> {[], "mcp config error: #{inspect(reason)}"}
    end
  end

  defp combine_notes(notes) do
    case Enum.reject(notes, &is_nil/1) do
      [] -> nil
      list -> Enum.join(list, " · ")
    end
  end

  # -- update: keyboard -------------------------------------------------------

  @impl true
  def update(%Raxol.Core.Events.Event{} = event, model) do
    model = maybe_launch_validation(model)
    norm = InputEvent.normalize(event)

    cond do
      # The credential/save steps are modal: they own the keyboard so a pasted
      # key never leaks into the prompt buffer or a slash command.
      modal_wizard?(model) ->
        handle_wizard(norm, model)

      InputEvent.shortcut?(norm) ->
        handle_shortcut(norm, model)

      InputEvent.text?(norm) ->
        handle_char(InputEvent.printable_char(norm), model)

      key = InputEvent.key(norm) ->
        handle_key(key, model)

      true ->
        {model, []}
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

    decision =
      Engine.evaluate(auth_policies(), :tool_call, context, model.auth_state)

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

  # An async `/login` validation ping result. Applied only when its ref still
  # matches the latest login (a newer `/login` supersedes an in-flight check).
  def update(
        {:command_result, {:login_validation, ref, harness, result}},
        model
      ) do
    if ref == model.login_ref do
      {%{
         model
         | status_line: validation_status(harness, result),
           login_ref: nil
       }, []}
    else
      {model, []}
    end
  end

  def update(_message, model), do: {model, []}

  # Fire the armed launch validation on the first update (dispatcher process).
  defp maybe_launch_validation(%{pending_validation: nil} = model), do: model

  defp maybe_launch_validation(%{pending_validation: executor} = model) do
    ref = start_login_validation(model, executor)

    %{
      model
      | pending_validation: nil,
        login_ref: ref,
        status_line: "validating #{executor.backend} credential…"
    }
  end

  defp modal_wizard?(%{wizard: %{step: step}})
       when step in [:credential, :confirm_save], do: true

  defp modal_wizard?(_model), do: false

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

  # In browse mode, ↑/↓ move the provider cursor; Enter on an empty prompt
  # selects it. A typed prompt or slash command still takes precedence (so the
  # `/login <provider> ...` text path stays reachable alongside the wizard).
  defp handle_key(:up, %{wizard: %{step: :browse}} = model),
    do: {wizard_move(model, -1), []}

  defp handle_key(:down, %{wizard: %{step: :browse}} = model),
    do: {wizard_move(model, +1), []}

  defp handle_key(:enter, model) do
    case String.trim(model.input) do
      "" -> {maybe_wizard_select(model), []}
      "/" <> _ = command -> dispatch_slash(%{model | input: ""}, command)
      prompt -> {submit_prompt(model, prompt), []}
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

  # Esc closes the browse list (reopen with /login); the modal steps handle
  # their own Esc in handle_wizard/2.
  defp handle_key(:escape, %{wizard: %{step: :browse}} = model),
    do: {close_wizard(model), []}

  defp handle_key(_key, model), do: {model, []}

  # A prompt only starts a turn once a provider is connected; otherwise the
  # input is kept and a hint steers the user to `/login` (slash commands still
  # run, so `/login` itself is always reachable).
  defp submit_prompt(model, prompt) do
    if provider_ready?(model) do
      start_turn(model, prompt)
    else
      notice(model, provider_setup_hint(model))
    end
  end

  defp provider_ready?(%{provider_status: :ready}), do: true

  defp provider_ready?(%{provider_status: {:ready, _harness, _source}}),
    do: true

  defp provider_ready?(_model), do: false

  # Plan mode only toggles when idle — flipping it mid-turn or mid-approval
  # would be surprising (the toolset/prompt are fixed at turn start).
  defp maybe_toggle_plan_mode(%{running?: true} = model), do: model
  defp maybe_toggle_plan_mode(%{pending_approval: %{}} = model), do: model

  defp maybe_toggle_plan_mode(model),
    do: %{model | plan_mode: not model.plan_mode}

  # -- turn lifecycle ---------------------------------------------------------

  defp start_turn(model, prompt) do
    session_id = "code-#{System.unique_integer([:positive])}"
    ensure_streamer!()
    app = self()

    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    messages = model.messages ++ [%{role: :user, content: prompt}]

    opts =
      [
        backend_opts: model.backend_opts,
        system_prompt: system_prompt(model),
        actions: model.actions,
        messages: messages,
        context: run_context(model, app)
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
        Contract.pump(session_id, Raxol.Agent.Stream.react(prompt, opts),
          prompt: prompt
        )
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

  # The run context: the human-in-the-loop authorizer, the sub-agent backend
  # (for the `task` tool), and any settings-file tool-call hooks.
  defp run_context(model, app) do
    %{
      tool_authorizer: tool_authorizer(app),
      subagent: %{
        executor: model.executor,
        backend_opts: model.backend_opts,
        model: model.model_override
      }
    }
    |> maybe_add_hooks(model)
  end

  defp maybe_add_hooks(context, %{hooks: nil}), do: context

  defp maybe_add_hooks(context, %{hooks: config, cwd: cwd}) do
    Map.merge(context, %{
      tool_call_hooks: [Raxol.Agent.Code.Hooks],
      code_hooks: config,
      hook_cwd: cwd
    })
  end

  defp run_stop_hooks(%{hooks: nil}), do: :ok

  defp run_stop_hooks(%{hooks: config, cwd: cwd}) do
    spawn(fn -> Raxol.Agent.Code.Hooks.run_stop(config, cwd) end)
    :ok
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

    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    events = model.events ++ [normalized]

    model = %{
      model
      | events: events,
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
        %{
          model
          | turn_answer:
              model.turn_answer <> to_string(payload_content(payload))
        }

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
      run_stop_hooks(model)
      persist(%{model | messages: messages, turn_answer: ""})
    else
      model
    end
  end

  defp finalize_turn(model, %{type: :error} = event) do
    model = persist(%{model | turn_answer: ""})

    # A credential rejected mid-session (revoked/expired key) routes back to
    # onboarding instead of leaving the bare error face. The conversation is
    # preserved (messages are untouched here), so `/login` reconnects and the
    # user continues where they left off.
    if auth_rejected?(error_reason(event)),
      do: to_reauth(model),
      else: model
  end

  defp finalize_turn(model, _event), do: model

  defp error_reason(%{payload: payload}) when is_map(payload),
    do: Map.get(payload, :reason) || Map.get(payload, "reason")

  defp error_reason(_event), do: nil

  # Flip the provider back to its unconnected state so the setup panel shows
  # and `submit_prompt/2` gates further turns until `/login` reconnects.
  defp to_reauth(model) do
    backend = current_backend(model)

    %{
      model
      | provider_status: {:no_key, backend},
        notice: "auth failed for #{backend} — run /login to reconnect"
    }
  end

  defp current_backend(%{provider_status: {:ready, backend, _source}}),
    do: backend

  defp current_backend(%{executor: %{backend: backend}})
       when not is_nil(backend),
       do: backend

  defp current_backend(_model), do: :unknown

  defp append_assistant(messages, answer) do
    case String.trim(answer) do
      "" ->
        messages

      trimmed ->
        # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
        messages ++ [%{role: :assistant, content: trimmed}]
    end
  end

  defp payload_content(payload),
    do: Map.get(payload, :content) || Map.get(payload, "content") || ""

  defp persist(model) do
    case Raxol.Agent.Code.Store.save(model.sessions_dir, model.session_key, %{
           messages: model.messages,
           events: durable_events(model.events)
         }) do
      :ok ->
        model

      {:error, reason} ->
        %{model | status_line: "session save failed: #{inspect(reason)}"}
    end
  end

  # Only durable events rebuild the transcript on resume; ephemeral deltas are
  # live-render-only and never persisted.
  defp durable_events(events), do: Enum.filter(events, &(&1.tier == :durable))

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

        send(
          app,
          {:command_result, {:authorize_request, ref, self(), meta.name}}
        )

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
    apply_command(name, arg, model)
  end

  defp apply_command("help", _arg, model), do: {notice(model, help_text()), []}
  defp apply_command("login", arg, model), do: {login(model, arg), []}
  defp apply_command("clear", _arg, model), do: {clear_session(model), []}

  defp apply_command("plan", _arg, model),
    do: {maybe_toggle_plan_mode(model), []}

  defp apply_command("model", arg, model), do: {set_model(model, arg), []}

  defp apply_command("context", _arg, model),
    do: {notice(model, context_text(model)), []}

  defp apply_command("compact", _arg, model), do: {compact(model), []}

  defp apply_command("sessions", _arg, model),
    do: {notice(model, sessions_text(model)), []}

  defp apply_command("mcp", _arg, model),
    do: {notice(model, mcp_text(model)), []}

  defp apply_command("hooks", _arg, model),
    do: {notice(model, hooks_text(model)), []}

  defp apply_command(other, _arg, model),
    do: {notice(model, "unknown command: /#{other} — try /help"), []}

  defp mcp_text(%{mcp_servers: []}), do: "no MCP servers configured (.mcp.json)"

  defp mcp_text(%{mcp_servers: servers}) do
    Enum.map_join(servers, "\n", fn s ->
      "#{s.name}  →  #{s.command} #{Enum.join(s.args, " ")}"
    end)
  end

  defp hooks_text(%{hooks: nil}), do: "no hooks configured (.raxol/hooks.json)"

  defp hooks_text(%{hooks: config}) do
    "pre_tool_use: #{length(config.pre)} · post_tool_use: #{length(config.post)} · " <>
      "stop: #{length(config.stop)}"
  end

  # -- /login: connect a provider --------------------------------------------

  # `/login`                         -> status + usage
  # `/login <provider>`              -> connect via op/env (or keyless local)
  # `/login <provider> op://ref`     -> store the 1Password reference + connect
  # `/login <provider> <key>`        -> session-only key (never persisted)
  # a trailing token is taken as a model override.
  defp login(model, arg) do
    case String.split(String.trim(arg), ~r/\s+/, trim: true) do
      [] ->
        open_browse(model)

      [provider] ->
        login_provider(model, provider, nil, nil)

      [provider, secret] ->
        login_provider(model, provider, secret, nil)

      [provider, secret, model_name | _] ->
        login_provider(model, provider, secret, model_name)
    end
  end

  defp login_provider(model, provider_str, secret, model_name) do
    case Raxol.Agent.Backend.Resolver.harness_from_string(provider_str) do
      {:ok, harness} ->
        connect(model, harness, secret, model_name)

      :error ->
        notice(
          model,
          "unknown provider: #{provider_str}\n\n" <> login_status_text()
        )
    end
  end

  # An op:// reference is stored (so it survives relaunch) then resolved; a raw
  # key stays in memory for this session only; no secret connects via op/env.
  defp connect(model, harness, "op://" <> _ = ref, model_name) do
    case Raxol.Agent.Backend.Credentials.put(
           harness,
           put_model([op_ref: ref], model_name)
         ) do
      :ok ->
        resolve_and_connect(model, harness, [], "op reference stored")

      {:error, reason} ->
        notice(model, "could not store reference: #{inspect(reason)}")
    end
  end

  defp connect(model, harness, secret, model_name) when is_binary(secret) do
    resolve_and_connect(
      model,
      harness,
      put_model([api_key: secret], model_name),
      "session key — not persisted"
    )
  end

  defp connect(model, harness, nil, model_name) do
    resolve_and_connect(model, harness, put_model([], model_name), nil)
  end

  defp resolve_and_connect(model, harness, extra_opts, note) do
    opts = Keyword.put(extra_opts, :harness, harness)

    case Raxol.Agent.Backend.Resolver.resolve(opts) do
      {:ok, executor, source} ->
        # Fire a cheap, async validation ping; its result arrives as a
        # `{:login_validation, ...}` message and updates the status line. The
        # connection is marked ready immediately either way — validation only
        # annotates it, so a slow or offline check never blocks the TUI.
        ref = start_login_validation(model, executor)

        %{
          model
          | executor: executor,
            provider_status: {:ready, harness, source},
            model_override: executor.model || model.model_override,
            login_ref: ref,
            wizard: nil
        }
        |> notice(connect_note(harness, source, note))
        |> put_status("connected to #{harness} — validating credential…")

      {:no_key, ^harness} ->
        notice(
          model,
          "no credential found for #{harness}. Supply one:\n" <>
            "  /login #{harness} op://Vault/Item/field   (1Password)\n" <>
            "  /login #{harness} <api-key>               (this session only)"
        )

      :no_provider ->
        notice(model, "could not resolve a provider for #{harness}")
    end
  end

  defp put_model(opts, nil), do: opts
  defp put_model(opts, ""), do: opts
  defp put_model(opts, model_name), do: Keyword.put(opts, :model, model_name)

  defp connect_note(harness, source, nil),
    do: "connected to #{harness} (via #{source})"

  defp connect_note(harness, source, note),
    do: "connected to #{harness} (via #{source}) — #{note}"

  defp put_status(model, text), do: %{model | status_line: text}

  # Kick off the injectable validator, returning the ref that stamps its
  # result. `self()` here is the app process, so the ping's reply message lands
  # where `update/2` can fold it.
  defp start_login_validation(model, executor) do
    ref = make_ref()
    model.login_validator.(executor, ref, self())
    ref
  end

  @doc false
  # The default validator: a cheap, single-token completion against the freshly
  # resolved backend, off the app process so a hung endpoint never blocks the
  # TUI. The normalized outcome rides back as a `:login_validation` message.
  def default_login_validator(executor, ref, app) do
    spawn(fn ->
      result =
        try do
          do_validate_ping(executor)
        rescue
          _ -> :unreachable
        catch
          _, _ -> :unreachable
        end

      send(
        app,
        {:command_result, {:login_validation, ref, executor.backend, result}}
      )
    end)

    :ok
  end

  defp do_validate_ping(executor) do
    case Raxol.Agent.Backend.Selector.select(executor) do
      {:ok, backend, opts} -> validate_backend(backend, opts)
      {:error, reason} -> {:select_error, reason}
    end
  end

  # Prefer the token-free model-list auth check for the HTTP backend; only an
  # ambiguous result (unsupported endpoint, or reachable-but-odd-status) falls
  # back to the authoritative single-token completion ping.
  defp validate_backend(Raxol.Agent.Backend.HTTP = backend, opts) do
    case Raxol.Agent.Backend.HTTP.check_auth(opts) do
      :unsupported -> ping_completion(backend, opts)
      {:reachable_error, _status} -> ping_completion(backend, opts)
      verdict -> verdict
    end
  end

  defp validate_backend(backend, opts), do: ping_completion(backend, opts)

  defp ping_completion(backend, opts) do
    ping_opts =
      opts |> Keyword.put(:max_tokens, 1) |> Keyword.put(:timeout, 10_000)

    interpret_ping(
      backend.complete([%{role: :user, content: "ping"}], ping_opts)
    )
  end

  @doc false
  # Classify a backend `complete/2` return by what it says about the credential.
  # Auth is the question: a 401/403 rejects; a reachable endpoint that answered
  # (even a truncated/unparseable body) authorized the request, so it is valid.
  def interpret_ping({:ok, _response}), do: :valid

  def interpret_ping({:error, {:http_error, status, _body} = reason}) do
    if auth_rejected?(reason),
      do: {:rejected, status},
      else: {:reachable_error, status}
  end

  def interpret_ping({:error, {:request_failed, _reason}}), do: :unreachable
  def interpret_ping({:error, :req_not_available}), do: :req_unavailable
  def interpret_ping({:error, _marker}), do: :valid

  @doc false
  # Shared credential-rejection classifier for a backend error term — used by
  # both the `/login` ping (interpret_ping/1) and the mid-turn error fold
  # (finalize_turn on a contract `:error` event). Recognizes the structured
  # `complete/2` shape (`{:http_error, 401|403, _}`) and the streaming shape
  # (the "HTTP 401"/"HTTP 403" string `Backend.HTTP.stream/2` surfaces as its
  # error element).
  def auth_rejected?({:http_error, status, _body}) when status in [401, 403],
    do: true

  def auth_rejected?(reason) when is_binary(reason),
    do: reason =~ ~r/\bHTTP (401|403)\b/

  def auth_rejected?(_reason), do: false

  defp validation_status(harness, :valid),
    do: "#{harness} credential validated ●"

  defp validation_status(harness, {:rejected, status}),
    do: "#{harness} key rejected (HTTP #{status}) — check /login"

  defp validation_status(harness, :unreachable),
    do: "#{harness} endpoint unreachable — is it running?"

  defp validation_status(harness, {:reachable_error, status}),
    do: "#{harness} reachable but returned HTTP #{status}"

  defp validation_status(harness, {:select_error, reason}),
    do: "#{harness} cannot validate: #{inspect(reason)}"

  defp validation_status(harness, :req_unavailable),
    do: "#{harness} connected (Req unavailable, validation skipped)"

  defp validation_status(harness, _other), do: "#{harness} connected"

  # -- onboarding wizard ------------------------------------------------------

  defp open_browse(model) do
    entries = browse_entries()
    cursor = default_cursor(entries)

    %{
      model
      | wizard: %{step: :browse, cursor: cursor, entries: entries},
        notice: nil
    }
  end

  # Provider rows for the list, carrying the diagnostics so the panel can show
  # availability + an actionable note per provider.
  defp browse_entries, do: Raxol.Agent.Backend.Resolver.diagnostics().providers

  # Start the cursor on the first available provider, else the top.
  defp default_cursor(entries) do
    case Enum.find_index(entries, & &1.available?) do
      nil -> 0
      idx -> idx
    end
  end

  defp wizard_move(
         %{wizard: %{entries: entries, cursor: cursor} = wizard} = model,
         delta
       ) do
    max = max(length(entries) - 1, 0)
    next = min(max, max(0, cursor + delta))
    %{model | wizard: %{wizard | cursor: next}}
  end

  defp maybe_wizard_select(
         %{wizard: %{step: :browse, entries: entries, cursor: cursor}} = model
       ) do
    case Enum.at(entries, cursor) do
      nil -> model
      entry -> select_provider(model, entry.harness, entry.keyless?)
    end
  end

  defp maybe_wizard_select(model), do: model

  # A keyless provider connects immediately; a keyed one opens masked entry.
  defp select_provider(model, harness, true) do
    model |> connect(harness, nil, nil) |> close_wizard_if_ready()
  end

  defp select_provider(model, harness, false) do
    %{
      model
      | wizard: %{step: :credential, harness: harness, buffer: ""},
        notice:
          "#{harness}: paste an op:// reference (saved) or an API key (Enter to submit, Esc to cancel)"
    }
  end

  defp close_wizard(model), do: %{model | wizard: nil}

  defp close_wizard_if_ready(model) do
    if provider_ready?(model), do: close_wizard(model), else: model
  end

  # -- wizard: modal steps (own the keyboard) ---------------------------------

  defp handle_wizard(norm, %{wizard: %{step: :credential}} = model) do
    cond do
      InputEvent.text?(norm) ->
        {append_credential(model, InputEvent.printable_char(norm)), []}

      InputEvent.key(norm) == :enter ->
        {submit_credential(model), []}

      InputEvent.key(norm) == :backspace ->
        {backspace_credential(model), []}

      InputEvent.key(norm) == :escape ->
        {open_browse(model), []}

      true ->
        {model, []}
    end
  end

  defp handle_wizard(norm, %{wizard: %{step: :confirm_save}} = model) do
    cond do
      InputEvent.printable_char(norm) in ["y", "Y"] ->
        {save_key_to_op(model), []}

      InputEvent.printable_char(norm) in ["n", "N"] ->
        {decline_save(model), []}

      InputEvent.key(norm) == :escape ->
        {decline_save(model), []}

      true ->
        {model, []}
    end
  end

  defp append_credential(%{wizard: wizard} = model, char),
    do: %{model | wizard: %{wizard | buffer: wizard.buffer <> char}}

  defp backspace_credential(%{wizard: %{buffer: buffer} = wizard} = model),
    do: %{model | wizard: %{wizard | buffer: String.slice(buffer, 0..-2//1)}}

  # An op:// reference stores + connects; a raw key connects for this session
  # and (if op is available) offers to save it to 1Password.
  defp submit_credential(%{wizard: %{harness: harness, buffer: buffer}} = model) do
    trimmed = String.trim(buffer)

    cond do
      trimmed == "" ->
        model

      String.starts_with?(trimmed, "op://") ->
        model |> connect(harness, trimmed, nil) |> close_wizard_if_ready()

      true ->
        model
        |> connect(harness, trimmed, nil)
        |> maybe_offer_save(harness, trimmed)
    end
  end

  defp maybe_offer_save(model, harness, key) do
    if Raxol.Agent.Backend.Credentials.op_available?() do
      %{
        model
        | wizard: %{step: :confirm_save, harness: harness, key: key},
          notice:
            "Save this #{harness} key to 1Password?  [y] yes   [n] keep for this session"
      }
    else
      close_wizard(model)
    end
  end

  defp save_key_to_op(%{wizard: %{harness: harness, key: key}} = model) do
    case model.op_saver.(harness, key) do
      {:ok, ref} ->
        _ = Raxol.Agent.Backend.Credentials.put(harness, op_ref: ref)

        model
        |> close_wizard()
        |> notice("saved #{harness} key to 1Password (#{ref})")

      {:error, reason} ->
        model
        |> close_wizard()
        |> notice(
          "could not save to 1Password: #{inspect(reason)} — key kept for this session"
        )
    end
  end

  defp decline_save(%{wizard: %{harness: harness}} = model),
    do:
      model
      |> close_wizard()
      |> notice("#{harness} key kept for this session only")

  @doc false
  def default_op_saver(harness, key),
    do: Raxol.Agent.Backend.Credentials.create_item(harness, key)

  defp login_status_text do
    rows =
      Raxol.Agent.Backend.Resolver.status()
      |> Enum.map_join("\n", fn s ->
        mark = if s.available?, do: "●", else: "○"
        src = if s.source, do: " (#{s.source})", else: ""
        "  #{mark} #{s.harness}#{src}"
      end)

    """
    Connect a provider with /login:
      /login anthropic op://Vault/Anthropic/key   1Password reference (persisted)
      /login openai sk-...                         session key (not saved)
      /login lm_studio                             local server (no key)

    ● connected  ○ not connected
    #{rows}
    """
    |> String.trim_trailing()
  end

  # Shown on the setup panel and as the hint when a prompt is sent with no
  # provider connected.
  defp provider_setup_hint(%{provider_status: {:no_key, harness}}) do
    "harness #{harness} was selected but no key resolved.\n\n" <>
      login_status_text()
  end

  defp provider_setup_hint(_model) do
    "No LLM provider connected.\n\n" <> login_status_text()
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
    notice(
      model,
      "usage: /model <name>  (current: #{model.model_override || "default"})"
    )
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

      marker = %{
        role: :system,
        content: "[#{length(older)} earlier messages compacted]"
      }

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
    /login [provider]  connect an LLM provider (op ref, key, or local)
    /clear             start a fresh session
    /model <name>      switch model for the next turns
    /plan              toggle plan mode
    /compact           shrink the conversation history
    /context           session stats
    /sessions          list saved sessions
    /mcp               list configured MCP servers
    /hooks             show configured lifecycle hooks
    """
    |> String.trim_trailing()
  end

  # -- view -------------------------------------------------------------------

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1} do
      [
        transcript(model),
        setup_block(model),
        notice_block(model),
        status_strip(model),
        footer(model)
      ]
      |> Enum.reject(&is_nil/1)
    end
  end

  # The onboarding panel: the wizard when one is open, else a static hint when
  # unconnected, else nothing. Keeps the TUI on "connect a provider" instead of
  # failing an invisible request.
  defp setup_block(%{wizard: %{step: :browse} = wizard}),
    do: browse_panel(wizard)

  defp setup_block(%{wizard: %{step: :credential} = wizard}),
    do: credential_panel(wizard)

  defp setup_block(%{wizard: %{step: :confirm_save} = wizard}),
    do: confirm_save_panel(wizard)

  defp setup_block(model) do
    if provider_ready?(model), do: nil, else: hint_panel(model)
  end

  defp browse_panel(%{entries: entries, cursor: cursor}) do
    rows =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} -> provider_row(entry, index == cursor) end)

    box style: %{border: :single, padding: 0} do
      column style: %{gap: 0} do
        [
          text("connect a provider  (↑↓ move · Enter connect · Esc cancel)",
            fg: :yellow,
            style: [:bold]
          )
        ] ++ rows
      end
    end
  end

  defp provider_row(entry, selected?) do
    marker = if selected?, do: "▸", else: " "
    avail = if entry.available?, do: "●", else: "○"
    note = if entry.note, do: "  #{entry.note}", else: ""
    fg = if selected?, do: :cyan, else: :white
    style = if selected?, do: [:bold], else: []
    text("#{marker} #{avail} #{entry.label}#{note}", fg: fg, style: style)
  end

  defp credential_panel(%{harness: harness, buffer: buffer}) do
    shown =
      if String.starts_with?(buffer, "op://"),
        do: buffer,
        else: String.duplicate("•", String.length(buffer))

    box style: %{border: :single, padding: 0} do
      column style: %{gap: 0} do
        [
          text("connect #{harness}", fg: :yellow, style: [:bold]),
          text("credential: #{shown}▌", fg: :cyan),
          text("op:// reference is stored; a raw key can be saved to 1Password",
            style: [:dim]
          )
        ]
      end
    end
  end

  defp confirm_save_panel(%{harness: harness}) do
    box style: %{border: :single, padding: 0} do
      text(
        "Save #{harness} key to 1Password?  [y] yes   [n] keep for this session",
        fg: :yellow
      )
    end
  end

  defp hint_panel(model) do
    lines = String.split(provider_setup_hint(model), "\n")

    box style: %{border: :single, padding: 0} do
      column style: %{gap: 0} do
        [text("connect a provider to begin", fg: :yellow, style: [:bold])] ++
          Enum.map(lines, &text(&1, fg: :cyan))
      end
    end
  end

  defp notice_block(%{notice: notice}) when is_binary(notice) do
    lines = String.split(notice, "\n")

    box style: %{border: :single, padding: 0} do
      column style: %{gap: 0} do
        Enum.map(lines, &text(&1, fg: :cyan))
      end
    end
  end

  defp notice_block(_model), do: nil

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
      [face, plan_chip(model), status] |> Enum.reject(&is_nil/1)
    end
  end

  defp plan_chip(%{plan_mode: true}),
    do: text("PLAN", fg: :yellow, style: [:bold])

  defp plan_chip(_model), do: nil

  defp status_label(%{status_line: line}) when is_binary(line), do: line

  defp status_label(%{pending_approval: %{name: name}}),
    do: "awaiting approval: #{name}"

  defp status_label(%{provider_status: {:no_key, harness}}),
    do: "no key for #{harness} — /login"

  defp status_label(%{provider_status: :no_provider}),
    do: "no provider — /login"

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
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        raise "cannot start SessionStreamer: #{inspect(reason)}"
    end
  end

  defp default_actions do
    Raxol.Agent.Actions.Fs.all() ++
      Raxol.Agent.Actions.Code.all() ++
      Raxol.Agent.Actions.Task.all()
  end

  defp default_system do
    "You are a coding assistant running in a terminal at the user's " <>
      "current working directory. Read files before editing them. Use " <>
      "write_file/edit_file to change code and bash to run commands. Be concise."
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
