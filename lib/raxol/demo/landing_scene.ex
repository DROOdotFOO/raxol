defmodule Raxol.Demo.LandingScene do
  @moduledoc """
  Self-driving 80x24 hero scene for the axol.io landing page.

  One story on rails: a supervised agent spawns with its own wallet, takes a
  mandate a human signed and scoped, finds an opportunity, clears the spend
  against the mandate, and settles privately through Xochi so the trade never
  reaches the mempool. A crash mid-run shows the supervisor restart it with the
  mandate intact.

  The scene advances itself on a timer and stops at the end, so a recorder
  captures a fixed-length cast (the player adds the loop). Designed for 80x24:
  row 1 is the title, row 24 the status line.

  Record it (deterministic, headless) with `demos/record_landing_scene.exs`, or
  interactively in an 80x24 terminal with
  `mix raxol.record -m Raxol.Demo.LandingScene --width 80 --height 24`.
  """

  use Raxol.Core.Runtime.Application

  @tick_ms 90
  @spinner ~w(| / - \\)

  # Each phase emits its lines on entry and holds for `ticks` before the next.
  # Budgets are in ticks (90ms each); the whole arc is ~23s.
  @script [
    {:intro, 10},
    {:spawn, 22},
    {:wallet, 18},
    {:mandate, 30},
    {:opportunity, 22},
    {:guard, 22},
    {:settle, 36},
    {:payoff, 40},
    {:crash, 28},
    {:restored, 24},
    {:done, 34}
  ]

  @quote 0.18
  @daily 0.50
  @remaining_after Float.round(@daily - @quote, 2)

  @impl true
  def init(_context) do
    %{phase: :intro, t: 0, total: 0, lines: [], status: nil, done: false}
    |> enter(:intro)
  end

  @impl true
  def update(:tick, %{done: true} = model), do: {model, [Directive.stop()]}

  def update(:tick, model) do
    model = %{model | t: model.t + 1, total: model.total + 1}

    if model.t >= budget(model.phase) do
      advance(model)
    else
      {model, []}
    end
  end

  def update(key_match("q"), model), do: {model, [Directive.stop()]}
  def update(key_match("c", ctrl: true), model), do: {model, [Directive.stop()]}
  def update(_message, model), do: {model, []}

  @impl true
  def subscribe(_model), do: [subscribe_interval(@tick_ms, :tick)]

  # -- phase machine ----------------------------------------------------------

  defp advance(model) do
    case next_phase(model.phase) do
      nil -> {%{model | done: true}, []}
      next -> {enter(%{model | phase: next, t: 0}, next), []}
    end
  end

  defp next_phase(phase) do
    @script
    |> Enum.map(&elem(&1, 0))
    |> next_after(phase)
  end

  defp next_after([phase, next | _], phase), do: next
  defp next_after([_ | rest], phase), do: next_after(rest, phase)
  defp next_after([], _phase), do: nil

  defp budget(phase) do
    {_phase, ticks} = Enum.find(@script, {phase, 20}, &(elem(&1, 0) == phase))
    ticks
  end

  # Append the lines a phase reveals, and set the status line where it applies.
  defp enter(model, :intro), do: %{model | lines: []}

  defp enter(model, :spawn) do
    add(model, [
      prompt("spawn agent  market-maker-7", "supervised pid <0.412.0>  up 0ms")
    ])
  end

  defp enter(model, :wallet) do
    add(model, [prompt("wallet       0xA1..9f", "balance 4.20 ETH")])
  end

  defp enter(model, :mandate) do
    add(model, [
      prompt("mandate      signed by 0xHUMAN", ""),
      dim(
        "             spend <= #{eth(@daily)}/day   venue xochi   expires 7d"
      ),
      blank()
    ])
  end

  defp enter(model, :opportunity) do
    add(model, [line("agent: opportunity found -> quote #{eth(@quote)}", :cyan)])
  end

  defp enter(model, :guard) do
    add(model, [
      line(
        "guard: within mandate  (#{eth(@quote)} <= #{eth(@daily)} today)  [OK]",
        :green
      )
    ])
  end

  defp enter(model, :settle) do
    add(model, [blank(), {:settle_anim, "settle: routing through Xochi"}])
  end

  defp enter(model, :payoff) do
    model
    |> replace_settle("settle: routed through Xochi          private")
    |> add([
      line("       tx never hit the mempool -- strategy stays dark", :yellow, [
        :bold
      ])
    ])
  end

  defp enter(model, :crash) do
    add(model, [blank(), line("!! process <0.412.0> crashed mid-run", :red)])
  end

  defp enter(model, :restored) do
    add(model, [
      line("-> supervisor restarted market-maker-7 <0.547.0>", :green),
      dim("   mandate intact; resumed where it left off")
    ])
  end

  defp enter(model, :done) do
    %{
      model
      | status:
          "filled #{eth(@quote)}   pnl +0.006 ETH   mandate #{eth(@remaining_after)} left"
    }
  end

  # -- view -------------------------------------------------------------------

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 0, width: 80} do
      Enum.concat([[title(), blank_text()], body(model), [status_row(model)]])
    end
  end

  defp title do
    text("Raxol -- agent runtime for on-chain commerce",
      fg: :cyan,
      style: [:bold]
    )
  end

  defp body(model) do
    Enum.map(model.lines, fn entry ->
      case entry do
        {:settle_anim, base} -> settle_line(model, base)
        %{text: t, fg: fg, style: s} -> text(t, fg: fg, style: s)
      end
    end)
  end

  # The settling beat animates a spinner + progress fill until the payoff resolves it.
  defp settle_line(model, base) do
    frame = Enum.at(@spinner, rem(model.total, length(@spinner)))
    pct = min(100, round(model.t / budget(:settle) * 100))
    filled = div(pct, 10)
    bar = String.duplicate("#", filled) <> String.duplicate(".", 10 - filled)
    text("#{base} #{frame} [#{bar}] #{pct}%", fg: :yellow)
  end

  defp status_row(model) do
    text("  " <> (model.status || ""), fg: :magenta, style: [:bold])
  end

  # -- line helpers -----------------------------------------------------------

  defp add(model, entries), do: %{model | lines: model.lines ++ entries}

  defp prompt(label, detail) do
    line("> #{label}   #{detail}" |> String.trim_trailing(), :white)
  end

  defp line(t, fg, style \\ []), do: %{text: "  " <> t, fg: fg, style: style}
  defp dim(t), do: %{text: "  " <> t, fg: :white, style: [:faint]}
  defp blank, do: %{text: "", fg: :white, style: []}
  defp blank_text, do: text("")

  # Swap the live settle-animation line for the resolved one.
  defp replace_settle(model, resolved) do
    lines =
      Enum.map(model.lines, fn
        {:settle_anim, _} ->
          %{text: "  " <> resolved, fg: :yellow, style: [:bold]}

        other ->
          other
      end)

    %{model | lines: lines}
  end

  defp eth(amount),
    do: "#{:erlang.float_to_binary(amount * 1.0, decimals: 2)} ETH"
end
