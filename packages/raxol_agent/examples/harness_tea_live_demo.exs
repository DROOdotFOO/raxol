# Harness TEA live demo (U6-d): the assembled TEA harness against a REAL
# agent session.
#
# This is the U6 swap's proof surface: the SAME session runtime as
# `harness_live_demo.exs` (SessionInbox + SessionStreamer + the same
# tool set), but the UI side is the new stack -- one
# `Raxol.Harness.Live.start_link/1` boots SessionPump + Lifecycle(
# environment: :harness) running `HarnessApp`, replacing the
# LiveSessionDriver + Surface map-machine. Everything the old demo
# wires by hand (InlineDriver stdin, alt-screen bracket, SIGWINCH
# watch, geometry probe, paint gating, teardown ordering) is owned by
# the assembly now; what remains here is exactly the embedder's share:
# app starts, backend selection, the session runtime, and waiting for
# the halt.
#
# Run it under the raxol_agent Mix project (raxol_agent path-depends on
# main raxol, not the other way around):
#
#   cd packages/raxol_agent
#   mix run --no-start examples/harness_tea_live_demo.exs
#   mix run --no-start examples/harness_tea_live_demo.exs --prompt "hello"
#   mix run --no-start examples/harness_tea_live_demo.exs --yolo
#
# For a real terminal, prefer the pre-BEAM locks the old demo's wrapper
# documents (`stty -f /dev/tty -isig` + `ELIXIR_ERL_OPTIONS="+Bi"`), e.g.
# via packages/raxol_agent/examples/harness-live-demo.sh's pattern -- the
# kernel/VM ^C story is terminal reality, not something this demo can
# fix in Elixir.
#
# Backend selection (same convention as the old demo):
#
#   (default)                 Mock backend -- zero config, canned echo
#   LM_STUDIO=true            local LM Studio (:lm_studio harness)
#   AI_API_KEY=sk-...         any OpenAI-compatible provider (:openai)
#   AI_BASE_URL=https://...   base URL override
#   AI_MODEL=...              model override
#
# Keys while running: type + Enter submits; Esc interrupts; Tab steers;
# z folds; PgUp/PgDn scroll; q quits on an empty composer; ^C arms then
# quits on a second consecutive press (the model's quit protocol). The
# demo enables `time_travel: true` -- every update/2 cycle is recorded
# (Raxol.Debug.TimeTravel), the U6 migration's free payoff.

defmodule HarnessTeaLiveDemo do
  @moduledoc false

  @linger_ms 2_500

  def run(argv) do
    {prompt, _yolo?, opts_rest} = parse_args(argv)
    yolo? = "--yolo" in argv
    _ = opts_rest

    # Log lines printed mid-raw-mode corrupt the harness frame (the old
    # demo's hard-won invariant); everything this demo needs starts
    # explicitly below.
    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.configure(level: :error)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {backend, backend_opts, label} = detect_backend()

    if backend == Raxol.Agent.Backend.HTTP do
      {:ok, _} = Application.ensure_all_started(:req)
    end

    {:ok, streamer} = Raxol.Agent.SessionStreamer.start_link([])
    session_id = "tea-live-demo-#{System.unique_integer([:positive])}"

    actions =
      Raxol.Agent.Actions.Fs.all() ++
        Raxol.Agent.Actions.Workspace.all() ++ [Raxol.Agent.Actions.Shell]

    {:ok, inbox} =
      Raxol.Agent.Harness.SessionInbox.start_link(
        session_id: session_id,
        actions: actions,
        backend: backend,
        backend_opts: backend_opts,
        system_prompt: nil,
        gate?: not yolo?,
        notify: self()
      )

    session = %{session_id: session_id, pid: inbox}

    # THE U6 ASSEMBLY: one call. The pump boots the Lifecycle, enters the
    # alt screen before the Engine's first frame, owns stdin/SIGWINCH/
    # teardown, and feeds HarnessApp through the DeliveryShim -> {:harness,
    # _} ingress -> update/2 path. Directives come back the other way.
    {:ok, %{pump: pump, lifecycle: lifecycle}} =
      Raxol.Harness.Live.start_link(
        lane: {Raxol.Agent.Harness.SessionLane, session},
        inline_driver_opts: [],
        editor_session: Raxol.Harness.EditorSession,
        greeting?: true,
        time_travel: true,
        notify: self()
      )

    IO.puts(:stderr, "[tea-live] up (#{label} backend) -- #{session_id}")

    if prompt do
      type_string(pump, prompt)
      send(pump, {:inline_input, enter_key()})
      linger_then_halt(pump)
    end

    wait_for_halt(pump, lifecycle, streamer)
  end

  # -- the main wait: session death is NOT teardown (PumpContract §8), so
  # the script ends only on the pump's own halt (q / ^C^C / --prompt).
  defp wait_for_halt(pump, lifecycle, streamer) do
    receive do
      {:session_pump, ^pump, :halted} ->
        IO.puts(:stderr, "[tea-live] halted")
        cleanup(lifecycle, streamer)
    end
  end

  defp cleanup(lifecycle, streamer) do
    if Process.alive?(lifecycle), do: GenServer.stop(lifecycle, :normal)
    if Process.alive?(streamer), do: GenServer.stop(streamer, :normal)
    :ok
  end

  defp linger_then_halt(pump) do
    Process.sleep(@linger_ms)
    Raxol.Harness.Live.stop(pump)
  end

  # Keys ride the REAL input path (InlineDriver's {:inline_input, _}
  # shape), so a scripted prompt exercises the same fold a typed one
  # does -- pump boundary normalize -> shim -> update/2 -> directive.
  defp type_string(pump, text) do
    text
    |> String.graphemes()
    |> Enum.each(fn char ->
      send(pump, {:inline_input, %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: char, state: :pressed, modifiers: []}
      }})
    end)
  end

  defp enter_key,
    do: %Raxol.Core.Events.Event{
      type: :key,
      data: %{key: :enter, state: :pressed, modifiers: []}
    }

  defp parse_args(argv) do
    {prompt, rest} =
      case Enum.find_index(argv, &(&1 == "--prompt")) do
        nil -> {nil, argv}
        idx -> {Enum.at(argv, idx + 1), List.delete_at(argv, idx + 1) |> List.delete_at(idx)}
      end

    yolo? = "--yolo" in rest
    {prompt, yolo?, rest}
  end

  defp detect_backend do
    cond do
      System.get_env("LM_STUDIO") in ["true", "1"] ->
        live_backend(:lm_studio, System.get_env("AI_MODEL") || "local-model", %{})

      key = System.get_env("AI_API_KEY") ->
        live_backend(:openai, System.get_env("AI_MODEL") || "gpt-4o-mini", %{
          api_key: key
        })

      true ->
        {Raxol.Agent.Backend.Mock,
         [response: "TEA harness live echo (mock backend)."], "mock"}
    end
  end

  # The blessed resolution path (ExecutorConfig + Backend.Selector), same
  # as the old demo's live_backend/3.
  defp live_backend(harness, model, auth) do
    config =
      Raxol.Agent.ExecutorConfig.new(
        harness: harness,
        model: model,
        auth: auth,
        opts: base_url_opts()
      )

    case Raxol.Agent.Backend.Selector.select(config) do
      {:ok, backend, opts} -> {backend, opts, Atom.to_string(harness)}
      {:error, _} -> {Raxol.Agent.Backend.Mock, [response: "mock (selector fell back)"], "mock"}
    end
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
end

HarnessTeaLiveDemo.run(System.argv())
