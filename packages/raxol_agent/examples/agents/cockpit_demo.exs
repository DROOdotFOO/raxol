# Agent Cockpit Demo
#
# Multi-pane dashboard showing supervised agents working in real time,
# rendered entirely through Raxol's View DSL and TEA architecture.
#
# Demonstrates: OTP supervision, crash recovery, inter-agent coordination,
# live system metrics with sparklines, and dramatic crash visualization.
#
# Run with: mix run examples/agents/cockpit_demo.exs

Logger.configure(level: :warning)

# --- Agent Modules ---

defmodule CockpitDemo.FileScanner do
  @moduledoc false
  use Raxol.Agent

  @files ~w(
    lib/raxol/agent.ex
    lib/raxol/agent/session.ex
    lib/raxol/agent/team.ex
    lib/raxol/agent/comm.ex
    lib/raxol/core/runtime/command.ex
    lib/raxol/core/runtime/lifecycle.ex
    lib/raxol/core/runtime/application.ex
    lib/raxol/core/runtime/events/dispatcher.ex
    lib/raxol/terminal/driver.ex
    lib/raxol/ui/components/base/component.ex
    lib/raxol/core/focus_manager.ex
    lib/raxol/sensor/fusion.ex
  )

  def init(_ctx) do
    %{
      remaining: @files,
      scanned: [],
      total_lines: 0,
      current: nil,
      status: :idle
    }
  end

  def update({:agent_message, _from, :start}, model) do
    scan_next(%{model | status: :scanning})
  end

  def update({:command_result, :scan_next}, model), do: scan_next(model)

  def update({:command_result, {:shell_result, %{output: out}}}, model) do
    lines =
      case Integer.parse(String.trim(out)) do
        {n, _} -> n
        :error -> 0
      end

    new_model = %{
      model
      | scanned: [{Path.basename(model.current), lines} | model.scanned],
        total_lines: model.total_lines + lines
    }

    case new_model.remaining do
      [_ | _] -> {new_model, [Directive.schedule(400, :scan_next)]}
      [] -> {%{new_model | current: nil, status: :done}, []}
    end
  end

  def update(_msg, model), do: {model, []}

  defp scan_next(model) do
    case model.remaining do
      [file | rest] ->
        {%{model | remaining: rest, current: file},
         [Directive.shell("wc -l < #{file}")]}

      [] ->
        {%{model | current: nil, status: :done}, []}
    end
  end
end

defmodule CockpitDemo.CodeAnalyzer do
  @moduledoc false
  use Raxol.Agent

  @files ~w(
    lib/raxol/agent.ex
    lib/raxol/agent/session.ex
    lib/raxol/agent/team.ex
    lib/raxol/agent/comm.ex
    lib/raxol/core/runtime/command.ex
    lib/raxol/core/runtime/rendering/engine.ex
    lib/raxol/terminal/driver.ex
    lib/raxol/ui/components/base/component.ex
    lib/raxol/core/focus_manager.ex
    lib/raxol/sensor/fusion.ex
    lib/raxol/sensor/feed.ex
    lib/raxol/swarm/topology.ex
  )

  def init(_ctx) do
    %{remaining: @files, results: [], current: nil, status: :idle}
  end

  def update({:agent_message, _from, :start}, model) do
    analyze_next(%{model | status: :analyzing})
  end

  def update({:command_result, :analyze_next}, model), do: analyze_next(model)

  def update({:command_result, {:shell_result, %{output: out}}}, model) do
    has_docs = String.trim(out) != "0"

    new_model = %{
      model
      | results: [{Path.basename(model.current), has_docs} | model.results]
    }

    case new_model.remaining do
      [_ | _] -> {new_model, [Directive.schedule(500, :analyze_next)]}
      [] -> {%{new_model | current: nil, status: :done}, []}
    end
  end

  def update(_msg, model), do: {model, []}

  defp analyze_next(model) do
    case model.remaining do
      [file | rest] ->
        {%{model | remaining: rest, current: file},
         [Directive.shell("grep -c '@moduledoc' #{file} 2>/dev/null; true")]}

      [] ->
        {%{model | current: nil, status: :done}, []}
    end
  end
end

defmodule CockpitDemo.SystemMonitor do
  @moduledoc false
  use Raxol.Agent

  def init(_ctx) do
    %{checks: 0, stats: %{}, status: :idle, history: [], proc_history: []}
  end

  def update({:agent_message, _from, :start}, model) do
    do_check(%{model | status: :monitoring})
  end

  def update({:command_result, :tick}, model), do: do_check(model)
  def update(_msg, model), do: {model, []}

  defp do_check(model) do
    mem_mb = div(:erlang.memory(:total), 1_048_576)
    proc_count = :erlang.system_info(:process_count)

    stats = %{
      processes: proc_count,
      memory_mb: mem_mb,
      schedulers: :erlang.system_info(:schedulers_online)
    }

    history = Enum.take([mem_mb | model.history], 20)
    proc_history = Enum.take([proc_count | model.proc_history], 20)

    {%{
       model
       | checks: model.checks + 1,
         stats: stats,
         history: history,
         proc_history: proc_history
     }, [Directive.schedule(600, :tick)]}
  end
end

defmodule CockpitDemo.ChaosWorker do
  @moduledoc false
  use Raxol.Agent

  def init(_ctx), do: %{tasks_done: 0, status: :idle}

  def update({:agent_message, _from, :start}, model) do
    {%{model | status: :working}, [Directive.shell("echo ok")]}
  end

  def update({:command_result, :next_task}, model) do
    {model, [Directive.shell("echo task_#{model.tasks_done + 1}")]}
  end

  def update({:command_result, {:shell_result, _}}, model) do
    {%{model | tasks_done: model.tasks_done + 1},
     [Directive.schedule(500, :next_task)]}
  end

  def update(_msg, model), do: {model, []}
end

defmodule CockpitDemo.DepChecker do
  @moduledoc false
  use Raxol.Agent

  def init(_ctx), do: %{deps: [], status: :idle, checked: 0}

  def update({:agent_message, _from, :start}, model) do
    {%{model | status: :checking},
     [Directive.shell("mix deps 2>/dev/null | grep -c 'ok'")]}
  end

  def update({:command_result, {:shell_result, %{output: out}}}, model) do
    count =
      case Integer.parse(String.trim(out)) do
        {n, _} -> n
        :error -> 0
      end

    {%{model | checked: count, status: :done}, []}
  end

  def update(_msg, model), do: {model, []}
end

# --- Dashboard (TEA Architecture) ---

defmodule CockpitDemo do
  @moduledoc false
  use Raxol.Core.Runtime.Application

  alias Raxol.Agent.Session
  alias Raxol.Style.Colors.{Color, Gradient}

  # Agent boot stagger (ticks within :running phase, 200ms per tick)
  @boot_schedule [
    {1, CockpitDemo.FileScanner, :scanner},
    {3, CockpitDemo.CodeAnalyzer, :analyzer},
    {5, CockpitDemo.SystemMonitor, :monitor},
    {7, CockpitDemo.ChaosWorker, :chaos},
    {9, CockpitDemo.DepChecker, :dep_checker}
  ]

  # Crash timeline
  @warn_start 36
  @warn_phase_2 41
  @warn_phase_3 45
  @crash_tick 49
  @crash_flash_ticks 4
  @recover_tick 58
  @post_done_ticks 10

  @header_gradient Gradient.linear(
                     Color.from_hex("#00FFFF"),
                     Color.from_hex("#FF00FF"),
                     21
                   )
  @success_gradient Gradient.linear(
                      Color.from_hex("#00FF00"),
                      Color.from_hex("#00FFFF"),
                      16
                    )
  @splash_ms 2000

  @sparks ~w(\u2581 \u2582 \u2583 \u2584 \u2585 \u2586 \u2587 \u2588)
  @bar_fill "\u2588"
  @bar_empty "\u2591"
  @spinner_chars ["|", "/", "-", "\\"]
  @heartbeat_normal ~w(. _ . - ^ - . _ .)
  @heartbeat_erratic ~w(^ ! ^ _ ! ^ ! _ ^ !)

  # -- TEA Callbacks --

  @impl true
  def init(_context) do
    ensure_infra()

    {w, h} = detect_size()

    %{
      phase: :splash,
      splash_start: System.monotonic_time(:millisecond),
      tick: 0,
      width: w,
      height: h,
      start_time: System.monotonic_time(:second),
      crashes: 0,
      events: [],
      restarted: false,
      scanner: nil,
      analyzer: nil,
      monitor: nil,
      chaos: nil,
      dep_checker: nil,
      pids: %{},
      old_pids: %{},
      uptimes: %{},
      booted: MapSet.new(),
      done_logged: MapSet.new()
    }
  end

  @impl true
  def subscribe(_model), do: [subscribe_interval(200, :tick)]

  @impl true
  def update(message, model) do
    case message do
      :tick ->
        handle_tick(model)

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [command(:quit)]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [command(:quit)]}

      %Raxol.Core.Events.Event{type: :resize, data: %{width: w, height: h}} ->
        {%{model | width: w, height: h}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    case model.phase do
      :splash -> splash_view(model)
      :running -> dashboard_view(model)
      :summary -> summary_view(model)
    end
  end

  # -- Tick Handler --

  defp handle_tick(model) do
    case model.phase do
      :splash ->
        elapsed = System.monotonic_time(:millisecond) - model.splash_start

        if elapsed >= @splash_ms do
          {%{
             model
             | phase: :running,
               start_time: System.monotonic_time(:second)
           }, []}
        else
          {model, []}
        end

      :running ->
        new_model =
          model
          |> staggered_boot()
          |> poll_agents()
          |> track_pids()
          |> handle_chaos()
          |> handle_narration()
          |> track_completions()
          |> maybe_transition_to_summary()

        {%{new_model | tick: new_model.tick + 1}, []}

      :summary ->
        {model, []}
    end
  end

  defp maybe_transition_to_summary(model) do
    if model.restarted and MapSet.member?(model.done_logged, :all_done) and
         model.tick >= @recover_tick + @post_done_ticks do
      %{model | phase: :summary}
    else
      model
    end
  end

  # -- Narrative phase (derived from tick state) --

  defp narrative_phase(model) do
    tick = model.tick

    cond do
      tick < 1 -> :init
      tick <= 10 -> :boot
      tick < @warn_start -> :working
      tick < @crash_tick -> :warning
      tick < @recover_tick -> :crash
      not model.restarted -> :crash
      not MapSet.member?(model.done_logged, :all_done) -> :recovery
      true -> :complete
    end
  end

  defp phase_display(:init), do: {"INITIALIZING", :yellow}
  defp phase_display(:boot), do: {"BOOTING", :cyan}
  defp phase_display(:working), do: {"CONCURRENT WORK", :green}
  defp phase_display(:warning), do: {"!! WARNING !!", :yellow}
  defp phase_display(:crash), do: {"!! CRASH !!", :red}
  defp phase_display(:recovery), do: {"RECOVERING", :green}
  defp phase_display(:complete), do: {"ALL CLEAR", :cyan}

  # ============================================================
  # Visual State (affects all panels during crash)
  # ============================================================

  defp visual_state(model) do
    tick = model.tick

    cond do
      tick >= @warn_phase_3 and tick < @recover_tick ->
        %{other_panels_dim: true, chaos_border: :red, chaos_fg: :red}

      tick >= @warn_phase_2 and tick < @warn_phase_3 ->
        %{other_panels_dim: false, chaos_border: :yellow, chaos_fg: :yellow}

      tick >= @warn_start and tick < @warn_phase_2 ->
        %{other_panels_dim: false, chaos_border: :yellow, chaos_fg: :yellow}

      true ->
        %{other_panels_dim: false, chaos_border: nil, chaos_fg: nil}
    end
  end

  # ============================================================
  # Helper Functions
  # ============================================================

  defp spinner_char(tick) do
    Enum.at(@spinner_chars, rem(tick, length(@spinner_chars)))
  end

  defp mini_bar(current, total, width) when total > 0 do
    filled = div(current * width, total)
    empty = width - filled
    String.duplicate(@bar_fill, filled) <> String.duplicate(@bar_empty, empty)
  end

  defp mini_bar(_current, _total, width) do
    String.duplicate(@bar_empty, width)
  end

  defp heartbeat(tick, :normal) do
    Enum.at(@heartbeat_normal, rem(tick, length(@heartbeat_normal)))
  end

  defp heartbeat(tick, :erratic) do
    Enum.at(@heartbeat_erratic, rem(tick, length(@heartbeat_erratic)))
  end

  defp waiting_panel(title, tick) do
    spin = spinner_char(tick)

    agent_box(title, :idle, nil, [
      text("  #{spin} waiting...", style: [:dim])
    ])
  end

  # ============================================================
  # Views
  # ============================================================

  # -- Gradient helper --

  defp gradient_text(string, gradient) do
    Gradient.apply_to_text(gradient, string)
  end

  # -- Logo element with fallback --

  defp logo_element do
    logo_path =
      Path.join(:code.priv_dir(:raxol), "static/@static/static/images/logo.png")

    if File.exists?(logo_path) and Raxol.Terminal.Image.supported?() do
      image(src: logo_path, width: 30, height: 15)
    else
      ascii_logo()
    end
  end

  defp ascii_logo do
    art = """
                          __
     _________ __  ______  / /
    / ___/ __ `/ |/_/ __ \\/ /
    / /  / /_/ />  </ /_/ / /
    /_/   \\__,_/_/|_/\\____/_/
    """

    column style: %{gap: 0} do
      art
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> text(line, fg: :cyan, style: [:bold]) end)
    end
  end

  # -- Splash View --

  defp splash_view(model) do
    elapsed = System.monotonic_time(:millisecond) - model.splash_start
    progress = min(elapsed / @splash_ms, 1.0)
    bar_width = 30
    filled = round(progress * bar_width)
    empty = bar_width - filled

    bar =
      String.duplicate(@bar_fill, filled) <> String.duplicate(@bar_empty, empty)

    column style: %{padding: 0, gap: 0} do
      [
        spacer(size: max(1, div(model.height - 12, 3))),
        logo_element(),
        spacer(size: 1),
        text(gradient_text("RAXOL AGENT COCKPIT", @header_gradient),
          style: [:bold]
        ),
        spacer(size: 1),
        text("  Initializing agents...", style: [:dim]),
        text("  #{bar}", fg: :cyan),
        bottom_spacer(model.height, div(model.height - 12, 3) + 10),
        text("  raxol.io", style: [:dim])
      ]
    end
  end

  # -- Dashboard View --

  defp dashboard_view(model) do
    uptime = System.monotonic_time(:second) - model.start_time
    vs = visual_state(model)

    column style: %{padding: 0, gap: 0} do
      [
        header_bar(uptime, model),
        spacer(size: 1),
        row style: %{gap: 1} do
          [
            scanner_panel(model, vs),
            analyzer_panel(model, vs)
          ]
        end,
        spacer(size: 1),
        row style: %{gap: 1} do
          [
            monitor_panel(model, vs),
            chaos_panel(model)
          ]
        end,
        spacer(size: 1),
        row style: %{gap: 1} do
          [
            supervision_tree_panel(model),
            event_log_panel(model)
          ]
        end,
        bottom_spacer(model.height, 31),
        key_bar()
      ]
    end
  end

  # -- Summary View --

  defp summary_view(model) do
    scanner = model.scanner
    analyzer = model.analyzer
    dep = model.dep_checker

    lines = (scanner && scanner.total_lines) || 0
    files_scanned = (scanner && length(scanner.scanned)) || 0
    files_analyzed = (analyzer && length(analyzer.results)) || 0
    docs = (analyzer && Enum.count(analyzer.results, fn {_, d} -> d end)) || 0
    deps_ok = (dep && dep.checked) || 0
    uptime = System.monotonic_time(:second) - model.start_time

    old_pid =
      if model.old_pids[:chaos],
        do: inspect(model.old_pids[:chaos]),
        else: "---"

    new_pid =
      if model.pids[:chaos], do: inspect(model.pids[:chaos]), else: "---"

    column style: %{padding: 0, gap: 0} do
      [
        box style: %{border: :double, width: :fill, padding: 0} do
          text("  " <> gradient_text("MISSION COMPLETE", @success_gradient),
            style: [:bold]
          )
        end,
        spacer(size: 1),
        logo_element(),
        spacer(size: 1),
        box style: %{border: :single, width: :fill, padding: 1} do
          column style: %{gap: 0} do
            [
              row style: %{gap: 1} do
                [
                  text("  ", style: [:dim]),
                  text(old_pid, fg: :red),
                  text("->", style: [:dim]),
                  text(new_pid, fg: :green, style: [:bold]),
                  text("(auto-restarted, zero data loss)", style: [:bold])
                ]
              end
            ]
          end
        end,
        spacer(size: 1),
        box style: %{border: :single, width: :fill, padding: 1} do
          column style: %{gap: 0} do
            [
              row style: %{gap: 2} do
                [
                  text("  Files scanned  ", style: [:dim]),
                  text("#{files_scanned}"),
                  text("   Lines counted  ", style: [:dim]),
                  text(fmt(lines))
                ]
              end,
              row style: %{gap: 2} do
                [
                  text("  Doc coverage   ", style: [:dim]),
                  text("#{docs}/#{files_analyzed}"),
                  text("   Dependencies   ", style: [:dim]),
                  text("#{deps_ok} OK")
                ]
              end,
              row style: %{gap: 2} do
                [
                  text("  Crashes        ", style: [:dim]),
                  text("#{model.crashes}"),
                  text("   Data loss      ", style: [:dim]),
                  text("zero", style: [:bold], fg: :green)
                ]
              end,
              row style: %{gap: 2} do
                [
                  text("  Uptime         ", style: [:dim]),
                  text("#{uptime}s")
                ]
              end
            ]
          end
        end,
        spacer(size: 1),
        text(
          "  " <>
            gradient_text(
              "5 GenServers, 1 killed, 0 data lost. OTP supervision.",
              @header_gradient
            ),
          style: [:dim]
        ),
        bottom_spacer(model.height, 24),
        key_bar()
      ]
    end
  end

  # ============================================================
  # Panel Components
  # ============================================================

  defp header_bar(uptime, model) do
    {label, pfg} = phase_display(narrative_phase(model))

    box style: %{border: :double, width: :fill, padding: 0} do
      row style: %{justify_content: :space_between} do
        [
          text("  " <> gradient_text("RAXOL AGENT COCKPIT", @header_gradient),
            style: [:bold]
          ),
          text(">> #{label}", style: [:bold], fg: pfg),
          text("uptime #{fmt_uptime(uptime)}  ", style: [:bold])
        ]
      end
    end
  end

  # -- Scanner Panel: file ticker --

  defp scanner_panel(model, vs) do
    m = model.scanner
    title_style = if vs.other_panels_dim, do: [:dim], else: [:bold]

    if m do
      scanned = length(m.scanned)
      total = scanned + length(m.remaining)

      # Show last 3 completed files + active file with spinner
      recent =
        m.scanned
        |> Enum.take(3)
        |> Enum.map(fn {name, lines} ->
          text("  [+] #{String.pad_trailing(name, 20)} #{lines} lines",
            fg: :green
          )
        end)

      active =
        if m.current do
          spin = spinner_char(model.tick)

          [
            text("  #{spin}  #{Path.basename(m.current)}...",
              style: [:bold]
            )
          ]
        else
          []
        end

      bar = mini_bar(scanned, total, 14)
      progress = text("  #{bar} #{scanned}/#{total}", style: [:dim])

      content = active ++ recent ++ [progress]

      agent_box(
        "File Scanner",
        m.status,
        model.pids[:scanner],
        content,
        uptime: agent_uptime(model, :scanner),
        title_style: title_style
      )
    else
      waiting_panel("File Scanner", model.tick)
    end
  end

  # -- Analyzer Panel: checklist --

  defp analyzer_panel(model, vs) do
    m = model.analyzer
    title_style = if vs.other_panels_dim, do: [:dim], else: [:bold]

    if m do
      checked = length(m.results)
      total = checked + length(m.remaining)

      # Show last 5 results as checklist
      items =
        m.results
        |> Enum.take(5)
        |> Enum.map(fn {name, has_docs} ->
          {icon, fg} = if has_docs, do: {"[+]", :green}, else: {"[-]", :red}
          text("  #{icon} #{name}", fg: fg)
        end)

      active =
        if m.current do
          spin = spinner_char(model.tick)
          [text("  #{spin}  #{Path.basename(m.current)}...", style: [:bold])]
        else
          []
        end

      docs = Enum.count(m.results, fn {_, d} -> d end)

      summary =
        text("  #{docs}/#{checked} documented  #{checked}/#{total} checked",
          style: [:dim]
        )

      content = active ++ items ++ [summary]

      agent_box(
        "Code Analyzer",
        m.status,
        model.pids[:analyzer],
        content,
        uptime: agent_uptime(model, :analyzer),
        title_style: title_style
      )
    else
      waiting_panel("Code Analyzer", model.tick)
    end
  end

  # -- Monitor Panel: dual sparkline --

  defp monitor_panel(model, vs) do
    m = model.monitor
    title_style = if vs.other_panels_dim, do: [:dim], else: [:bold]

    if m && map_size(m.stats) > 0 do
      s = m.stats
      mem_spark = spark_bar(m.history)
      proc_spark = spark_bar(m.proc_history)

      agent_box(
        "System Monitor",
        :monitoring,
        model.pids[:monitor],
        [
          memory_sparkline_row(s.memory_mb, mem_spark),
          proc_sparkline_row(s.processes, proc_spark),
          stat_line("Scheds", "#{s.schedulers}")
        ],
        uptime: agent_uptime(model, :monitor),
        title_style: title_style
      )
    else
      waiting_panel("System Monitor", model.tick)
    end
  end

  # -- Chaos Panel: heartbeat with escalation --

  defp chaos_panel(model) do
    m = model.chaos
    tick = model.tick
    in_flash = tick >= @crash_tick and tick < @crash_tick + @crash_flash_ticks
    in_dead = tick >= @crash_tick + @crash_flash_ticks and tick < @recover_tick

    cond do
      # Crash flash (0.8s)
      in_flash ->
        old_pid = fmt_pid(model.old_pids[:chaos] || model.pids[:chaos])
        crash_flash_box(old_pid, tick - @crash_tick)

      # Dead panel (eerie silence)
      in_dead ->
        dot_count = min(rem(tick - @crash_tick - @crash_flash_ticks, 4) + 1, 3)
        dots = String.duplicate(".", dot_count)

        box style: %{border: :single, width: :fill, padding: 1} do
          column style: %{gap: 0} do
            [
              text("x Chaos Worker", style: [:dim]),
              divider(char: "-"),
              text(""),
              text("  restarting#{dots}", style: [:dim])
            ]
          end
        end

      # Warning phase 3: red border, CRITICAL
      tick >= @warn_phase_3 and m != nil ->
        hb = heartbeat(tick, :erratic)

        box style: %{border: :double, width: :fill, padding: 1} do
          column style: %{gap: 0} do
            [
              row style: %{gap: 1} do
                [
                  text("!", fg: :red),
                  text("Chaos Worker", style: [:bold], fg: :red),
                  text("CRITICAL", style: [:bold], fg: :red)
                ]
              end,
              divider(char: "="),
              stat_line("Tasks", "#{m.tasks_done}"),
              text("  heartbeat  #{hb} #{hb} #{hb}", fg: :red, style: [:bold])
            ]
          end
        end

      # Warning phase 2: bold border, UNSTABLE
      tick >= @warn_phase_2 and m != nil ->
        hb = heartbeat(tick, :erratic)

        box style: %{border: :double, width: :fill, padding: 1} do
          column style: %{gap: 0} do
            [
              row style: %{gap: 1} do
                [
                  text("!", fg: :yellow),
                  text("Chaos Worker", style: [:bold], fg: :yellow),
                  text("UNSTABLE", style: [:bold], fg: :yellow)
                ]
              end,
              divider(char: "-"),
              stat_line("Tasks", "#{m.tasks_done}"),
              text("  heartbeat  #{hb} #{hb} #{hb}", fg: :yellow)
            ]
          end
        end

      # Warning phase 1: yellow, PRESSURE
      tick >= @warn_start and m != nil ->
        hb = heartbeat(tick, :normal)

        agent_box(
          "Chaos Worker",
          m.status,
          model.pids[:chaos],
          [
            stat_line("Tasks", "#{m.tasks_done}"),
            text("  PRESSURE", fg: :yellow),
            text("  heartbeat  #{hb} #{hb} #{hb}", fg: :yellow)
          ],
          uptime: agent_uptime(model, :chaos)
        )

      # Recovered state
      m != nil and model.crashes > 0 and model.restarted ->
        box style: %{border: :double, width: :fill, padding: 1} do
          column style: %{gap: 0} do
            [
              row style: %{gap: 1} do
                [
                  text("*", fg: :green),
                  text("Chaos Worker", style: [:bold], fg: :green),
                  text("RECOVERED", style: [:bold], fg: :green),
                  text(" #{short_pid(model.pids[:chaos])}", style: [:dim])
                ]
              end,
              divider(char: "-"),
              stat_line("Tasks", "#{m.tasks_done}"),
              stat_line("Crashes", "#{model.crashes}"),
              text("  new PID, work resumed", fg: :green)
            ]
          end
        end

      # Normal working state
      m != nil ->
        hb = heartbeat(tick, :normal)

        agent_box(
          "Chaos Worker",
          m.status,
          model.pids[:chaos],
          [
            stat_line("Tasks", "#{m.tasks_done}"),
            text("  heartbeat  #{hb} #{hb} #{hb}", style: [:dim])
          ],
          uptime: agent_uptime(model, :chaos)
        )

      true ->
        waiting_panel("Chaos Worker", model.tick)
    end
  end

  defp event_log_panel(model) do
    entries = model.events |> Enum.take(7) |> Enum.reverse()

    rows =
      Enum.map(entries, fn {elapsed, tag, message} ->
        {tag_label, tag_fg} = tag_display(tag)

        row style: %{gap: 1} do
          [
            text(String.pad_leading("#{elapsed}s", 4), style: [:dim]),
            text(tag_label, style: [:bold], fg: tag_fg),
            text(message)
          ]
        end
      end)

    padding = for _ <- 1..max(0, 7 - length(rows)), do: text("")

    box style: %{border: :single, width: :fill, padding: 1} do
      column style: %{gap: 0} do
        [
          text("Event Log", style: [:bold], fg: :cyan),
          divider(char: "-")
          | rows ++ padding
        ]
      end
    end
  end

  # -- Supervision Tree Panel --

  defp supervision_tree_panel(model) do
    in_crash = model.tick >= @crash_tick and model.tick < @recover_tick

    box style: %{border: :single, width: :fill, padding: 1} do
      column style: %{gap: 0} do
        [
          text("Process Tree", style: [:bold], fg: :cyan),
          divider(char: "-"),
          text("  DynamicSupervisor", style: [:bold])
          | tree_nodes(model, in_crash)
        ]
      end
    end
  end

  defp tree_nodes(model, in_crash) do
    List.flatten([
      tree_node("Scanner  ", :scanner, model, false, in_crash),
      tree_node("Analyzer ", :analyzer, model, false, in_crash),
      tree_node("Monitor  ", :monitor, model, false, in_crash),
      tree_node("Chaos    ", :chaos, model, false, in_crash),
      tree_restart_node(model),
      tree_node("DepCheck ", :dep_checker, model, true, in_crash)
    ])
  end

  defp tree_node(name, id, model, is_last, in_crash) do
    branch = if is_last, do: "  +-- ", else: "  |-- "
    pid = model.pids[id]

    {pid_str, dot, fg} =
      cond do
        id == :chaos and in_crash ->
          old = model.old_pids[:chaos] || pid
          pid_s = if old, do: short_pid(old), else: "---"
          {pid_s, " X KILLED", :red}

        pid != nil ->
          {short_pid(pid), " *", :green}

        MapSet.member?(model.booted, id) ->
          {"---", " o", :yellow}

        true ->
          {"---", " -", :white}
      end

    row style: %{gap: 0} do
      [
        text(branch, style: [:dim]),
        text(name, style: [:bold]),
        text(pid_str, style: [:dim]),
        text(dot, fg: fg)
      ]
    end
  end

  defp tree_restart_node(model) do
    if model.restarted and model.old_pids[:chaos] do
      old_pid = short_pid(model.old_pids[:chaos])

      new_pid =
        if model.pids[:chaos], do: short_pid(model.pids[:chaos]), else: "---"

      [
        row style: %{gap: 0} do
          [
            text("  |  +> ", style: [:dim]),
            text(old_pid, fg: :red),
            text(" -> ", style: [:dim]),
            text(new_pid, fg: :green, style: [:bold]),
            text(" restarted", style: [:dim])
          ]
        end
      ]
    else
      []
    end
  end

  defp key_bar do
    row style: %{gap: 2} do
      [
        text(" q", style: [:bold], fg: :magenta),
        text("quit", style: [:dim])
      ]
    end
  end

  # ============================================================
  # Reusable View Helpers
  # ============================================================

  defp agent_box(title, status, pid, content_rows, opts \\ []) do
    border = if status in [:done, :crashed], do: :double, else: :single
    fg = status_fg(status)
    pid_str = if pid, do: " #{short_pid(pid)}", else: ""
    uptime = Keyword.get(opts, :uptime)
    uptime_str = if uptime, do: " #{uptime}s", else: ""
    title_style = Keyword.get(opts, :title_style, [:bold])

    box style: %{border: border, width: :fill, padding: 1} do
      column style: %{gap: 0} do
        [
          row style: %{gap: 1} do
            [
              text(status_dot(status), fg: fg),
              text(title, style: title_style, fg: fg),
              text(pid_str, style: [:dim]),
              text(uptime_str, style: [:dim])
            ]
          end,
          divider(char: "-")
          | content_rows
        ]
      end
    end
  end

  defp crash_flash_box(old_pid, flash_tick) do
    alert = if rem(flash_tick, 2) == 0, do: "KILLED", else: "X X X"

    box style: %{border: :double, width: :fill, padding: 1} do
      column style: %{gap: 0} do
        [
          row style: %{gap: 1} do
            [
              text("X", fg: :red),
              text("Chaos Worker", style: [:bold], fg: :red),
              text("KILLED", style: [:bold], fg: :red)
            ]
          end,
          divider(char: "="),
          text("    #{alert}", style: [:bold], fg: :red),
          text("    Process.exit(pid, :kill)", style: [:bold], fg: :red),
          text("    PID #{old_pid} terminated", fg: :red)
        ]
      end
    end
  end

  defp stat_line(label, value) do
    row style: %{gap: 1} do
      [
        text("  #{String.pad_trailing(label, 8)}", style: [:dim]),
        text(value, style: [:bold])
      ]
    end
  end

  defp memory_sparkline_row(mem_mb, spark) do
    row style: %{gap: 1} do
      [
        text("  #{String.pad_trailing("Memory", 8)}", style: [:dim]),
        text("#{mem_mb} MB", style: [:bold]),
        text(spark, fg: :cyan)
      ]
    end
  end

  defp proc_sparkline_row(count, spark) do
    row style: %{gap: 1} do
      [
        text("  #{String.pad_trailing("Procs", 8)}", style: [:dim]),
        text("#{count}", style: [:bold]),
        text(spark, fg: :magenta)
      ]
    end
  end

  # ============================================================
  # Agent Lifecycle (side effects in update)
  # ============================================================

  defp bottom_spacer(terminal_height, content_rows) do
    gap = max(1, terminal_height - content_rows - 1)
    spacer(size: gap)
  end

  defp detect_size do
    case {:io.columns(), :io.rows()} do
      {{:ok, w}, {:ok, h}} when w > 0 and h > 0 -> {w, h}
      _ -> {80, 24}
    end
  end

  defp ensure_infra do
    case Registry.start_link(keys: :unique, name: Raxol.Agent.Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Registry.start_link(keys: :duplicate, name: :raxol_event_subscriptions) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case DynamicSupervisor.start_link(
           name: Raxol.DynamicSupervisor,
           strategy: :one_for_one
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp staggered_boot(model) do
    Enum.reduce(@boot_schedule, model, fn {tick, mod, id}, st ->
      cond do
        model.tick == tick and not MapSet.member?(st.booted, id) ->
          DynamicSupervisor.start_child(
            Raxol.DynamicSupervisor,
            {Session, app_module: mod, id: id}
          )

          st
          |> Map.put(:booted, MapSet.put(st.booted, id))
          |> Map.update!(
            :uptimes,
            &Map.put(&1, id, System.monotonic_time(:second))
          )

        model.tick == tick + 1 and MapSet.member?(st.booted, id) and
            not MapSet.member?(st.done_logged, {:started, id}) ->
          Session.send_message(id, :start)

          st
          |> add_event(:boot, "#{agent_name(id)} online")
          |> Map.update!(:done_logged, &MapSet.put(&1, {:started, id}))

        true ->
          st
      end
    end)
  end

  defp poll_agents(model) do
    %{
      model
      | scanner: safe_model(:scanner),
        analyzer: safe_model(:analyzer),
        monitor: safe_model(:monitor),
        chaos: safe_model(:chaos),
        dep_checker: safe_model(:dep_checker)
    }
  end

  defp safe_model(id) do
    case Session.get_model(id) do
      {:ok, m} -> m
      _ -> nil
    end
  end

  defp track_pids(model) do
    ids = [:scanner, :analyzer, :monitor, :chaos, :dep_checker]

    current =
      Enum.reduce(ids, %{}, fn id, acc ->
        case Registry.lookup(Raxol.Agent.Registry, id) do
          [{pid, _}] -> Map.put(acc, id, pid)
          [] -> acc
        end
      end)

    old =
      Enum.reduce(ids, model.old_pids, fn id, acc ->
        case {Map.get(model.pids, id), Map.get(current, id)} do
          {old_pid, new_pid} when old_pid != nil and old_pid != new_pid ->
            Map.put(acc, id, old_pid)

          _ ->
            acc
        end
      end)

    %{model | pids: current, old_pids: old}
  end

  defp handle_chaos(model) do
    cond do
      model.tick == @crash_tick ->
        kill_agent(:chaos)

        model
        |> Map.put(:crashes, model.crashes + 1)
        |> add_event(
          :crash,
          "Chaos Worker killed (#{fmt_pid(model.pids[:chaos])})"
        )

      model.tick == @recover_tick and not model.restarted ->
        Session.send_message(:chaos, :start)

        new_pid =
          case Registry.lookup(Raxol.Agent.Registry, :chaos) do
            [{pid, _}] -> pid
            [] -> nil
          end

        old_pid = model.old_pids[:chaos] || model.pids[:chaos]

        model
        |> Map.put(:restarted, true)
        |> Map.update!(
          :uptimes,
          &Map.put(&1, :chaos, System.monotonic_time(:second))
        )
        |> add_event(
          :recover,
          "#{fmt_pid(old_pid)} -> #{fmt_pid(new_pid)} (new PID!)"
        )

      true ->
        model
    end
  end

  defp kill_agent(id) do
    case Registry.lookup(Raxol.Agent.Registry, id) do
      [{pid, _}] -> Process.exit(pid, :kill)
      [] -> :ok
    end
  end

  defp handle_narration(model) do
    cond do
      model.tick == @warn_start ->
        add_event(model, :warn, "Memory pressure on Chaos Worker")

      model.tick == @warn_phase_2 ->
        add_event(model, :warn, "Chaos Worker becoming unstable")

      model.tick == @warn_phase_3 ->
        add_event(model, :crit, "CRITICAL: Chaos Worker unresponsive")

      model.tick == @crash_tick + 1 ->
        add_event(model, :warn, "Supervisor detected exit :killed")

      model.tick == @crash_tick + @crash_flash_ticks ->
        add_event(model, :warn, "Initiating automatic restart...")

      model.tick == @recover_tick + 2 ->
        add_event(model, :info, "New PID assigned, work resumed")

      all_done?(model) and not MapSet.member?(model.done_logged, :all_done) ->
        model
        |> add_event(:done, "All tasks complete. Zero data loss.")
        |> Map.update!(:done_logged, &MapSet.put(&1, :all_done))

      true ->
        model
    end
  end

  defp all_done?(model) do
    Enum.all?([:scanner, :analyzer], fn key ->
      m = Map.get(model, key)
      m && m.status == :done
    end)
  end

  defp track_completions(model) do
    model
    |> maybe_log_done(:scanner, fn ->
      "Scanner: #{fmt(model.scanner.total_lines)} lines across #{length(model.scanner.scanned)} files"
    end)
    |> maybe_log_done(:analyzer, fn ->
      docs = Enum.count(model.analyzer.results, fn {_, d} -> d end)
      total = length(model.analyzer.results)
      "Analyzer: #{docs}/#{total} modules have @moduledoc"
    end)
    |> maybe_log_done(:dep_checker, fn ->
      "Deps: #{model.dep_checker.checked} dependencies OK"
    end)
  end

  defp maybe_log_done(model, key, msg_fn) do
    m = Map.get(model, key)

    if m && m.status == :done && not MapSet.member?(model.done_logged, key) do
      model
      |> add_event(:info, msg_fn.())
      |> Map.update!(:done_logged, &MapSet.put(&1, key))
    else
      model
    end
  end

  # ============================================================
  # Event Log
  # ============================================================

  defp add_event(model, tag, message) do
    elapsed = System.monotonic_time(:second) - model.start_time
    entry = {elapsed, tag, message}
    %{model | events: Enum.take([entry | model.events], 8)}
  end

  defp tag_display(:boot), do: {"BOOT  ", :cyan}
  defp tag_display(:warn), do: {"WARN  ", :yellow}
  defp tag_display(:crit), do: {"CRIT! ", :red}
  defp tag_display(:crash), do: {"CRASH!", :red}
  defp tag_display(:recover), do: {"RECOV.", :green}
  defp tag_display(:done), do: {"DONE  ", :green}
  defp tag_display(:info), do: {"INFO  ", :cyan}
  defp tag_display(_), do: {"      ", :white}

  # ============================================================
  # Rendering Helpers
  # ============================================================

  defp spark_bar(history) when length(history) < 3, do: ""

  defp spark_bar(history) do
    values = Enum.reverse(Enum.take(history, 10))
    mn = Enum.min(values)
    mx = Enum.max(values)
    range = max(mx - mn, 1)

    values
    |> Enum.map(fn v ->
      idx = min(7, div((v - mn) * 7, range))
      Enum.at(@sparks, idx)
    end)
    |> Enum.join()
  end

  defp status_dot(:idle), do: "o"
  defp status_dot(:crashed), do: "x"
  defp status_dot(:done), do: "*"
  defp status_dot(_active), do: "*"

  defp status_fg(:idle), do: :yellow
  defp status_fg(:scanning), do: :green
  defp status_fg(:analyzing), do: :green
  defp status_fg(:monitoring), do: :green
  defp status_fg(:checking), do: :green
  defp status_fg(:working), do: :green
  defp status_fg(:done), do: :cyan
  defp status_fg(:crashed), do: :red
  defp status_fg(_), do: :white

  defp agent_name(:scanner), do: "File Scanner"
  defp agent_name(:analyzer), do: "Code Analyzer"
  defp agent_name(:monitor), do: "System Monitor"
  defp agent_name(:chaos), do: "Chaos Worker"
  defp agent_name(:dep_checker), do: "Dep Checker"

  # ============================================================
  # Formatters
  # ============================================================

  defp fmt_uptime(s) do
    m = div(s, 60)
    sec = rem(s, 60)
    min_str = m |> Integer.to_string() |> String.pad_leading(2, "0")
    sec_str = sec |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{min_str}:#{sec_str}"
  end

  defp fmt(nil), do: "0"

  defp fmt(n) when is_integer(n) and n >= 1000 do
    "#{div(n, 1000)},#{n |> rem(1000) |> Integer.to_string() |> String.pad_leading(3, "0")}"
  end

  defp fmt(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt(_), do: "0"

  defp fmt_pid(nil), do: "---"
  defp fmt_pid(pid) when is_pid(pid), do: inspect(pid)

  defp agent_uptime(model, id) do
    case model.uptimes[id] do
      nil -> nil
      boot -> System.monotonic_time(:second) - boot
    end
  end

  defp short_pid(pid) when is_pid(pid) do
    pid |> inspect() |> String.replace("PID", "")
  end

  defp short_pid(_), do: ""
end

# --- Start ---

Raxol.Core.Runtime.Log.info("CockpitDemo: Starting...")
{:ok, pid} = Raxol.start_link(CockpitDemo, [])
Raxol.Core.Runtime.Log.info("CockpitDemo: Running. Press 'q' to quit.")

# Keep the script alive until the Lifecycle process exits (e.g. user presses 'q')
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
