defmodule Mix.Tasks.Raxol.Harness do
  @shortdoc "Start the live agent harness (the full TEA stack) in this terminal"

  @moduledoc """
  Boot the live agent harness — the assembled TEA stack — against a real
  agent session, right in your terminal.

      mix raxol.harness                      # mock backend, zero config
      mix raxol.harness --prompt "hello"     # send one prompt, then linger + quit
      mix raxol.harness --yolo               # no approval gate (auto-run tools)

  This is the single executable that replaced the two example scripts
  (`harness_live_demo.exs` / `harness_tea_live_demo.exs`). One
  `Raxol.Harness.Live.start_link/1` boots SessionPump + Lifecycle
  (`environment: :harness`) running `HarnessApp` — the pump owns stdin,
  the alt-screen bracket, SIGWINCH, paint gating, and teardown, so this
  task's share is exactly the embedder's: start the runtime deps, select a
  backend, wire the session, and wait for the halt.

  ## Backend selection

      (default)                 Mock backend -- canned echo, zero config
      LM_STUDIO=true            local LM Studio (:lm_studio harness)
      AI_API_KEY=sk-...         any OpenAI-compatible provider (:openai)
      AI_BASE_URL=https://...   base-URL override
      AI_MODEL=...              model override

  ## Keys while running

  Type + `Enter` submits; `Esc` interrupts; `Tab` steers; `z` folds;
  `PgUp`/`PgDn` scroll; `q` quits on an empty composer; `^C` arms then
  quits on a second consecutive press. `time_travel: true` is on — every
  `update/2` cycle is recorded (`Raxol.Debug.TimeTravel`).

  ## Terminal note

  The kernel/VM `^C` story is terminal reality, not something this task can
  fix in Elixir. For the cleanest raw-mode experience, launch under the
  pre-BEAM locks (these must be set BEFORE the VM starts):

      stty -isig; ELIXIR_ERL_OPTIONS="+Bi" mix raxol.harness

  ## Options

    * `--prompt TEXT`     — send TEXT as the first turn, linger, then halt
      (handy for smoke tests / recordings)
    * `--yolo`            — disable the approval gate (consequential tools
      run without asking)
    * `--demo-approval`   — mock backend scripts ONE `edit_file` tool call
      against a temp file, so the whole approval surface (inline ± diff,
      footer selector, y/n answer) can be exercised live with zero config
  """

  use Mix.Task

  @linger_ms 2_500

  @impl Mix.Task
  def run(argv) do
    # The task runs with the project + deps compiled and loaded but the app
    # NOT started (like `mix run --no-start`): the harness wires its own
    # runtime (Lifecycle via the pump), so only these leaf deps are started
    # explicitly. Log lines printed mid-raw-mode corrupt the frame, so Logger
    # stays at :error.
    {prompt, yolo?, demo_approval?} = parse_args(argv)

    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.configure(level: :error)
    {:ok, _} = Application.ensure_all_started(:telemetry)

    # Belt-and-braces terminal release (V's field report: mouse reporting
    # survived a quit). The InlineDriver's own teardown owns the full
    # sequence on every graceful path; this at_exit is the second net for
    # the paths that never reach it — a ^C that lands as SIGINT while
    # prim_tty has ISIG re-flipped (the BREAK-menu abort kills the VM
    # mid-session, but abort DOES run at_exit handlers), a crashed pump,
    # an init:stop unwind. Idempotent byte-wise: mode resets are set/reset
    # DEC privates, and `stty sane` after a restored tty is a no-op in
    # effect. SIGKILL still cleans nothing — nothing can.
    System.at_exit(fn _status ->
      IO.write(:stdio, "\e[?1000l\e[?1006l\e[?1003l\e[?2004l\e[?1004l")
      Raxol.Terminal.Driver.Stty.sane!()
    end)

    {backend, backend_opts, label, demo_cleanup} =
      if demo_approval? do
        demo_approval_backend()
      else
        {b, o, l} = detect_backend()
        {b, o, l, fn -> :ok end}
      end

    if backend == Raxol.Agent.Backend.HTTP do
      {:ok, _} = Application.ensure_all_started(:req)
    end

    {:ok, streamer} = Raxol.Agent.SessionStreamer.start_link([])
    session_id = "harness-#{System.unique_integer([:positive])}"

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

    # THE ASSEMBLY: one call. The pump boots the Lifecycle, enters the alt
    # screen before the Engine's first frame, owns stdin/SIGWINCH/teardown,
    # and feeds HarnessApp through the DeliveryShim -> {:harness, _} ingress
    # -> update/2 path. Directives come back the other way.
    {:ok, %{pump: pump, lifecycle: lifecycle}} =
      Raxol.Harness.Live.start_link(
        lane: {Raxol.Agent.Harness.SessionLane, session},
        inline_driver_opts: [],
        editor_session: Raxol.Harness.EditorSession,
        greeting?: true,
        time_travel: true,
        notify: self()
      )

    IO.puts(:stderr, "[raxol.harness] up (#{label} backend) -- #{session_id}")

    if prompt do
      type_string(pump, prompt)
      send(pump, {:inline_input, enter_key()})
      linger_then_halt(pump)
    end

    wait_for_halt(pump, lifecycle, streamer)
    demo_cleanup.()
  end

  # -- lifecycle ------------------------------------------------------------

  # Session death is NOT teardown (PumpContract §8): the task ends only on
  # the pump's own halt (q / ^C^C / --prompt linger).
  defp wait_for_halt(pump, lifecycle, streamer) do
    receive do
      {:session_pump, ^pump, :halted} ->
        IO.puts(:stderr, "[raxol.harness] halted")
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

  # -- scripted input (rides the REAL InlineDriver path) --------------------

  defp type_string(pump, text) do
    text
    |> String.graphemes()
    |> Enum.each(fn char ->
      send(
        pump,
        {:inline_input,
         %Raxol.Core.Events.Event{
           type: :key,
           data: %{key: char, state: :pressed, modifiers: []}
         }}
      )
    end)
  end

  defp enter_key,
    do: %Raxol.Core.Events.Event{
      type: :key,
      data: %{key: :enter, state: :pressed, modifiers: []}
    }

  # -- args -----------------------------------------------------------------

  defp parse_args(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [prompt: :string, yolo: :boolean, demo_approval: :boolean]
      )

    {Keyword.get(opts, :prompt), Keyword.get(opts, :yolo, false),
     Keyword.get(opts, :demo_approval, false)}
  end

  # -- the approval demo (a scripted one-shot edit_file) --------------------

  # Mock backend + `tool_calls_fn` (one-shot): the FIRST completion round
  # returns a single `edit_file` call against a seeded demo file, every
  # later round falls back to plain text. The approval gate is left ON, so
  # the call escalates into the real `approval_requested` -> inline ± diff
  # -> footer selector -> y/n path — the full surface, no provider needed.
  #
  # The demo file lives INSIDE the fs-action sandbox (cwd) — `Fs.resolve/1`
  # rejects anything outside it, which would degrade the preview to an
  # honest-but-ugly `target not located` hunk and refuse the apply. The
  # task deletes the file after halt.
  defp demo_approval_backend do
    path = ".raxol-harness-demo-#{System.unique_integer([:positive])}.txt"

    File.write!(path, "keep this line\nswap me out\nkeep this line too\n")
    # Post-halt cleanup can be raced out by a hard PTY teardown; at_exit
    # is the second net (best-effort — a SIGKILLed VM leaves the dotfile).
    System.at_exit(fn _status -> File.rm(path) end)

    {:ok, once} = Agent.start_link(fn -> :armed end)

    tool_calls_fn = fn ->
      Agent.get_and_update(once, fn
        :armed ->
          {[
             %{
               "id" => "demo-edit-1",
               "name" => "edit_file",
               "arguments" => %{
                 "path" => path,
                 "old_string" => "swap me out",
                 "new_string" => "swapped in by the approval demo"
               }
             }
           ], :spent}

        :spent ->
          {nil, :spent}
      end)
    end

    {Raxol.Agent.Backend.Mock,
     [
       tool_calls_fn: tool_calls_fn,
       response: "edit applied — approval demo complete."
     ], "mock+demo-approval", fn -> File.rm(path) end}
  end

  # -- backend selection (the blessed ExecutorConfig + Selector path) -------

  defp detect_backend do
    cond do
      System.get_env("LM_STUDIO") in ["true", "1"] ->
        live_backend(
          :lm_studio,
          System.get_env("AI_MODEL") || "local-model",
          %{}
        )

      key = System.get_env("AI_API_KEY") ->
        live_backend(:openai, System.get_env("AI_MODEL") || "gpt-4o-mini", %{
          api_key: key
        })

      true ->
        {Raxol.Agent.Backend.Mock,
         [response: "Raxol harness live echo (mock backend)."], "mock"}
    end
  end

  defp live_backend(harness, model, auth) do
    config =
      Raxol.Agent.ExecutorConfig.new(
        harness: harness,
        model: model,
        auth: auth,
        opts: base_url_opts()
      )

    case Raxol.Agent.Backend.Selector.select(config) do
      {:ok, backend, opts} ->
        {backend, opts, Atom.to_string(harness)}

      {:error, _} ->
        {Raxol.Agent.Backend.Mock, [response: "mock (selector fell back)"],
         "mock"}
    end
  end

  defp base_url_opts do
    case System.get_env("AI_BASE_URL") do
      nil ->
        []

      url ->
        # Backend.HTTP's :openai provider appends /v1/chat/completions itself
        # -- strip a conventionally-supplied trailing /v1.
        [
          base_url:
            url |> String.trim_trailing("/") |> String.trim_trailing("/v1")
        ]
    end
  end
end
