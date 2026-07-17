# Harness LIVE demo (the assembled harness against a REAL agent session).
#
# Runs the assembled `Raxol.Harness.Surface` -- via
# `Raxol.Harness.LiveSessionDriver` -- against a live
# `Raxol.Agent.SessionStreamer` session on a real tty. This is the live
# counterpart of `examples/harness_fixture_demo.exs`: same
# `Raxol.Terminal.InlineDriver` raw-mode input path, same startup
# push-up, same teardown ownership -- but the events come from a real
# `Raxol.Agent.Stream.run/2` turn pumped through
# `Raxol.Agent.Contract.pump/3`, not a golden fixture. Wiring proven by
# the integration keystone at
# `packages/raxol_agent/test/raxol/agent/harness/live_session_agent_test.exs`
# ("c. the real event path end-to-end").
#
# The main `raxol` package does NOT depend on `raxol_agent` (see the
# dependency graph in CLAUDE.md), so this script must run under the
# raxol_agent Mix project, which path-depends on main raxol:
#
#   cd packages/raxol_agent
#   mix run --no-start ../../examples/harness_live_demo.exs
#   mix run --no-start ../../examples/harness_live_demo.exs --prompt "hello world"
#
# `--no-start` avoids interleaving application boot logs into the byte
# stream, exactly as the fixture demo documents -- everything this demo
# needs (SessionStreamer, telemetry) is started explicitly below.
#
# Backend selection (mirrors examples/agents/zero_system.exs + CLAUDE.md):
#
#   (default)                 Mock backend -- zero config, canned echo response
#   LM_STUDIO=true            local LM Studio via the :lm_studio harness
#                             (OpenAI-compatible, default http://localhost:1234)
#   AI_API_KEY=sk-...         any OpenAI-compatible provider via the :openai
#   AI_BASE_URL=https://...   harness (base URL WITHOUT the /v1 suffix --
#                             Backend.HTTP appends /v1/chat/completions; a
#                             trailing /v1 is stripped here as a courtesy)
#   AI_MODEL=...              model override for either live harness
#
# Keys while running (a REPL-ish loop):
#
#   type + ↵    submit the composed text as the next turn's prompt: a new
#               `Raxol.Agent.Stream.run/2` + `Contract.pump/3` per submit;
#               events flow SessionStreamer -> LiveSessionDriver -> sealed
#               history. A submit mid-turn is queued and runs after the
#               current turn completes.
#   Esc         REAL interrupt path: `SessionLane.interrupt/2` decodes and
#               routes the command, but this session carries no `:pid`, so
#               no runtime picks it up -- the footer shows the HONEST
#               pending state ("interrupt sent — awaiting confirmation")
#               and never fabricates an ack. Expected; see the keystone.
#   Tab         steer: `Raxol.Agent.Harness.SessionLane.steer/2` honestly
#               refuses with :no_steer_channel (no shipped runtime owns a
#               live TurnState) -- the footer shows "steer NOT delivered".
#   z/j/k       fold/jump, once off the composer (Surface.focus_transcript/1)
#   q           quits cleanly WHEN THE COMPOSER BUFFER IS EMPTY (the
#               LiveSessionDriver owns this check, same convention as the
#               fixture demo; Ctrl-C does not work -- raw mode disables
#               SIGINT delivery, per InlineDriver's moduledoc)
#
# The REPL seam (why this demo keeps a mirror Composer): on this branch
# `Raxol.Harness.Surface` has no live submit channel -- its own composer
# submit renders the honest "» (stub) would send prompt: ..." notice and
# stops there (`apply_composer_command/2`), and `:submit` is not one of
# the `command_sink` command types. So this demo feeds a SECOND
# `Raxol.UI.Components.Harness.Composer` instance -- a deterministic
# state machine -- the exact same passthrough events the Surface's own
# composer receives, and reads submits off the mirror. Events are still
# forwarded to the LiveSessionDriver verbatim, so what you SEE is always
# the Surface's own truth; only the demo's notion of "what ↵ submits"
# comes from the mirror. Known honest limitation: the mirror assumes
# composer focus with no overlay (`composing?: true`), so typing into an
# open Ctrl-P palette, or navigating focus off the composer and back,
# can desync the mirror's buffer from the Surface's until both are
# cleared -- acceptable for a demo, called out rather than papered over.
#
# Two more expected notices, documented so nobody debugs them as bugs:
#   * after each turn the footer says "session ended — transcript above
#     is preserved; q quits": `Contract.pump/3` closes every turn with
#     `final: true`, and the driver renders that honestly. The loop keeps
#     running; the next submit starts a fresh turn and clears the notice.
#   * each ↵ also flashes the Surface's own "» (stub) would send prompt"
#     notice -- that is the Surface telling the truth about ITS submit
#     channel (see the REPL-seam note above); the demo's mirror is what
#     actually sends the prompt.
#
# `--prompt X` one-shot mode (non-interactive smoke): submits X
# programmatically (no composer involved), lets the turn stream to
# sealed history, lingers briefly (input still live), then exits 0.
#
#   cd packages/raxol_agent
#   script -q /tmp/live_demo.out \
#     mix run --no-start ../../examples/harness_live_demo.exs --prompt "hello world"

defmodule Raxol.Examples.HarnessLiveDemo do
  @moduledoc false

  alias Raxol.Harness.LiveSessionDriver
  alias Raxol.Harness.Surface
  alias Raxol.Terminal.InlineDriver
  alias Raxol.UI.Components.Harness.Composer
  alias Raxol.UI.Harness.InputEvent
  alias Raxol.UI.Harness.Keymap

  @footer_rows 6
  @subscribe_wait_ms 5_000
  @one_shot_linger_ms 2_500

  # The mirror routes events exactly like `Surface.handle_input/2` does
  # for the composing-focused, no-overlay case (keymap-first, then
  # composer passthrough) -- see the REPL-seam note in the header.
  @mirror_keymap_context %{
    composing?: true,
    streaming?: false,
    focused_block_id: nil,
    overlay_open?: false
  }

  def run(argv) do
    ensure_agent_package!()
    one_shot = parse_args(argv)

    # Explicit app starts instead of `:raxol` boot (see `--no-start` note):
    # telemetry for Contract.pump's DoneGate signals; req only when a
    # live HTTP backend was selected. Logger is raised to :error because
    # a log line printed mid-raw-mode corrupts the harness display -- the
    # one known offender is Harness.Projection's recovered
    # :orphan_item_completed warning on every Contract.pump turn (a
    # lib-side event-vocabulary mismatch, reported separately; the
    # projection recovers and the transcript stays correct).
    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.configure(level: :error)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {backend, backend_opts_fun, label} = detect_backend()

    if backend == Raxol.Agent.Backend.HTTP do
      {:ok, _} = Application.ensure_all_started(:req)
    end

    # SessionStreamer does NOT auto-start (nothing in raxol_agent does
    # outside a supervision tree) -- the demo owns it.
    {:ok, _streamer} = Raxol.Agent.SessionStreamer.start_link([])

    session_id = "live-demo-#{System.unique_integer([:positive])}"
    session = %{session_id: session_id}

    {width, rows} = geometry()
    tty? = Raxol.Terminal.TerminalUtils.has_terminal_device?()

    # Lands in native scrollback once startup_push_up scrolls it away.
    IO.puts("harness live demo -- backend=#{label} session=#{session_id}")

    # Same startup discipline as the fixture demo: push whatever is on
    # screen up into scrollback via plain newlines -- never `\e[2J`.
    Surface.startup_push_up(:stdio, rows)

    # The live driver: builds Surface + StreamCadence + the subscription
    # forwarder inside its own process; `notify: self()` tells this
    # embedder when the loop ends (q on empty composer, or halt/1).
    {:ok, driver} =
      LiveSessionDriver.start_link(
        lane: {Raxol.Agent.Harness.SessionLane, session},
        device: :stdio,
        width: width,
        rows: rows,
        footer_rows: @footer_rows,
        tty?: tty?,
        notify: self()
      )

    # The tty side, exactly as the fixture demo wires it -- except the
    # subscriber is THIS process, which forwards every parsed keypress to
    # the LiveSessionDriver as `{:inline_input, event}` (its documented
    # input seam) after feeding the REPL mirror.
    {:ok, inline} =
      InlineDriver.start_link(
        subscriber: self(),
        device: :stdio,
        rows: rows,
        probe?: false,
        tty?: tty?
      )

    try do
      # The driver's forwarder owns the real `subscribe/1` call -- wait
      # for it to land before pumping, so the first turn's events are
      # never emitted to zero subscribers (keystone test convention).
      case wait_for_subscription(session_id, @subscribe_wait_ms) do
        :ok ->
          :ok

        :timeout ->
          IO.puts(
            :stderr,
            "live stream subscription never landed (session #{session_id}); exiting"
          )

          System.halt(1)
      end

      {:ok, mirror} =
        Composer.init(%{
          id: "live-demo-mirror",
          width: width - 2,
          focused: true
        })

      state = %{
        driver: driver,
        mirror: mirror,
        session_id: session_id,
        backend: backend,
        backend_opts_fun: backend_opts_fun,
        turn_task: nil,
        queue: [],
        mode: if(one_shot, do: :one_shot, else: :interactive)
      }

      state = if one_shot, do: start_turn(state, one_shot), else: state
      loop(state)
    after
      LiveSessionDriver.halt(driver)
      # InlineDriver's terminate/2 owns ALL terminal teardown (region
      # release, modes off, cooked stty) -- the LiveSessionDriver emits no
      # teardown bytes of its own, per its moduledoc.
      GenServer.stop(inline, :normal)
    end
  end

  # -- the embedder loop ---------------------------------------------------

  defp loop(%{mode: {:linger, deadline}} = state) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :ok
    else
      receive do
        msg ->
          case handle_msg(state, msg) do
            :halt -> :ok
            {:cont, state} -> loop(state)
          end
      after
        remaining -> :ok
      end
    end
  end

  defp loop(state) do
    receive do
      msg ->
        case handle_msg(state, msg) do
          :halt -> :ok
          {:cont, state} -> loop(state)
        end
    end
  end

  # Every keypress is forwarded to the LiveSessionDriver verbatim (the
  # Surface must see everything to render truthfully), THEN fed to the
  # REPL mirror when the Surface's own routing would have passed it
  # through to the composer.
  defp handle_msg(state, {:inline_input, event}) do
    send(state.driver, {:inline_input, event})
    {:cont, feed_mirror(state, event)}
  end

  # The driver ended its loop (q on empty composer) -- teardown runs in
  # the caller's `after` block.
  defp handle_msg(_state, {:live_session_driver, _pid, :halted}), do: :halt

  defp handle_msg(state, {ref, result}) when is_reference(ref),
    do: {:cont, handle_turn_result(state, ref, result)}

  # Task.async's trailing DOWN for a completed turn task.
  defp handle_msg(state, {:DOWN, _ref, :process, _pid, _reason}),
    do: {:cont, state}

  defp handle_msg(state, _other), do: {:cont, state}

  defp feed_mirror(state, event) do
    norm = InputEvent.normalize(event)

    case Keymap.resolve(norm, @mirror_keymap_context) do
      :passthrough ->
        {mirror, commands} = Composer.handle_event(event, state.mirror, %{})

        Enum.reduce(
          commands,
          %{state | mirror: mirror},
          &apply_mirror_command/2
        )

      _command ->
        # ESC/Tab/Ctrl-E/Ctrl-P resolve to commands and never reach the
        # Surface's composer -- keep the mirror consistent by skipping it.
        state
    end
  end

  defp apply_mirror_command({:component_event, _id, {:submit, text}}, state),
    do: handle_submit(state, String.trim(text))

  defp apply_mirror_command(_command, state), do: state

  defp handle_submit(state, ""), do: state

  # One turn at a time: Contract.pump is a blocking drain per turn, and
  # interleaving two pumps on one session would shuffle their events into
  # a single transcript -- queue instead.
  defp handle_submit(%{turn_task: task} = state, prompt) when not is_nil(task),
    do: %{state | queue: state.queue ++ [prompt]}

  defp handle_submit(state, prompt), do: start_turn(state, prompt)

  # The turn: exactly the keystone's recipe. `Stream.run/2` builds the
  # lazy backend stream; `Contract.pump/3` drains it, emitting turn
  # lifecycle + delta events onto the SessionStreamer, where the driver's
  # forwarder (already subscribed) picks them up. pump blocks until the
  # stream is done, so it runs in its own task; a raise inside a live
  # backend stream is caught and reported rather than crashing the demo
  # (pump itself already emits an honest :error event for in-band stream
  # errors).
  defp start_turn(state, prompt) do
    backend = state.backend
    backend_opts = state.backend_opts_fun.(prompt)
    session_id = state.session_id

    task =
      Task.async(fn ->
        try do
          stream =
            Raxol.Agent.Stream.run(prompt,
              backend: backend,
              backend_opts: backend_opts
            )

          Raxol.Agent.Contract.pump(session_id, stream, prompt: prompt)
        rescue
          error -> {:error, {:turn_crashed, Exception.message(error)}}
        catch
          kind, reason -> {:error, {:turn_crashed, {kind, reason}}}
        end
      end)

    %{state | turn_task: task}
  end

  defp handle_turn_result(%{turn_task: %Task{ref: ref}} = state, ref, result) do
    state = %{state | turn_task: nil}

    case result do
      {:error, {:turn_crashed, info}} ->
        # Nothing reached the event stream for this failure mode, so the
        # transcript cannot show it -- stderr is the honest channel left.
        IO.puts(:stderr, "turn crashed before completing: #{inspect(info)}")

      _ok_or_pumped_error ->
        # {:ok, %{content: ...}} or a pump-level {:error, reason} -- both
        # already rendered through the event stream; nothing to add here.
        :ok
    end

    case state.queue do
      [next | rest] -> start_turn(%{state | queue: rest}, next)
      [] -> maybe_enter_linger(state)
    end
  end

  defp handle_turn_result(state, _ref, _result), do: state

  # One-shot mode: the (only) turn is done -- keep the terminal up long
  # enough for the tail of the reveal to seal, still forwarding input,
  # then exit 0 on our own.
  defp maybe_enter_linger(%{mode: :one_shot} = state) do
    deadline = System.monotonic_time(:millisecond) + @one_shot_linger_ms
    %{state | mode: {:linger, deadline}}
  end

  defp maybe_enter_linger(state), do: state

  # -- backend selection (zero_system.exs convention, thin) -----------------

  defp detect_backend do
    cond do
      System.get_env("LM_STUDIO") in ["true", "1"] ->
        live_backend(
          :lm_studio,
          System.get_env("AI_MODEL") || "local-model",
          %{}
        )

      key = System.get_env("AI_API_KEY") ->
        live_backend(
          :openai,
          System.get_env("AI_MODEL") || "gpt-4o-mini",
          %{api_key: key}
        )

      true ->
        {Raxol.Agent.Backend.Mock,
         fn prompt -> [response: mock_response(prompt)] end, "mock"}
    end
  end

  # Through the blessed path: ExecutorConfig + Backend.Selector resolve
  # the harness atom to Backend.HTTP + provider/base_url/auth defaults.
  defp live_backend(harness, model, auth) do
    config =
      Raxol.Agent.ExecutorConfig.new(
        harness: harness,
        model: model,
        auth: auth,
        opts: base_url_opts()
      )

    {:ok, backend, opts} = Raxol.Agent.Backend.Selector.select(config)
    {backend, fn _prompt -> opts end, "live:#{harness}:#{model}"}
  end

  defp base_url_opts do
    case System.get_env("AI_BASE_URL") do
      nil ->
        []

      url ->
        # Backend.HTTP's :openai provider appends /v1/chat/completions
        # itself -- strip a conventionally-supplied trailing /v1.
        [
          base_url:
            url |> String.trim_trailing("/") |> String.trim_trailing("/v1")
        ]
    end
  end

  defp mock_response(prompt) do
    "the mock answer — live harness echo of: #{prompt}"
  end

  # -- plumbing --------------------------------------------------------------

  defp parse_args(argv) do
    {opts, _positional, _invalid} =
      OptionParser.parse(argv, strict: [prompt: :string])

    Keyword.get(opts, :prompt)
  end

  defp wait_for_subscription(session_id, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    poll_subscription(session_id, deadline)
  end

  defp poll_subscription(session_id, deadline) do
    cond do
      session_id in Raxol.Agent.SessionStreamer.list_sessions() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(20)
        poll_subscription(session_id, deadline)
    end
  end

  defp ensure_agent_package! do
    unless Code.ensure_loaded?(Raxol.Agent.SessionStreamer) do
      IO.puts(
        :stderr,
        "raxol_agent is not on the code path -- run this demo from the " <>
          "raxol_agent package (main raxol does not depend on it):\n\n" <>
          "  cd packages/raxol_agent\n" <>
          "  mix run --no-start ../../examples/harness_live_demo.exs"
      )

      System.halt(1)
    end
  end

  defp geometry do
    width =
      case :io.columns() do
        {:ok, cols} -> cols
        _ -> 80
      end

    rows =
      case :io.rows() do
        {:ok, rows} -> rows
        _ -> 24
      end

    {width, rows}
  end
end

Raxol.Examples.HarnessLiveDemo.run(System.argv())
