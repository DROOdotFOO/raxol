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
  alias Raxol.Agent.Journal.FileStore
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

    session = init_session(options)

    cwd = Keyword.get(options, :cwd) || Raxol.Agent.Actions.Fs.working_dir()
    {hooks, hooks_note} = load_hooks(cwd)
    {mcp_servers, mcp_note} = load_mcp(cwd)

    config(options, context)
    |> Map.merge(%{
      # Seeded from a resumed session so the transcript + conversation
      # rebuild immediately; a fresh session starts these empty. Resumed
      # events arrive renumbered 1..n, so the live fold continues at n+1.
      events: session.events,
      next_event_id: length(session.events) + 1,
      messages: session.messages,
      status_line: combine_notes([session.notice, hooks_note, mcp_note]),
      session_key: session.key,
      sessions_dir: session.dir,
      title: session.title,
      parent: session.parent,
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
      # `/model` with no arg fetches the connected provider's model list off
      # the app process; the result rides back as a `:models_list` message
      # matched by this ref. Injectable so tests drive it without a network
      # call, mirroring `:login_validator`.
      models_ref: nil,
      models_fetcher:
        Keyword.get(
          options,
          :models_fetcher,
          &__MODULE__.default_models_fetcher/3
        ),
      # `/resume` with no arg lists saved sessions off the app process
      # (Store.list reads every session file); the result rides back as a
      # `:sessions_list` message matched by this ref. Injectable,
      # mirroring `:models_fetcher`.
      sessions_ref: nil,
      sessions_fetcher:
        Keyword.get(
          options,
          :sessions_fetcher,
          &__MODULE__.default_sessions_fetcher/3
        ),
      # `/inspect` gathers off the app process (provider probing may shell
      # out to `op`, which must never stall the update loop); the rendered
      # snapshot rides back as an `:inspection_result` message matched by
      # this ref. Injectable, mirroring `:models_fetcher`.
      inspection_ref: nil,
      inspection_fetcher:
        Keyword.get(
          options,
          :inspection_fetcher,
          &__MODULE__.default_inspection_fetcher/4
        ),
      # `.mcp.json` servers bridge into the toolset asynchronously: armed at
      # init, launched on the first update (the dispatcher process, where the
      # result message must land), folded into `:actions` when tools arrive.
      # Injectable, mirroring `:models_fetcher`.
      mcp_ref: nil,
      mcp_status: nil,
      mcp_janitor: nil,
      mcp_loader:
        Keyword.get(options, :mcp_loader, &__MODULE__.default_mcp_loader/3),
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
      # `/copy` and `/logout <provider>` reach system state (clipboard,
      # the stored-credentials file); injectable so tests stay hermetic.
      clipboard:
        Keyword.get(options, :clipboard, &Raxol.System.Clipboard.copy/1),
      credential_remover:
        Keyword.get(options, :credential_remover, &Raxol.Agent.Setup.remove/1),
      # The durable journal handle, opened lazily on the first durable
      # event so idle sessions never spawn a Writer. `:journal_opts` is
      # forwarded to `FileStore.open/2` (tests set `:base_dir` here).
      journal: nil,
      journal_opts: Keyword.get(options, :journal_opts, []),
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
        fresh_session(dir)

      key ->
        case Raxol.Agent.Code.Store.load(dir, key) do
          {:ok, %{messages: messages, events: events} = saved} ->
            %{
              dir: dir,
              key: key,
              messages: messages,
              events: renumber_events(events),
              notice: "resumed #{length(messages)} messages",
              title: Map.get(saved, :title, ""),
              parent: Map.get(saved, :parent)
            }

          {:error, _} ->
            %{
              fresh_session(dir)
              | key: key,
                notice: "session #{key} not found — starting fresh"
            }
        end
    end
  end

  defp fresh_session(dir) do
    %{
      dir: dir,
      key: mint_session_key(),
      messages: [],
      events: [],
      notice: nil,
      title: "",
      parent: nil
    }
  end

  # Stored ids are whatever the producer stamped at the time (historically
  # per-turn pump counters, which collide across turns) and the durable-only
  # filter leaves gaps; both make the projection's id recovery drop or
  # diagnose resumed events on every render. Ids only order the projection
  # fold, so a resumed log is renumbered into the dense session space the
  # live fold continues from.
  defp renumber_events(events) do
    events
    |> Enum.with_index(1)
    |> Enum.map(fn {event, index} -> %{event | id: index} end)
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
    model = model |> maybe_launch_validation() |> maybe_launch_mcp()
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

  # An async `/model` model-list fetch result. Applied only when its ref still
  # matches the latest fetch (a newer `/model` supersedes an in-flight one).
  # An async `/resume` session list. Same ref discipline as `:models_list`.
  def update({:command_result, {:sessions_list, ref, sessions}}, model) do
    if ref == model.sessions_ref do
      {apply_sessions_result(model, sessions), []}
    else
      {model, []}
    end
  end

  def update({:command_result, {:models_list, ref, result}}, model) do
    if ref == model.models_ref,
      do: {apply_models_result(model, result), []},
      else: {model, []}
  end

  # An async `/inspect` snapshot. Same ref discipline as `:models_list`.
  def update({:command_result, {:inspection_result, ref, text}}, model) do
    if ref == model.inspection_ref,
      do: {notice(%{model | inspection_ref: nil, status_line: nil}, text), []},
      else: {model, []}
  end

  # The async `.mcp.json` bundle result: fold the discovered tools into the
  # toolset and record per-server state for `/mcp`. Same ref discipline.
  def update({:command_result, {:mcp_loaded, ref, result}}, model) do
    if ref == model.mcp_ref do
      model = %{
        model
        | mcp_ref: nil,
          mcp_janitor: result.janitor,
          mcp_status: %{
            connected: result.connected,
            failed: result.failed,
            tools: length(result.tools)
          },
          actions: model.actions ++ result.tools
      }

      {put_status(model, mcp_loaded_line(result)), []}
    else
      {model, []}
    end
  end

  def update(_message, model), do: {model, []}

  # Fire the armed `.mcp.json` bundle load on the first update (the
  # dispatcher process, where the `:mcp_loaded` result must land). Loading
  # is off-process, so a slow server handshake never stalls boot or input.
  defp maybe_launch_mcp(%{mcp_servers: []} = model), do: model

  defp maybe_launch_mcp(%{mcp_ref: nil, mcp_status: nil} = model) do
    ref = make_ref()
    model.mcp_loader.(model.mcp_servers, ref, self())

    %{model | mcp_ref: ref, mcp_status: :loading}
  end

  defp maybe_launch_mcp(model), do: model

  @doc false
  # Default loader: bridge the configured servers off the app process; the
  # result rides back as an `:mcp_loaded` message `update/2` folds.
  def default_mcp_loader(servers, ref, app) do
    # The janitor monitors `app` (the dispatcher/session process), so the
    # started clients are torn down whenever this session ends.
    spawn(fn ->
      result = Raxol.Agent.Code.McpLoader.load(servers, owner: app)
      send(app, {:command_result, {:mcp_loaded, ref, result}})
    end)
  end

  defp mcp_loaded_line(%{tools: [], failed: []}), do: "mcp: no tools discovered"

  defp mcp_loaded_line(%{tools: tools, connected: connected, failed: []}) do
    "mcp: #{length(tools)} tools from #{length(connected)} servers"
  end

  defp mcp_loaded_line(%{tools: tools, failed: failed}) do
    names =
      Enum.map_join(failed, ", ", fn {name, _reason} -> to_string(name) end)

    "mcp: #{length(tools)} tools · failed: #{names}"
  end

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
    # Fast-path cleanup: stop the MCP janitor (and its clients) and flush
    # the journal on an explicit quit. Both also survive any other exit
    # path — the janitor monitors this process, and the journal Writer is
    # linked to it (its terminate flushes).
    Raxol.Agent.Code.McpLoader.stop(model.mcp_janitor)
    close_journal(model.journal)
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
  defp handle_key(:up, %{wizard: %{step: step}} = model)
       when step in [:browse, :models, :sessions],
       do: {wizard_move(model, -1), []}

  defp handle_key(:down, %{wizard: %{step: step}} = model)
       when step in [:browse, :models, :sessions],
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

  # Esc closes the browse/model list (reopen with /login or /model); the modal
  # steps handle their own Esc in handle_wizard/2.
  defp handle_key(:escape, %{wizard: %{step: step}} = model)
       when step in [:browse, :models, :sessions],
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
    |> maybe_add_skills()
    |> maybe_add_hooks(model)
  end

  # Wire the configured skills store under context[:skills] so the skill actions
  # can reach it. No-op when skills are disabled (default_context returns nil).
  defp maybe_add_skills(context) do
    case Raxol.Agent.Skills.default_context() do
      nil -> context
      skills -> Map.put(context, :skills, skills)
    end
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

    # Producer ids restart every turn (`Contract.pump` stamps from a fresh
    # per-turn counter), but the projection's id recovery requires one
    # session-monotonic id space — colliding ids drop whole turns from the
    # transcript. The model is the id authority for its own event log: every
    # folded event is re-stamped from a session counter.
    normalized = %{normalized | id: model.next_event_id}

    {model, journal_warning} = journal_durable(model, normalized)

    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    events = model.events ++ [normalized]

    model = %{
      model
      | events: events,
        next_event_id: model.next_event_id + 1,
        face_state: face_for_event(event, model.face_state),
        face_frame: model.face_frame + 1,
        running?: running?,
        worker: if(running?, do: model.worker, else: nil),
        status_line:
          journal_warning ||
            if(running?, do: model.status_line, else: nil)
    }

    model
    |> accumulate_answer(event)
    |> finalize_turn(event)
  end

  # -- durable journal --------------------------------------------------------

  # Durable events land in the session's offset-addressed journal as they
  # fold, so the durable-tier stamp holds even if the process dies mid-turn
  # (the JSON store only persists on turn boundaries). Journal trouble never
  # blocks the fold: the event stays in the model either way and the failure
  # surfaces on the status line. A lost Writer drops the handle so the next
  # durable event reopens it.
  defp journal_durable(model, %{tier: :durable} = normalized) do
    case ensure_journal(model) do
      {:ok, model} ->
        case FileStore.append(model.journal, journal_record(model, normalized)) do
          {:ok, _offset} ->
            {model, nil}

          {:error, {:writer_down, _reason}} ->
            {%{model | journal: nil}, "journal writer lost — will reopen"}

          {:error, reason} ->
            {model, "journal append failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {model, "journal unavailable: #{inspect(reason)}"}
    end
  end

  defp journal_durable(model, _ephemeral), do: {model, nil}

  defp ensure_journal(%{journal: %FileStore{}} = model), do: {:ok, model}

  defp ensure_journal(model) do
    opts = Keyword.merge([cwd: model.cwd], model.journal_opts)

    case FileStore.open(model.session_key, opts) do
      {:ok, journal} -> {:ok, %{model | journal: journal}}
      {:error, _} = error -> error
    end
  end

  # The Writer stamps `id` (the journal offset) and stringifies keys; the
  # payload is already JSON-safe from the EventBoundary normalization.
  defp journal_record(model, normalized) do
    %{
      v: 0,
      session_id: model.session_key,
      turn_id: normalized.turn_id,
      ts: normalized.ts,
      family: normalized.family,
      type: normalized.type,
      tier: :durable,
      payload: normalized.payload
    }
  end

  defp close_journal(%FileStore{} = journal), do: FileStore.close(journal)
  defp close_journal(_none), do: :ok

  # -- /rewind ----------------------------------------------------------------

  # Drops the last turn from the transcript and the conversation in
  # lockstep. The journal is append-only, so the drop is recorded there as
  # a meta `:rewind` marker — replay applies markers in offset order and
  # so converges with the live session; the JSON store just persists the
  # truncated state.
  defp rewind(%{running?: true} = model),
    do: notice(model, "cannot rewind while a turn is running")

  defp rewind(model) do
    case last_turn_id(model.events) do
      nil ->
        notice(model, "nothing to rewind")

      turn_id ->
        {dropped, kept} =
          Enum.split_with(model.events, &(&1.turn_id == turn_id))

        {messages, dropped_messages} = drop_turn_messages(model.messages)
        {model, marker_warning} = journal_rewind_marker(model, turn_id)

        model =
          persist(%{
            model
            | events: kept,
              messages: messages,
              turn_answer: "",
              face_state: :idle
          })

        note =
          "rewound — dropped #{length(dropped)} events, " <>
            "#{dropped_messages} messages"

        notice(model, join_notes(note, marker_warning))
    end
  end

  defp join_notes(note, nil), do: note
  defp join_notes(note, warning), do: note <> " · " <> warning

  defp last_turn_id(events),
    do: events |> Enum.reverse() |> Enum.find_value(& &1.turn_id)

  # The turn's conversation tail is at most one user prompt plus one
  # assistant reply (an errored turn appends no reply).
  defp drop_turn_messages(messages) do
    case Enum.reverse(messages) do
      [%{role: :assistant}, %{role: :user} | rest] ->
        {Enum.reverse(rest), 2}

      [%{role: :assistant} | rest] ->
        {Enum.reverse(rest), 1}

      [%{role: :user} | rest] ->
        {Enum.reverse(rest), 1}

      _other ->
        {messages, 0}
    end
  end

  defp journal_rewind_marker(model, turn_id) do
    case ensure_journal(model) do
      {:ok, model} ->
        record = %{
          v: 0,
          session_id: model.session_key,
          turn_id: nil,
          ts: System.system_time(:microsecond),
          family: :meta,
          type: :rewind,
          tier: :durable,
          payload: %{"dropped_turn" => turn_id}
        }

        case FileStore.append(model.journal, record) do
          {:ok, _offset} ->
            {model, nil}

          {:error, _reason} ->
            {model, "journal marker failed — --replay may still show it"}
        end

      {:error, _reason} ->
        {model, "journal unavailable — --replay may still show it"}
    end
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
           events: durable_events(model.events),
           cwd: model.cwd,
           title: model.title,
           parent: model.parent
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

  @doc false
  # The `:tool_authorizer`: runs inside the react loop's process and defers
  # every sensitive tool call to the app for an Engine verdict, blocking until
  # the app answers. Non-sensitive tools are allowed without a round-trip.
  def tool_authorizer(app) do
    fn action, _params, _context ->
      {name, sensitive?} = action_identity(action)

      if sensitive? do
        ref = make_ref()

        send(
          app,
          {:command_result, {:authorize_request, ref, self(), name}}
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

  # Module Actions carry their identity in `__action_meta__/0`;
  # runtime-discovered MCP tools are `%Action.Dynamic{}` structs and carry it
  # on the struct (sensitive by default, so an external server's tool is
  # approval-gated per call — and denied outright in plan mode, since its
  # effects are unknown).
  defp action_identity(%Raxol.Agent.Action.Dynamic{
         name: name,
         sensitive: sensitive?
       }),
       do: {name, sensitive?}

  defp action_identity(module) when is_atom(module) do
    meta = module.__action_meta__()
    {meta.name, Map.get(meta, :sensitive, false)}
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

  defp apply_command("usage", _arg, model),
    do: {notice(model, usage_text(model)), []}

  defp apply_command("compact", _arg, model), do: {compact(model), []}

  defp apply_command("rewind", _arg, model), do: {rewind(model), []}

  defp apply_command("rename", arg, model),
    do: {rename(model, String.trim(arg)), []}

  defp apply_command("resume", arg, model) do
    case String.trim(arg) do
      "" -> {open_session_picker(model), []}
      key -> {switch_session(model, key), []}
    end
  end

  defp apply_command("fork", arg, model),
    do: {fork_session(model, String.trim(arg)), []}

  defp apply_command("export", arg, model),
    do: {export_session(model, String.trim(arg)), []}

  defp apply_command("transcript", _arg, model),
    do: {write_transcript(model), []}

  defp apply_command("copy", _arg, model), do: {copy_last_answer(model), []}

  defp apply_command("find", arg, model),
    do: {find_in_transcript(model, String.trim(arg)), []}

  defp apply_command("logout", arg, model),
    do: {logout(model, String.trim(arg)), []}

  defp apply_command("sessions", _arg, model),
    do: {notice(model, sessions_text(model)), []}

  defp apply_command("mcp", _arg, model),
    do: {notice(model, mcp_text(model)), []}

  defp apply_command("hooks", _arg, model),
    do: {notice(model, hooks_text(model)), []}

  defp apply_command("inspect", _arg, model) do
    ref = make_ref()
    model.inspection_fetcher.(model.cwd, model.sessions_dir, ref, self())
    {%{model | inspection_ref: ref} |> put_status("inspecting…"), []}
  end

  defp apply_command(other, _arg, model),
    do: {notice(model, "unknown command: /#{other} — try /help"), []}

  @doc false
  # Default fetcher: gather + render the snapshot off the app process (a
  # fresh disk read, the same snapshot `mix raxol.inspect` prints); the
  # result rides back as an `:inspection_result` message `update/2` folds.
  def default_inspection_fetcher(cwd, sessions_dir, ref, app) do
    spawn(fn ->
      text =
        cwd
        |> Raxol.Agent.Code.Inspection.gather(sessions_dir: sessions_dir)
        |> Raxol.Agent.Code.Inspection.render()

      send(app, {:command_result, {:inspection_result, ref, text}})
    end)
  end

  defp mcp_text(%{mcp_servers: []}), do: "no MCP servers configured (.mcp.json)"

  defp mcp_text(%{mcp_servers: servers} = model) do
    Enum.map_join(servers, "\n", fn s ->
      "#{server_mark(model.mcp_status, s.name)} #{s.name}  →  " <>
        "#{s.command} #{Enum.join(s.args, " ")}"
    end)
  end

  defp server_mark(:loading, _name), do: "…"
  defp server_mark(nil, _name), do: "○"

  defp server_mark(%{connected: connected, failed: failed}, name) do
    atom = String.to_existing_atom(name)

    cond do
      atom in connected -> "●"
      Enum.any?(failed, fn {n, _reason} -> n == atom end) -> "✗"
      true -> "○"
    end
  rescue
    ArgumentError -> "○"
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

  defp maybe_wizard_select(
         %{wizard: %{step: :sessions, entries: entries, cursor: cursor}} = model
       ) do
    case Enum.at(entries, cursor) do
      nil -> model
      entry -> switch_session(%{model | wizard: nil}, entry.id)
    end
  end

  defp maybe_wizard_select(
         %{wizard: %{step: :models, entries: entries, cursor: cursor}} = model
       ) do
    case Enum.at(entries, cursor) do
      nil ->
        model

      entry ->
        notice(
          %{model | model_override: entry.model, wizard: nil},
          "model set to #{entry.model}"
        )
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
  # clearing is never destructive to a prior conversation. The old journal
  # closes (flushing its Writer); the new session lazily opens its own.
  defp clear_session(model) do
    close_journal(model.journal)

    %{
      model
      | messages: [],
        events: [],
        journal: nil,
        next_event_id: 1,
        turn_answer: "",
        face_state: :idle,
        face_frame: 0,
        session_key: mint_session_key(),
        title: "",
        parent: nil,
        notice: "cleared — new session"
    }
  end

  # `/rename` titles the session; the title shows in `/sessions` and the
  # `/resume` picker, and persists with the session file.
  defp rename(model, ""), do: notice(model, "usage: /rename <title>")

  defp rename(model, title),
    do:
      %{model | title: title} |> persist() |> notice(~s(renamed to "#{title}"))

  # -- /resume + /fork --------------------------------------------------------

  defp open_session_picker(model) do
    ref = make_ref()
    model.sessions_fetcher.(model.sessions_dir, ref, self())
    %{model | sessions_ref: ref} |> put_status("listing sessions…")
  end

  @doc false
  # Lists sessions off the app process (Store.list reads every session
  # file); the result rides back as a `:sessions_list` message.
  def default_sessions_fetcher(dir, ref, app) do
    spawn(fn ->
      send(
        app,
        {:command_result,
         {:sessions_list, ref, Raxol.Agent.Code.Store.list(dir)}}
      )
    end)
  end

  defp apply_sessions_result(model, []) do
    %{model | sessions_ref: nil, status_line: nil}
    |> notice("no saved sessions")
  end

  defp apply_sessions_result(model, sessions) do
    entries =
      sessions
      |> Enum.take(20)
      |> Enum.map(&%{id: &1.id, label: session_line(&1)})

    cursor = Enum.find_index(entries, &(&1.id == model.session_key)) || 0

    %{
      model
      | sessions_ref: nil,
        status_line: nil,
        wizard: %{step: :sessions, entries: entries, cursor: cursor}
    }
  end

  # Switching persists the departing session first (nothing is lost),
  # closes its journal, and rebuilds transcript + conversation from the
  # target — the in-place version of `--resume`.
  defp switch_session(%{running?: true} = model, _key),
    do: notice(model, "cannot switch sessions while a turn is running")

  defp switch_session(%{session_key: key} = model, key),
    do: notice(model, "already in session #{key}")

  defp switch_session(model, key) do
    case Raxol.Agent.Code.Store.load(model.sessions_dir, key) do
      {:ok, saved} ->
        model = if session_dirty?(model), do: persist(model), else: model
        close_journal(model.journal)
        events = renumber_events(saved.events)

        %{
          model
          | session_key: key,
            messages: saved.messages,
            events: events,
            next_event_id: length(events) + 1,
            journal: nil,
            title: saved.title,
            parent: saved.parent,
            turn_answer: "",
            face_state: :idle,
            wizard: nil
        }
        |> notice("resumed #{key} (#{length(saved.messages)} messages)")

      {:error, :not_found} ->
        notice(model, "session #{key} not found — try /sessions")
    end
  end

  defp session_dirty?(model), do: model.messages != [] or model.events != []

  # Copy-fork: the conversation and transcript continue under a fresh key
  # whose store entry names its parent; the original session file stays
  # intact. The fork's journal starts fresh on its next durable event.
  defp fork_session(%{running?: true} = model, _title),
    do: notice(model, "cannot fork while a turn is running")

  defp fork_session(model, title) do
    if session_dirty?(model) do
      parent = model.session_key
      model = persist(model)
      close_journal(model.journal)
      new_key = mint_session_key()

      %{
        model
        | session_key: new_key,
          parent: parent,
          title: if(title == "", do: model.title, else: title),
          journal: nil
      }
      |> persist()
      |> notice("forked to #{new_key} (from #{parent})")
    else
      notice(model, "nothing to fork yet")
    end
  end

  # -- /export /transcript /copy /find /logout --------------------------------

  # `/export [path]` writes the transcript as plain text; the default
  # lands beside the work as `<session_key>.txt` in the cwd.
  defp export_session(model, path_arg) do
    path =
      case path_arg do
        "" -> Path.join(model.cwd, "#{model.session_key}.txt")
        given -> Path.expand(given, model.cwd)
      end

    write_transcript_file(model, path, "exported to #{path}")
  end

  # `/transcript` writes to a temp file and points a pager at it. The TUI
  # cannot suspend the terminal to host `$PAGER` itself (the driver owns
  # the tty), so the hint is the honest version.
  defp write_transcript(model) do
    path =
      Path.join(System.tmp_dir!(), "#{model.session_key}-transcript.txt")

    write_transcript_file(
      model,
      path,
      "transcript written — view with: ${PAGER:-less} #{path}"
    )
  end

  defp write_transcript_file(model, path, success_note) do
    text = Raxol.Agent.Code.Replay.transcript_text(model.events)

    case File.write(path, text <> "\n") do
      :ok -> notice(model, success_note)
      {:error, reason} -> notice(model, "write failed: #{inspect(reason)}")
    end
  end

  defp copy_last_answer(model) do
    case model.messages
         |> Enum.reverse()
         |> Enum.find(&(&1.role == :assistant)) do
      nil ->
        notice(model, "no assistant reply to copy yet")

      %{content: content} ->
        case model.clipboard.(content) do
          :ok ->
            notice(model, "copied last reply (#{byte_size(content)} bytes)")

          {:error, reason} ->
            notice(model, "copy failed: #{inspect(reason)}")
        end
    end
  end

  @find_match_cap 8

  defp find_in_transcript(model, ""), do: notice(model, "usage: /find <text>")

  defp find_in_transcript(model, needle) do
    down_needle = String.downcase(needle)

    matches =
      Projection.project(model.events).blocks
      |> Enum.with_index(1)
      |> Enum.filter(fn {block, _index} ->
        block
        |> Block.search_text()
        |> String.downcase()
        |> String.contains?(down_needle)
      end)

    case matches do
      [] ->
        notice(model, "no matches for \"#{needle}\"")

      matches ->
        lines =
          matches
          |> Enum.take(@find_match_cap)
          |> Enum.map(fn {block, index} ->
            "#{index}. [#{block.kind}] " <>
              excerpt(Block.search_text(block), down_needle)
          end)

        header = "#{length(matches)} match(es) for \"#{needle}\":"
        notice(model, Enum.join([header | lines], "\n"))
    end
  end

  # A one-line window around the first hit, newlines flattened.
  defp excerpt(text, down_needle) do
    flat = text |> String.replace(~r/\s+/, " ") |> String.trim()

    start =
      case :binary.match(String.downcase(flat), down_needle) do
        {at, _len} -> max(at - 20, 0)
        :nomatch -> 0
      end

    prefix = if start > 0, do: "…", else: ""
    prefix <> String.slice(flat, start, 70)
  end

  # `/logout` disconnects the session's provider (the setup panel
  # reopens); `/logout <provider>` additionally deletes that provider's
  # stored credential reference.
  defp logout(%{executor: nil} = model, ""),
    do: notice(model, "no provider connected")

  defp logout(model, "") do
    %{model | executor: nil, provider_status: :no_provider}
    |> open_browse()
    |> notice("logged out — /login reconnects")
  end

  defp logout(model, provider) do
    case model.credential_remover.(provider) do
      {:ok, harness} ->
        model
        |> disconnect_if_current(harness)
        |> notice("removed stored credential for #{harness}")

      {:error, reason} ->
        notice(model, "logout failed: #{inspect(reason)}")
    end
  end

  defp disconnect_if_current(%{executor: %{backend: harness}} = model, harness) do
    %{model | executor: nil, provider_status: :no_provider} |> open_browse()
  end

  defp disconnect_if_current(model, _harness), do: model

  # `/model` with no arg on a connected provider fetches its model list and
  # opens a selectable picker; otherwise it just shows the current model.
  defp set_model(%{executor: %{}} = model, "") do
    if provider_ready?(model),
      do: open_model_picker(model),
      else: model_usage(model)
  end

  defp set_model(model, ""), do: model_usage(model)

  defp set_model(model, name) do
    notice(%{model | model_override: name}, "model set to #{name}")
  end

  defp model_usage(model),
    do:
      notice(
        model,
        "usage: /model <name>  (current: #{model.model_override || "default"})"
      )

  defp open_model_picker(model) do
    ref = make_ref()
    model.models_fetcher.(models_fetch_opts(model), ref, self())
    %{model | models_ref: ref} |> put_status("fetching models…")
  end

  # The connected executor's backend opts, with `:provider` pinned so the
  # model-list endpoint is chosen by the actual backend, not a URL guess.
  defp models_fetch_opts(%{executor: executor}) do
    executor
    |> Raxol.Agent.ExecutorConfig.to_backend_opts()
    |> Keyword.put(:provider, executor.backend)
  end

  @doc false
  # Default fetcher: list the provider's models off the app process (so a slow
  # endpoint never blocks the TUI); the outcome rides back as a `:models_list`
  # message `update/2` folds.
  def default_models_fetcher(opts, ref, app) do
    spawn(fn ->
      result = Raxol.Agent.Backend.HTTP.list_models(opts)
      send(app, {:command_result, {:models_list, ref, result}})
    end)
  end

  defp apply_models_result(model, {:ok, [_ | _] = ids}) do
    entries = Enum.map(ids, &%{model: &1, label: &1})

    %{
      model
      | models_ref: nil,
        status_line: nil,
        wizard: %{
          step: :models,
          entries: entries,
          cursor: model_cursor(entries, model.model_override)
        }
    }
  end

  defp apply_models_result(model, {:ok, []}),
    do:
      notice(
        %{model | models_ref: nil, status_line: nil},
        "no models returned — usage: /model <name>"
      )

  defp apply_models_result(model, :unsupported),
    do:
      notice(
        %{model | models_ref: nil, status_line: nil},
        "model listing unavailable for this provider — usage: /model <name>"
      )

  defp apply_models_result(model, {:error, _reason}),
    do:
      notice(
        %{model | models_ref: nil, status_line: nil},
        "couldn't fetch models — usage: /model <name>"
      )

  # Start the cursor on the current model when it's in the list, else the top.
  defp model_cursor(entries, current) do
    case Enum.find_index(entries, &(&1.model == current)) do
      nil -> 0
      index -> index
    end
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
    {_turns, usage} = fold_usage(model.events)

    "messages: #{length(model.messages)} · events: #{length(model.events)} · " <>
      "tokens: #{usage.input_tokens} in / #{usage.output_tokens} out · " <>
      "plan: #{if model.plan_mode, do: "on", else: "off"} · " <>
      "model: #{model.model_override || "default"} · session: #{model.session_key}"
  end

  # Session token totals folded from the turn_completed events the model
  # already holds (the same events the transcript rebuilds from), so /usage
  # works on a resumed session too. Cost appears only when per-mtok rates
  # are configured (RAXOL_COST_PER_MTOK_IN/OUT).
  defp usage_text(model) do
    {turns, usage} = fold_usage(model.events)

    base =
      "turns: #{turns} · input tokens: #{usage.input_tokens} · " <>
        "output tokens: #{usage.output_tokens}"

    case session_cost(usage) do
      nil ->
        base <> " · cost: set RAXOL_COST_PER_MTOK_IN/OUT to estimate"

      cost ->
        base <> " · est. cost: $#{:erlang.float_to_binary(cost, decimals: 4)}"
    end
  end

  defp fold_usage(events) do
    Enum.reduce(events, {0, %{input_tokens: 0, output_tokens: 0}}, fn
      %{type: :turn_completed, payload: payload}, {turns, acc} ->
        usage = Map.get(payload, :usage) || Map.get(payload, "usage") || %{}
        {turns + 1, Raxol.Agent.BenchmarkProfile.add_usage(acc, usage)}

      _event, acc ->
        acc
    end)
  end

  defp session_cost(usage) do
    case Raxol.Agent.BenchmarkProfile.from_env() do
      {:ok, %{cost_per_mtok_in: rin, cost_per_mtok_out: rout} = profile}
      when is_number(rin) and is_number(rout) ->
        Raxol.Agent.BenchmarkProfile.cost_usd(profile, usage)

      _ ->
        nil
    end
  end

  defp sessions_text(model) do
    case Raxol.Agent.Code.Store.list(model.sessions_dir) do
      [] ->
        "no saved sessions"

      sessions ->
        sessions
        |> Enum.take(10)
        |> Enum.map_join("\n", &session_line/1)
    end
  end

  defp session_line(session) do
    details =
      [
        title_note(session),
        "#{session.message_count} msgs",
        format_age(session.updated_at),
        shorten_home(session.cwd)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")

    "#{session.id}  (#{details})"
  end

  defp title_note(%{title: title}) when is_binary(title) and title != "",
    do: ~s("#{title}")

  defp title_note(_session), do: nil

  defp format_age(updated_at)
       when is_integer(updated_at) and updated_at > 0 do
    diff = System.system_time(:second) - updated_at

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  defp format_age(_updated_at), do: nil

  defp shorten_home(cwd) when is_binary(cwd) and cwd != "" do
    case System.user_home() do
      nil -> cwd
      home -> String.replace_prefix(cwd, home, "~")
    end
  end

  defp shorten_home(_cwd), do: nil

  defp help_text do
    """
    /help              this help
    /login [provider]  connect an LLM provider (op ref, key, or local)
    /clear             start a fresh session
    /model [name]      switch model (no name = pick from the provider's list)
    /plan              toggle plan mode
    /compact           shrink the conversation history
    /rewind            drop the last turn (transcript + conversation)
    /context           session stats
    /usage             session token and cost totals
    /sessions          list saved sessions
    /resume [id]       switch session (no id = pick from a list)
    /fork [title]      branch a copy of this session and continue there
    /rename <title>    title this session (shown in /sessions)
    /export [path]     write the transcript to a file (default: cwd)
    /transcript        write the transcript to a temp file for paging
    /copy              copy the last reply to the clipboard
    /find <text>       search the transcript blocks
    /logout [provider] disconnect (with a name: forget its credential)
    /mcp               list configured MCP servers
    /hooks             show configured lifecycle hooks
    /inspect           show every config source in use (providers, pin, hooks, MCP, skills, sessions)
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

  defp setup_block(%{wizard: %{step: :sessions} = wizard}),
    do: sessions_panel(wizard)

  defp setup_block(%{wizard: %{step: :models} = wizard}),
    do: models_panel(wizard)

  defp setup_block(model) do
    if provider_ready?(model), do: nil, else: hint_panel(model)
  end

  defp models_panel(%{entries: entries, cursor: cursor}) do
    rows =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} -> model_row(entry, index == cursor) end)

    box style: %{border: :single, padding: 0} do
      column style: %{gap: 0} do
        [
          text("pick a model  (↑↓ move · Enter select · Esc cancel)",
            fg: :yellow,
            style: [:bold]
          )
        ] ++ rows
      end
    end
  end

  defp model_row(entry, selected?) do
    marker = if selected?, do: "▸", else: " "
    fg = if selected?, do: :cyan, else: :white
    style = if selected?, do: [:bold], else: []
    text("#{marker} #{entry.label}", fg: fg, style: style)
  end

  defp sessions_panel(%{entries: entries, cursor: cursor}) do
    rows =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} -> model_row(entry, index == cursor) end)

    box style: %{border: :single, padding: 0} do
      column style: %{gap: 0} do
        [
          text("resume a session  (↑↓ move · Enter resume · Esc cancel)",
            fg: :yellow,
            style: [:bold]
          )
        ] ++ rows
      end
    end
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
      Raxol.Agent.Actions.Task.all() ++
      Raxol.Agent.Skills.enabled_actions()
  end

  defp default_system do
    "You are a coding assistant running in a terminal at the user's " <>
      "current working directory. Read files before editing them. Use " <>
      "write_file/edit_file to change code and bash to run commands. Be concise."
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
