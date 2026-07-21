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

  ## Tools and approval

  The agent gets the read-only fs tools plus the mutating coding tools
  (`write_file`/`edit_file`/`bash`), which are `sensitive`. A per-run
  `:tool_authorizer` gates each sensitive call through an interactive
  prompt: it sends `{:approval_request, ...}` to this app and BLOCKS the
  react loop's process until the user answers `y`/`n`, so a write or a
  shell command never runs unattended.

  ## Keys

    * printable text → prompt buffer (when idle)
    * Enter → submit the prompt / (when a tool is awaiting) ignored
    * `y` / `n` → answer a pending approval
    * Esc → deny a pending approval, else interrupt a running turn
    * Ctrl+C → quit
  """

  use Raxol.Core.Runtime.Application

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

    %{
      input: "",
      # Normalized projection events (durable + ephemeral), arrival order.
      events: [],
      face_state: :idle,
      face_frame: 0,
      running?: false,
      worker: nil,
      session_id: nil,
      pending_approval: nil,
      status_line: nil,
      ascii: Keyword.get(options, :ascii, false),
      executor: Keyword.get(options, :executor),
      backend_opts: Keyword.get(options, :backend_opts, []),
      system: Keyword.get(options, :system, default_system()),
      actions: Keyword.get(options, :actions, default_actions()),
      # Injectable so tests drive the loop without spawning a real turn.
      runner: Keyword.get(options, :runner, &__MODULE__.default_runner/4),
      width: Map.get(context, :width, 80),
      height: Map.get(context, :height, 24)
    }
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

  def update(
        {:command_result, {:approval_request, ref, from, name}},
        model
      ) do
    approval = %{ref: ref, from: from, name: name}
    {%{model | pending_approval: approval, face_state: :working}, []}
  end

  def update(_message, model), do: {model, []}

  # -- key handlers -----------------------------------------------------------

  defp handle_shortcut(%{char: "c", mods: %{ctrl: true}}, model) do
    {model, [Directive.stop()]}
  end

  defp handle_shortcut(_norm, model), do: {model, []}

  # `y`/`n` answer a pending approval; otherwise printable text edits the
  # prompt, but only when idle (no running turn, no pending approval).
  defp handle_char(char, %{pending_approval: %{}} = model)
       when char in ["y", "Y"],
       do: {decide_approval(model, :allow), []}

  defp handle_char(char, %{pending_approval: %{}} = model)
       when char in ["n", "N"],
       do: {decide_approval(model, :deny), []}

  defp handle_char(_char, %{pending_approval: %{}} = model), do: {model, []}

  defp handle_char(_char, %{running?: true} = model), do: {model, []}

  defp handle_char(char, model) do
    {%{model | input: model.input <> char}, []}
  end

  defp handle_key(:enter, %{pending_approval: %{}} = model), do: {model, []}
  defp handle_key(:enter, %{running?: true} = model), do: {model, []}

  defp handle_key(:enter, model) do
    case String.trim(model.input) do
      "" -> {model, []}
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
    do: {decide_approval(model, :deny), []}

  defp handle_key(:escape, %{running?: true} = model),
    do: {interrupt(model), []}

  defp handle_key(_key, model), do: {model, []}

  # -- turn lifecycle ---------------------------------------------------------

  defp start_turn(model, prompt) do
    session_id = "code-#{System.unique_integer([:positive])}"
    ensure_streamer!()
    app = self()

    opts = [
      backend_opts: model.backend_opts,
      system_prompt: model.system,
      actions: model.actions,
      context: %{tool_authorizer: approval_authorizer(app)}
    ]

    opts = maybe_put(opts, :executor, model.executor)

    worker = model.runner.(session_id, prompt, opts, app)

    %{
      model
      | running?: true,
        worker: worker,
        session_id: session_id,
        face_state: :thinking,
        face_frame: 0,
        status_line: nil,
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

    reply_pending(model, :deny)

    %{
      model
      | running?: false,
        worker: nil,
        face_state: :idle,
        pending_approval: nil,
        status_line: "interrupted"
    }
  end

  # -- contract-event fold ----------------------------------------------------

  defp fold_event(event, normalized, model) do
    running? = model.running? and not terminal_event?(event)

    %{
      model
      | events: model.events ++ [normalized],
        face_state: face_for_event(event, model.face_state),
        face_frame: model.face_frame + 1,
        running?: running?,
        worker: if(running?, do: model.worker, else: nil),
        status_line: if(running?, do: model.status_line, else: nil)
    }
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

  # -- approval ---------------------------------------------------------------

  # Runs inside the react loop's process; blocks it until the app answers.
  defp approval_authorizer(app) do
    fn module, _params, _context ->
      meta = module.__action_meta__()

      if Map.get(meta, :sensitive, false) do
        ref = make_ref()
        send(app, {:command_result, {:approval_request, ref, self(), meta.name}})

        receive do
          {:approval_decision, ^ref, :allow} -> :ok
          {:approval_decision, ^ref, :deny} -> {:deny, :user_denied}
        after
          @approval_timeout_ms -> {:deny, :approval_timeout}
        end
      else
        :ok
      end
    end
  end

  defp decide_approval(%{pending_approval: %{}} = model, decision) do
    reply_pending(model, decision)
    face = if decision == :allow, do: :working, else: :thinking
    %{model | pending_approval: nil, face_state: face}
  end

  defp decide_approval(model, _decision), do: model

  defp reply_pending(%{pending_approval: %{ref: ref, from: from}}, decision)
       when is_pid(from) do
    send(from, {:approval_decision, ref, decision})
    :ok
  end

  defp reply_pending(_model, _decision), do: :ok

  # -- view -------------------------------------------------------------------

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1} do
      [
        transcript(model),
        status_strip(model),
        footer(model)
      ]
    end
  end

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
    face = AxolFace.glyph(model.face_state, model.face_frame, model.ascii)

    row style: %{gap: 1} do
      [
        text(face, fg: AxolFace.color(model.face_state), style: [:bold]),
        text(status_label(model), style: [:dim])
      ]
    end
  end

  defp status_label(%{status_line: line}) when is_binary(line), do: line
  defp status_label(%{pending_approval: %{name: name}}), do: "awaiting approval: #{name}"
  defp status_label(%{running?: true}), do: "working…"
  defp status_label(_model), do: "ready"

  defp footer(%{pending_approval: %{name: name}}) do
    box style: %{border: :single, padding: 0} do
      text("Allow #{name}? [y/N]  ·  Esc denies", fg: :yellow)
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
