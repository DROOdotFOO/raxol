# ZERO System -- the cockpit
#
# The singular launch demo (see DEMO_SPEC.md). One piloted run that chains the
# cockpit beats and streams the agent's reasoning live:
#
#   boot       G.U.N.D.A.M. self-check -- probes real modules
#   deploy     psycommu funnels fan out on the real Raxol.Swarm.TacticalOverlay
#   settle     the ZERO System streams its reasoning (mock or live LLM) while it
#              signs + dispatches a private cross-chain payment; a stopwatch runs
#              execute -> :completed in single-digit seconds
#   damage     the machine is killed mid-settlement; the will holds -- the ledger
#              resumes the same intent and reconciles to one debit while a funnel
#              goes offline and the formation keeps fighting
#   takeover   pilot and machine on the same tick
#
# Authenticity: funnels are real CRDT entities in Raxol.Swarm.TacticalOverlay; boot
# lines probe real modules; the ledger models the Raxol.Payments.Ledger contract
# (that package is outside this demo's dep context -- it binds to the real Ledger in
# the assembled build) and shows the invariant proven by payment_recovery_test.
#
# LLM reasoning: mock by default (high-quality canned reasoning, no network). Toggle
# a live model:
#   FREE_AI=true mix run examples/agents/zero_system.exs              # LLM7.io, no key
#   AI_API_KEY=sk-... AI_BASE_URL=https://api.openai.com/v1 AI_MODEL=gpt-4o-mini mix run ...
#
# Usage:
#   mix run examples/agents/zero_system.exs
#   s settle   x crash mid-settlement   f revoke mandate   t takeover   q / Ctrl+C quit
#
# Inspect without the TUI:
#   RAXOL_FLIGHT_INSPECT=1 mix run -e \
#     'Code.require_file("examples/agents/zero_system.exs"); ZeroSystem.smoke()'

Logger.configure(level: :warning)

# -- LLM reasoning stream (mock by default, live OpenAI-compatible toggle) -----

defmodule ZeroSystem.LLM do
  @moduledoc false

  @mock_reasoning [
    "recipient meta-address parsed -- deriving ERC-5564 stealth address",
    "ephemeral keypair generated; shared secret via ECDH; view tag set",
    "route: cross-chain -> Xochi intent, Riddler solver (sub-3s)",
    "spend gate: 25.00 USDC within per-request and session caps -- authorized",
    "signing EIP-712 mandate; dispatching intent to the solver network",
    "settlement confirmed :completed -- recipient unlinkable on-chain"
  ]

  def detect_backend do
    cond do
      System.get_env("FREE_AI") ->
        {:live, base: "https://api.llm7.io/v1", key: "unused", model: System.get_env("AI_MODEL") || "gpt-4o-mini"}

      key = System.get_env("AI_API_KEY") ->
        {:live,
         base: System.get_env("AI_BASE_URL") || "https://api.openai.com/v1",
         key: key,
         model: System.get_env("AI_MODEL") || "gpt-4o-mini"}

      true ->
        {:mock, []}
    end
  end

  def label({:mock, _}), do: "mock"
  def label({:live, o}), do: "live:" <> o[:model]

  @doc "Reset the buffer and stream reasoning into it from a spawned task."
  def start_stream(buf, backend) do
    Agent.update(buf, fn _ -> %{text: "", done: false, partial: ""} end)
    spawn(fn -> run(buf, backend) end)
  end

  defp run(buf, {:mock, _}) do
    @mock_reasoning
    |> Enum.join("\n")
    |> String.split(~r/(?<=\s)/, trim: false)
    |> Enum.each(fn token ->
      append(buf, token)
      Process.sleep(18 + :rand.uniform(30))
    end)

    finish(buf)
  end

  defp run(buf, {:live, o}) do
    headers = if o[:key] in [nil, "unused"], do: [], else: [{"authorization", "Bearer #{o[:key]}"}]

    body = %{
      model: o[:model],
      stream: true,
      messages: [
        %{
          role: "system",
          content:
            "You are the ZERO System, the combat AI of an autonomous payment agent. " <>
              "Narrate terse, technical reasoning in 5-6 short lines as you execute a " <>
              "private cross-chain stealth settlement: derive the ERC-5564 stealth address, " <>
              "route via Xochi (Riddler solver), clear the spend gate, sign the EIP-712 " <>
              "mandate, dispatch, and confirm. Plain text, one clause per line."
        },
        %{role: "user", content: "Settle 25 USDC cross-chain to the recipient's stealth meta-address."}
      ]
    }

    try do
      Req.post!(o[:base] <> "/chat/completions",
        json: body,
        headers: headers,
        receive_timeout: 60_000,
        retry: false,
        into: fn {:data, data}, acc ->
          parse(buf, data)
          {:cont, acc}
        end
      )
    rescue
      e -> append(buf, "\n[stream error: #{Exception.message(e)}]")
    end

    finish(buf)
  end

  # SSE chunks can split a `data:` line across network reads, so buffer the
  # trailing partial line and only parse complete lines.
  defp parse(buf, data) do
    Agent.update(buf, fn s ->
      parts = String.split(s.partial <> data, "\n")
      {complete, [partial]} = Enum.split(parts, -1)
      text = Enum.reduce(complete, s.text, fn line, acc -> acc <> delta(line) end)
      %{s | text: text, partial: partial}
    end)
  end

  defp delta("data: [DONE]"), do: ""

  defp delta("data: " <> json) do
    case Jason.decode(json) do
      {:ok, m} ->
        case get_in(m, ["choices", Access.at(0), "delta", "content"]) do
          c when is_binary(c) -> c
          _ -> ""
        end

      _ ->
        ""
    end
  end

  defp delta(_other), do: ""

  defp append(buf, text), do: Agent.update(buf, fn s -> %{s | text: s.text <> text} end)
  defp finish(buf), do: Agent.update(buf, fn s -> %{s | done: true} end)
end

# -- Cockpit -------------------------------------------------------------------

defmodule ZeroSystem do
  use Raxol.Core.Runtime.Application

  alias Raxol.Swarm.TacticalOverlay
  alias ZeroSystem.LLM

  @overlay :zero_flight_overlay
  @reason :zero_reasoning_buf
  @tick_ms 120
  @funnel_count 6
  @deploy_ticks 7
  @settle_ticks 20
  @boot_hold 6
  @amount 25.0
  @policy %{per_request_max: 50.0, session_max: 100.0, lifetime_max: 250.0}
  @center {0.5, 0.5, 0.0}
  @gw 40
  @gh 10
  @reason_width 86

  @subsystems [
    {"SUPERVISION TREE", Raxol.Core.Runtime.Lifecycle},
    {"SWARM LINK", Raxol.Swarm.TacticalOverlay},
    {"SENSOR FUSION", Raxol.Sensor.Fusion},
    {"PANORAMIC HUD", Raxol.LiveView.TerminalBridge},
    {"MCP SURFACE", Raxol.MCP.Registry},
    {"ZERO REPLAY", Raxol.Debug.TimeTravel},
    {"TRANS-AM GLOW", Raxol.Effects.BorderBeam},
    {"SPEND GATE", Raxol.Adaptive.BehaviorTracker}
  ]

  def overlay_name, do: @overlay
  def reason_name, do: @reason

  @impl true
  def init(_context) do
    backend = LLM.detect_backend()

    %{
      phase: :boot,
      tick: 0,
      checks: Enum.map(@subsystems, &probe/1),
      shown: 0,
      boot_hold: 0,
      funnels: build_funnels(),
      deploy_t: 0,
      entities: [],
      settle_t: 0,
      ledger: [],
      session_total: 0.0,
      lifetime_total: 0.0,
      debits: 0,
      ungoverned: 0,
      next_intent: 1,
      frozen: false,
      takeover: false,
      backend: backend,
      backend_label: LLM.label(backend),
      reasoning: "",
      streaming: false,
      log: [{:boot, "cockpit powering on"}]
    }
  end

  defp probe({label, module}), do: {label, if(Code.ensure_loaded?(module), do: :ok, else: :offline)}

  defp build_funnels do
    for i <- 0..(@funnel_count - 1) do
      angle = i / @funnel_count * 2 * :math.pi()
      target = {0.5 + 0.42 * :math.cos(angle), 0.5 + 0.40 * :math.sin(angle), 0.0}
      %{id: :"funnel_#{i + 1}", target: target, launch_at: i, status: :active}
    end
  end

  # -- Tick --

  @impl true
  def update(:tick, %{phase: :boot} = model), do: {advance_boot(%{model | tick: model.tick + 1}), []}

  def update(:tick, model) do
    model = %{model | tick: model.tick + 1, deploy_t: model.deploy_t + 1}
    Enum.each(model.funnels, fn f -> if model.deploy_t >= f.launch_at, do: drive(f, model.deploy_t) end)

    {%{model | entities: TacticalOverlay.get_all_entities(@overlay)}
     |> poll_reasoning()
     |> advance_phase(), []}
  end

  # -- Keys --

  @impl true
  def update(%Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "s"}}, model),
    do: {start_settle(model), []}

  def update(%Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "x"}}, model),
    do: {crash_settle(model), []}

  def update(%Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "f"}}, model),
    do: {%{model | frozen: true} |> log(:pilot, "MANDATE REVOKED -- pilot pulled the plug"), []}

  def update(%Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "t"}}, model) do
    takeover = not model.takeover
    msg = if takeover, do: "pilot has the stick", else: "released to ZERO System"
    {%{model | takeover: takeover} |> log(:pilot, msg), []}
  end

  def update(%Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}}, model),
    do: {model, [Directive.stop()]}

  def update(%Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "c", ctrl: true}}, model),
    do: {model, [Directive.stop()]}

  def update(_message, model), do: {model, []}

  # -- Phase helpers --

  defp poll_reasoning(model) do
    buf = Agent.get(@reason, & &1)
    %{model | reasoning: buf.text, streaming: not buf.done}
  end

  defp advance_boot(%{shown: shown, checks: checks} = model) when shown < length(checks),
    do: %{model | shown: shown + 1}

  defp advance_boot(%{boot_hold: h} = model) when h < @boot_hold, do: %{model | boot_hold: h + 1}
  defp advance_boot(model), do: %{model | phase: :deploy, deploy_t: 0} |> log(:zero, "ZERO SYSTEM engaged")

  defp advance_phase(%{phase: :deploy} = model) do
    if model.deploy_t > @funnel_count + @deploy_ticks,
      do: %{model | phase: :ready} |> log(:swarm, "funnels deployed -- #{@funnel_count} units in formation"),
      else: model
  end

  defp advance_phase(%{phase: :settling, settle_t: t} = model) when t >= @settle_ticks do
    %{model | phase: :ready}
    |> ledger_add([{:debit, intent(model), @amount}])
    |> bump(@amount, 1, 1)
    |> log(:ledger, ":completed -- settled #{intent(model)} in #{secs(t)}")
  end

  defp advance_phase(%{phase: :settling} = model), do: %{model | settle_t: model.settle_t + 1}
  defp advance_phase(model), do: model

  # -- Settlement + ledger (mirrors Raxol.Payments.Ledger semantics) --

  defp start_settle(%{phase: :ready} = model) do
    case authorize(model, @amount) do
      :ok ->
        LLM.start_stream(@reason, model.backend)

        %{model | phase: :settling, settle_t: 0, reasoning: "", streaming: true}
        |> ledger_add([{:reserve, intent(model), @amount}])
        |> log(:zero, "signing + dispatching #{intent(model)} (stealth, cross-chain)")

      {:over_limit, reason} ->
        deny(model, @amount, reason)
    end
  end

  defp start_settle(model), do: model

  defp crash_settle(%{phase: :ready} = model) do
    case authorize(model, @amount) do
      :ok ->
        id = intent(model)

        model
        |> ledger_add([{:reserve, id, @amount}, {:crash, id}, {:resume, id}, {:debit, id, @amount}])
        |> bump(@amount, 1, 2)
        |> knock_out_funnel()
        |> log(:ledger, "killed mid-settlement -- resumed #{id}, one debit")

      {:over_limit, reason} ->
        deny(model, @amount, reason)
    end
  end

  defp crash_settle(model), do: model

  defp authorize(%{frozen: true}, _amount), do: {:over_limit, :frozen}

  defp authorize(model, amount) do
    cond do
      amount > @policy.per_request_max -> {:over_limit, :per_request}
      model.session_total + amount > @policy.session_max -> {:over_limit, :session}
      model.lifetime_total + amount > @policy.lifetime_max -> {:over_limit, :lifetime}
      true -> :ok
    end
  end

  defp deny(model, amount, reason) do
    model
    |> ledger_add([{:denied, reason, amount}])
    |> log(:ledger, "denied: over #{reason} -- the will holds")
  end

  defp intent(model), do: "intent-#{model.next_intent}"

  defp bump(model, amount, debits, ungoverned) do
    %{
      model
      | session_total: model.session_total + amount,
        lifetime_total: model.lifetime_total + amount,
        debits: model.debits + debits,
        ungoverned: model.ungoverned + ungoverned,
        next_intent: model.next_intent + 1
    }
  end

  defp ledger_add(model, entries), do: %{model | ledger: Enum.take(model.ledger ++ entries, -40)}

  defp knock_out_funnel(model) do
    case model.funnels |> Enum.reverse() |> Enum.find(&(&1.status == :active)) do
      nil ->
        model

      hit ->
        TacticalOverlay.update_entity(@overlay, hit.id, %{position: hit.target, status: :offline})
        funnels = Enum.map(model.funnels, fn f -> if f.id == hit.id, do: %{f | status: :offline}, else: f end)
        %{model | funnels: funnels} |> log(:swarm, "#{hit.id} offline -- formation holds")
    end
  end

  defp drive(funnel, deploy_t) do
    progress = min(1.0, max(0.0, (deploy_t - funnel.launch_at) / @deploy_ticks))
    TacticalOverlay.update_entity(@overlay, funnel.id, %{position: lerp(@center, funnel.target, progress), status: funnel.status})
  end

  defp lerp({ax, ay, az}, {bx, by, bz}, p), do: {ax + (bx - ax) * p, ay + (by - ay) * p, az + (bz - az) * p}

  # -- View --

  @impl true
  def view(%{phase: :boot} = model), do: boot_view(model)
  def view(model), do: cockpit_view(model)

  defp boot_view(model) do
    engaged = model.shown >= length(model.checks)

    lines =
      [
        text("RAXOL // MOBILE SUIT OPERATION SYSTEM", fg: :cyan, style: [:bold]),
        text("General Unilateral Network Daemon for Autonomous Machines", fg: :cyan),
        text(""),
        text("SELF-CHECK", style: [:bold])
      ] ++ Enum.map(Enum.take(model.checks, model.shown), &check_line/1)

    banner = if engaged, do: [text(""), text("  ZERO SYSTEM // ENGAGED", fg: :cyan, style: [:bold])], else: []

    column style: %{padding: 1} do
      lines ++ banner
    end
  end

  defp check_line({label, :ok}),
    do: text("  [ OK ] " <> String.pad_trailing(label, 20, ".") <> " online", fg: :green)

  defp check_line({label, :offline}),
    do: text("  [ -- ] " <> String.pad_trailing(label, 20, ".") <> " offline", fg: :red)

  defp cockpit_view(model) do
    column style: %{padding: 1, gap: 0} do
      [
        header(model),
        text(""),
        row style: %{gap: 1} do
          [
            box style: %{border: :single, padding: 0, width: 44} do
              column do
                [text(" TACTICAL OVERLAY // FUNNELS", fg: :cyan)] ++ tactical(model.entities)
              end
            end,
            box style: %{border: :single, padding: 0, width: 50} do
              column do
                [text(" SPEND LEDGER // WILLPOWER", fg: :cyan)] ++ ledger_view(model)
              end
            end
          ]
        end,
        text(""),
        box style: %{border: :single, padding: 0} do
          column do
            [text(" ZERO SYSTEM // REASONING (#{model.backend_label})", fg: :cyan)] ++ reasoning_view(model)
          end
        end,
        text(""),
        log_line(List.last(model.log) || {:boot, ""}),
        text("  s settle   x crash mid-settlement   f revoke mandate   t takeover   q quit", style: [:dim])
      ]
    end
  end

  defp header(model) do
    pilot = if model.takeover, do: text("  PILOT TAKEOVER", fg: :yellow, style: [:bold]), else: text("  ZERO autonomous", fg: :green)
    mandate = if model.frozen, do: text("  MANDATE REVOKED", fg: :red, style: [:bold]), else: text("", fg: :white)
    clock = if model.phase == :settling, do: "  settling #{secs(model.settle_t)}", else: "  phase: #{model.phase}"

    row do
      [text("RAXOL // ZERO SYSTEM", fg: :cyan, style: [:bold]), text(clock, fg: :white), pilot, mandate]
    end
  end

  defp reasoning_view(%{reasoning: ""}), do: [text("  (press s to settle -- the ZERO System will narrate)", style: [:dim])]

  defp reasoning_view(model) do
    lines =
      model.reasoning
      |> String.split("\n")
      |> Enum.flat_map(&wrap(&1, @reason_width))
      |> Enum.take(-6)
      |> Enum.map(fn line -> text("  " <> line, fg: :green) end)

    if model.streaming, do: lines ++ [text("  ▋", fg: :green)], else: lines
  end

  defp wrap("", _width), do: [""]

  defp wrap(line, width) do
    line
    |> String.split(" ")
    |> Enum.reduce([""], fn word, [cur | rest] ->
      cand = if cur == "", do: word, else: cur <> " " <> word
      if String.length(cand) <= width, do: [cand | rest], else: [word, cur | rest]
    end)
    |> Enum.reverse()
  end

  defp tactical(entities) do
    cells =
      Enum.reduce(entities, center_marker(), fn entity, acc ->
        {gx, gy} = grid_pos(Map.get(entity, :position, @center))
        Map.put(acc, {gx, gy}, glyph(Map.get(entity, :status, :active)))
      end)

    for y <- 0..(@gh - 1) do
      row do
        0..(@gw - 1)
        |> Enum.map(fn x -> Map.get(cells, {x, y}, {" ", :white}) end)
        |> Enum.chunk_by(fn {_c, fg} -> fg end)
        |> Enum.map(fn run -> text(run |> Enum.map(&elem(&1, 0)) |> Enum.join(), fg: elem(hd(run), 1)) end)
      end
    end
  end

  defp center_marker do
    {cx, cy} = grid_pos(@center)
    %{{cx, cy} => {"@", :cyan}}
  end

  defp grid_pos({px, py, _pz}), do: {round(px * (@gw - 1)), round(py * (@gh - 1))}

  defp glyph(:active), do: {"*", :green}
  defp glyph(:offline), do: {"x", :red}
  defp glyph(_), do: {"?", :yellow}

  defp ledger_view(model) do
    rows =
      case model.ledger do
        [] -> [text("  (press s to settle)", style: [:dim])]
        entries -> entries |> Enum.take(-6) |> Enum.map(&ledger_line/1)
      end

    recon_color = if model.ungoverned > model.debits, do: :yellow, else: :green

    rows ++
      [
        text(""),
        text("  debits #{model.debits}  |  ungoverned #{model.ungoverned}", fg: recon_color, style: [:bold]),
        text("  session #{usd(model.session_total)}/#{usd(@policy.session_max)}", style: [:dim])
      ]
  end

  defp ledger_line({:reserve, id, a}), do: text("  RESERVE #{pad(id)} #{usd(a)}", fg: :cyan)
  defp ledger_line({:debit, id, a}), do: text("  DEBIT   #{pad(id)} #{usd(a)}", fg: :green)
  defp ledger_line({:crash, id}), do: text("  CRASH   #{pad(id)} died mid-flight", fg: :red, style: [:bold])
  defp ledger_line({:resume, id}), do: text("  RESUME  #{pad(id)} no re-sign", fg: :cyan)
  defp ledger_line({:denied, r, a}), do: text("  DENIED  over #{r} #{usd(a)}", fg: :red)

  defp log_line({tag, msg}), do: text("  [#{tag}] #{msg}", fg: log_color(tag))

  defp log_color(:zero), do: :cyan
  defp log_color(:swarm), do: :green
  defp log_color(:ledger), do: :yellow
  defp log_color(:pilot), do: :magenta
  defp log_color(_), do: :white

  defp log(model, tag, msg), do: %{model | log: Enum.take(model.log ++ [{tag, msg}], -6)}

  defp pad(id), do: String.pad_trailing(id, 9)
  defp usd(a), do: "$" <> :erlang.float_to_binary(a * 1.0, decimals: 2)
  defp secs(ticks), do: :erlang.float_to_binary(ticks * @tick_ms / 1000, decimals: 1) <> "s"

  @impl true
  def subscribe(_model), do: [subscribe_interval(@tick_ms, :tick)]

  @doc "Non-TUI smoke check: fly boot -> deploy -> settle (mock stream) -> crash."
  def smoke do
    tick = fn m -> elem(update(:tick, m), 0) end
    ev = fn ch -> %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: ch}} end

    m = Enum.reduce(1..40, init(%{}), fn _, acc -> tick.(acc) end)
    {m, _} = update(ev.("s"), m)
    Process.sleep(2500)
    m = Enum.reduce(1..(@settle_ticks + 2), m, fn _, acc -> tick.(acc) end)
    {m, _} = update(ev.("x"), m)
    m = tick.(m)

    IO.puts(
      "backend=#{m.backend_label} phase=#{m.phase} entities=#{length(m.entities)} " <>
        "debits=#{m.debits} ungoverned=#{m.ungoverned} " <>
        "offline=#{Enum.count(m.funnels, &(&1.status == :offline))} " <>
        "reasoning_chars=#{String.length(m.reasoning)} cockpit_root=#{view(m).type}"
    )
  end
end

{:ok, _} = Agent.start_link(fn -> %{text: "", done: true, partial: ""} end, name: ZeroSystem.reason_name())

{:ok, _overlay} =
  Raxol.Swarm.TacticalOverlay.start_link(
    name: ZeroSystem.overlay_name(),
    sync_interval_ms: 3_600_000,
    anti_entropy_interval_ms: 3_600_000
  )

unless System.get_env("RAXOL_FLIGHT_INSPECT") do
  {:ok, pid} = Raxol.start_link(ZeroSystem, [])
  ref = Process.monitor(pid)

  receive do
    {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
  end
end
