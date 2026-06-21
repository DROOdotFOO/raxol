defmodule Raxol.Demo.LandingScene do
  @moduledoc """
  Self-driving 80x24 hero scene for the axol.io landing page (and X/GIF export).

  One story on rails, front-loaded so the poster frame is the thesis: a
  supervised agent spends only under a mandate a human signed and settles
  privately through Xochi, so the trade never reaches the mempool. A crash
  shows the supervisor restart it with the mandate intact.

  The chrome (wordmark, rule, thesis) is on screen from the first frame; the
  beats reveal underneath at a fast cadence (~13s total). Colors are the axol
  palette as truecolor, which a recorded cast carries verbatim.

  Record it headless with `demos/record_landing_scene.exs`, or interactively in
  an 80x24 terminal with `mix raxol.record -m Raxol.Demo.LandingScene --width 80
  --height 24`.
  """

  use Raxol.Core.Runtime.Application

  @tick_ms 90
  @spinner ~w(| / - \\)

  # axol palette (truecolor); coral carries the brand + the privacy beats, sky is
  # structure/chrome, frost is content, green is the one "safe" check.
  @coral {255, 205, 156}
  @warn {230, 132, 118}
  @sky {88, 161, 198}
  @frost {253, 255, 249}
  @ok {80, 220, 130}

  # Phase budgets in ticks (90ms each); the arc is ~13s with the hook held first.
  @script [
    {:hook, 20},
    {:spawn, 9},
    {:wallet, 8},
    {:mandate, 12},
    {:opportunity, 9},
    {:guard, 10},
    {:settle, 20},
    {:payoff, 24},
    {:crash, 9},
    {:restored, 12},
    {:done, 16}
  ]

  @quote 0.18
  @daily 0.50
  @remaining_after Float.round(@daily - @quote, 2)

  @impl true
  def init(_context) do
    %{phase: :hook, t: 0, total: 0, lines: [], status: nil, done: false}
  end

  @impl true
  def update(:tick, %{done: true} = model), do: {model, [Directive.stop()]}

  def update(:tick, model) do
    model = %{model | t: model.t + 1, total: model.total + 1}

    if model.t >= budget(model.phase), do: advance(model), else: {model, []}
  end

  def update(key_match("q"), model), do: {model, [Directive.stop()]}
  def update(key_match("c", ctrl: true), model), do: {model, [Directive.stop()]}
  def update(_message, model), do: {model, []}

  @impl true
  def subscribe(_model), do: [subscribe_interval(@tick_ms, :tick)]

  # phase machine

  defp advance(model) do
    case next_phase(model.phase) do
      nil -> {%{model | done: true}, []}
      next -> {enter(%{model | phase: next, t: 0}, next), []}
    end
  end

  defp next_phase(phase) do
    @script |> Enum.map(&elem(&1, 0)) |> next_after(phase)
  end

  defp next_after([phase, next | _], phase), do: next
  defp next_after([_ | rest], phase), do: next_after(rest, phase)
  defp next_after([], _phase), do: nil

  defp budget(phase) do
    {_phase, ticks} = Enum.find(@script, {phase, 16}, &(elem(&1, 0) == phase))
    ticks
  end

  # Each phase reveals its beat(s); the hook is just the persistent chrome.
  defp enter(model, :hook), do: model

  defp enter(model, :spawn) do
    add(model, [pair("> spawn", "market-maker-7", "supervised · pid <0.412.0>")])
  end

  defp enter(model, :wallet) do
    add(model, [pair("> wallet", "0xA1..9f", "4.20 ETH")])
  end

  defp enter(model, :mandate) do
    add(model, [
      pair("> mandate", "signed 0xHUMAN", "<= #{eth(@daily)}/day · xochi · 7d")
    ])
  end

  defp enter(model, :opportunity) do
    add(model, [
      blank(),
      text_line("agent   opportunity -> quote #{eth(@quote)}", @frost)
    ])
  end

  defp enter(model, :guard) do
    add(model, [
      marked("guard   #{eth(@quote)} <= #{eth(@daily)} today", "[OK]", @ok)
    ])
  end

  defp enter(model, :settle),
    do: add(model, [{:settle_anim, "settle  routing through Xochi"}])

  defp enter(model, :payoff) do
    model
    |> replace_settle("settle  routed", "private", @coral)
    |> add([
      accent("        tx never hit the mempool; strategy stays dark", @coral)
    ])
  end

  defp enter(model, :crash) do
    add(model, [blank(), accent("[!] <0.412.0> crashed mid-fill", @warn)])
  end

  defp enter(model, :restored) do
    add(model, [
      marked2(
        "[+] supervisor restarted <0.547.0>",
        "mandate intact",
        @ok,
        @frost
      )
    ])
  end

  defp enter(model, :done) do
    %{
      model
      | status:
          "filled #{eth(@quote)} · pnl +0.006 · mandate #{eth(@remaining_after)} left"
    }
  end

  # view

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 0, width: 80} do
      Enum.concat([chrome(), body(model), [status_row(model)]])
    end
  end

  defp chrome do
    [
      row do
        [
          text("RAXOL", fg: @coral, style: [:bold]),
          text("   agent runtime · on-chain commerce", fg: @sky)
        ]
      end,
      text(String.duplicate("-", 72), fg: @sky),
      text("agents spend only under a mandate a human signed, settling private",
        fg: @frost,
        style: [:bold]
      ),
      text("")
    ]
  end

  defp body(model) do
    Enum.map(model.lines, fn
      {:settle_anim, base} -> settle_line(model, base)
      %{kind: :row, segments: segs} -> row(do: Enum.map(segs, &seg/1))
      %{text: t, fg: fg, style: s} -> text(t, fg: fg, style: s)
    end)
  end

  defp seg({t, fg, style}), do: text(t, fg: fg, style: style)

  # The settling beat animates a spinner + progress fill until the payoff resolves it.
  defp settle_line(model, base) do
    frame = Enum.at(@spinner, rem(model.total, length(@spinner)))
    pct = min(100, round(model.t / budget(:settle) * 100))
    filled = div(pct, 10)

    bar =
      String.duplicate("#", filled) <>
        ">" <> String.duplicate(" ", max(0, 9 - filled))

    row do
      [
        text("#{base}    ", fg: @frost),
        text("[#{String.slice(bar, 0, 10)}] #{pct}%  #{frame}", fg: @sky)
      ]
    end
  end

  defp status_row(model) do
    text("  " <> (model.status || ""), fg: @coral, style: [:bold])
  end

  # line builders

  defp add(model, entries), do: %{model | lines: model.lines ++ entries}

  # label (sky) + value (frost) + trailing detail (sky), aligned on columns.
  defp pair(label, value, detail) do
    %{
      kind: :row,
      segments: [
        {String.pad_trailing(label, 11), @sky, []},
        {String.pad_trailing(value, 18), @frost, [:bold]},
        {detail, @sky, []}
      ]
    }
  end

  # left text (frost) + right-aligned marker (color).
  defp marked(left, mark, mark_fg) do
    %{
      kind: :row,
      segments: [
        {String.pad_trailing(left, 44), @frost, []},
        {mark, mark_fg, [:bold]}
      ]
    }
  end

  defp marked2(left, right, left_fg, right_fg) do
    %{
      kind: :row,
      segments: [
        {String.pad_trailing(left, 40), left_fg, [:bold]},
        {right, right_fg, []}
      ]
    }
  end

  defp text_line(t, fg), do: %{text: t, fg: fg, style: []}
  defp accent(t, fg), do: %{text: t, fg: fg, style: [:bold]}
  defp blank, do: %{text: "", fg: @frost, style: []}

  # Swap the live settle-animation row for the resolved one (left + right marker).
  defp replace_settle(model, left, mark, mark_fg) do
    lines =
      Enum.map(model.lines, fn
        {:settle_anim, _} ->
          %{
            kind: :row,
            segments: [
              {String.pad_trailing(left, 44), @frost, []},
              {mark, mark_fg, [:bold]}
            ]
          }

        other ->
          other
      end)

    %{model | lines: lines}
  end

  defp eth(amount),
    do: :erlang.float_to_binary(amount * 1.0, decimals: 2) <> " ETH"
end
