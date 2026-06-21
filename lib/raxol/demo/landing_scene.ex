defmodule Raxol.Demo.LandingScene do
  @moduledoc """
  Self-driving 80x24 hero scene for the axol.io landing page (and X/GIF export).

  One story on rails, front-loaded so the poster frame is the thesis: a
  supervised agent spends only under a mandate a human signed and settles
  through Xochi's dark pool, matched off the public mempool but landing as an
  on-chain tx anyone can open on Basescan. A crash shows the supervisor restart
  it mid-fill with the mandate intact.

  The chrome (wordmark, rule, thesis) is on screen from the first frame; the
  beats reveal underneath in three grouped sections (identity, trade, proof) at
  a fast cadence (~13s). Colors are the axol palette as truecolor, which a
  recorded cast carries verbatim: coral is the signature (privacy beat), sky is
  structure, frost is content, green is the safe check.

  Record it headless with `demos/record_landing_scene.exs`, or interactively in
  an 80x24 terminal with `mix raxol.record -m Raxol.Demo.LandingScene --width 80
  --height 24`.
  """

  use Raxol.Core.Runtime.Application

  @tick_ms 90
  @spinner ~w(| / - \\)
  @width 76
  @tx "0x7f3a..e21"

  @coral {255, 205, 156}
  @warn {230, 132, 118}
  @sky {88, 161, 198}
  @frost {253, 255, 249}
  @ok {80, 220, 130}
  @rule {70, 96, 130}
  @indigo {40, 51, 139}

  @script [
    {:hook, 20},
    {:spawn, 9},
    {:wallet, 8},
    {:mandate, 14},
    {:opportunity, 9},
    {:guard, 10},
    {:settle, 20},
    {:payoff, 24},
    {:crash, 9},
    {:restored, 12},
    {:done, 8},
    {:hover, 20}
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

  defp next_phase(phase),
    do: @script |> Enum.map(&elem(&1, 0)) |> next_after(phase)

  defp next_after([phase, next | _], phase), do: next
  defp next_after([_ | rest], phase), do: next_after(rest, phase)
  defp next_after([], _phase), do: nil

  defp budget(phase) do
    {_phase, ticks} = Enum.find(@script, {phase, 16}, &(elem(&1, 0) == phase))
    ticks
  end

  # Each phase reveals its beat(s); the hook is just the persistent chrome.
  defp enter(model, :hook), do: model

  defp enter(model, :spawn),
    do:
      add(model, [pair("spawn", "market-maker-7", "supervised · pid <0.412.0>")])

  defp enter(model, :wallet),
    do: add(model, [pair("wallet", "0xA1..9f", "4.20 ETH")])

  defp enter(model, :mandate),
    do:
      add(model, [
        pair("mandate", "signed 0xHUMAN", "<= #{eth(@daily)}/day · xochi · 7d")
      ])

  defp enter(model, :opportunity),
    do:
      add(model, [
        :divider,
        pair("agent", "opportunity", "quote #{eth(@quote)}")
      ])

  defp enter(model, :guard),
    do:
      add(model, [
        marker_row(
          "guard",
          "#{eth(@quote)} <= #{eth(@daily)} today",
          "[OK]",
          @ok
        )
      ])

  defp enter(model, :settle), do: add(model, [{:settle_anim, "settle"}])

  defp enter(model, :payoff) do
    model
    |> resolve_settle()
    |> add([accent("matched off the public mempool -- settles on-chain", @sky)])
  end

  defp enter(model, :crash),
    do: add(model, [:divider, accent("[!] <0.412.0> crashed mid-fill", @warn)])

  defp enter(model, :restored),
    do:
      add(model, [
        marker2("[+] supervisor restarted <0.547.0>", "mandate intact")
      ])

  defp enter(model, :done) do
    model
    |> add([%{kind: :explorer, hover: false}])
    |> Map.put(
      :status,
      "filled #{eth(@quote)} · pnl +0.006 · mandate #{eth(@remaining_after)} left"
    )
  end

  # The cast can't truly hover (it is playback), so the hover is scripted: a
  # pointer lands on the explorer link and it lights up, held as the loop rests.
  defp enter(model, :hover) do
    lines =
      Enum.map(model.lines, fn
        %{kind: :explorer} = e -> %{e | hover: true}
        other -> other
      end)

    %{model | lines: lines}
  end

  # view

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 0, width: 80} do
      Enum.concat([chrome(), body(model), footer(model)])
    end
  end

  defp chrome do
    [
      row do
        [
          text("RAXOL", fg: @coral, style: [:bold]),
          text("  ·  agent runtime · on-chain commerce", fg: @sky)
        ]
      end,
      text(String.duplicate("─", @width), fg: @rule),
      text(
        "agents spend only under a mandate a human signed, settling privately",
        fg: @frost
      ),
      text("")
    ]
  end

  defp footer(model) do
    [text(""), text("  " <> (model.status || ""), fg: @coral, style: [:bold])]
  end

  defp body(model) do
    Enum.map(model.lines, fn
      {:settle_anim, label} -> settle_line(model, label)
      :divider -> text("  " <> String.duplicate("─", @width - 2), fg: @rule)
      %{kind: :explorer, hover: hover} -> explorer(hover)
      %{kind: :row, segments: segs} -> row(do: Enum.map(segs, &seg/1))
      %{text: t, fg: fg, style: s} -> text(t, fg: fg, style: s)
    end)
  end

  # The explorer link: idle reads as a link (corner arrow, link color); on the
  # scripted hover it gets a pointer and a highlight, the way it lights up under
  # a real mouse in the live terminal.
  defp explorer(false) do
    text("  ↗ basescan.org/tx/#{@tx}", fg: @coral, style: [:underline, :italic])
  end

  defp explorer(true) do
    row do
      [
        text("  ▸ ", fg: @coral, style: [:bold]),
        text(" ↗ basescan.org/tx/#{@tx} ",
          fg: @frost,
          bg: @indigo,
          style: [:bold, :underline, :italic]
        )
      ]
    end
  end

  defp seg({t, fg, style}), do: text(t, fg: fg, style: style)

  # The settling beat animates a block progress bar until the payoff resolves it.
  defp settle_line(model, label) do
    spin = Enum.at(@spinner, rem(model.total, length(@spinner)))
    pct = min(100, round(model.t / budget(:settle) * 100))
    filled = div(pct, 10)
    bar = String.duplicate("▰", filled) <> String.duplicate("▱", 10 - filled)

    row do
      [
        text("  " <> String.pad_trailing(label, 9), fg: @sky),
        text("routing through Xochi   ", fg: @frost),
        text("#{bar}  #{pct}%  #{spin}", fg: @coral)
      ]
    end
  end

  # line builders

  defp add(model, entries), do: %{model | lines: model.lines ++ entries}

  # label (sky) + value (frost) + trailing detail (sky), aligned on columns.
  defp pair(label, value, detail) do
    seg_row([
      {"  " <> String.pad_trailing(label, 9), @sky, []},
      {String.pad_trailing(value, 18), @frost, []},
      {detail, @sky, []}
    ])
  end

  # label + value (frost) + a right-aligned status marker (color).
  defp marker_row(label, value, mark, mark_fg) do
    seg_row([
      {"  " <> String.pad_trailing(label, 9), @sky, []},
      {String.pad_trailing(value, 33), @frost, []},
      {mark, mark_fg, [:bold]}
    ])
  end

  defp marker2(left, right) do
    seg_row([
      {"  " <> String.pad_trailing(left, 40), @ok, []},
      {right, @frost, []}
    ])
  end

  defp seg_row(segments), do: %{kind: :row, segments: segments}

  defp accent(t, fg), do: %{text: "  " <> t, fg: fg, style: []}

  # Swap the live settle-animation row for the resolved one.
  defp resolve_settle(model) do
    lines =
      Enum.map(model.lines, fn
        {:settle_anim, _} ->
          seg_row([
            {"  " <> String.pad_trailing("settle", 9), @sky, []},
            {String.pad_trailing("Xochi dark pool", 33), @frost, []},
            {"matched", @coral, [:bold]}
          ])

        other ->
          other
      end)

    %{model | lines: lines}
  end

  defp eth(amount),
    do: :erlang.float_to_binary(amount * 1.0, decimals: 2) <> " ETH"
end
