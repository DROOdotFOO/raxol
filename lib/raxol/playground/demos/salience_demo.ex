defmodule Raxol.Playground.Demos.SalienceDemo do
  @moduledoc """
  Playground demo: H-K salience colour solver.

  Colours are `(hue, chroma, tier)` seeds; lightness is *solved* against a
  ground (background) lightness rather than hand-picked, compensating for
  the Helmholtz-Kohlrausch effect so every tier reads perceptually level
  regardless of terminal background. Cycling the ground resolves the same
  semantic seed to a different literal hex while the apparent-lightness
  relationship to the ground -- and thus how it reads to the eye -- stays
  constant.
  """
  use Raxol.Core.Runtime.Application
  alias Raxol.Playground.DemoHelpers
  alias Raxol.UI.Theming.{Salience, SalienceTheme}

  @grounds [
    {"dark", 0.10},
    {"mid-gray", 0.50},
    {"light", 0.92}
  ]

  @roles [:accent, :error, :warning, :success, :emphasis, :foreground]

  @impl true
  def init(_context) do
    %{ground_index: 0, role_index: 0, tier_index: 2}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("g") ->
        {cycle(model, :ground_index, length(@grounds)), []}

      key_match("h") ->
        {cycle(model, :role_index, length(@roles)), []}

      key_match("t") ->
        {cycle(model, :tier_index, length(Salience.tiers())), []}

      _ ->
        {model, []}
    end
  end

  defp cycle(model, key, count) do
    Map.update!(model, key, &DemoHelpers.cycle_next(&1, count))
  end

  @impl true
  def view(model) do
    {ground_name, ground_l} = Enum.at(@grounds, model.ground_index)
    role = Enum.at(@roles, model.role_index)
    tier = Enum.at(Salience.tiers(), model.tier_index)
    seed = Enum.find(SalienceTheme.seeds(), &(&1.name == role))

    ladder =
      Salience.tiers()
      |> Enum.with_index()
      |> Enum.map(fn {t, i} ->
        tier_row(seed, t, ground_l, i == model.tier_index)
      end)

    grounds_row =
      @grounds
      |> Enum.with_index()
      |> Enum.map(fn {{name, l}, i} ->
        ground_swatch(seed, tier, name, l, i == model.ground_index)
      end)

    target = Salience.tier_target(tier, ground_l)

    column style: %{gap: 1} do
      [
        text("Salience Demo", style: [:bold]),
        divider(),
        text("Role: #{role}   hue=#{seed.h} chroma=#{fmt(seed.c)}"),
        text("Ground: #{ground_name}   L=#{fmt(ground_l)}"),
        divider(),
        text("Tier ladder solved against this ground:", style: [:dim]),
        column style: %{gap: 0} do
          ladder
        end,
        divider(),
        text("Same seed, tier #{tier}, across grounds:", style: [:dim]),
        row style: %{gap: 1} do
          grounds_row
        end,
        text(
          "apparent-L target #{fmt(target)}  (ground #{fmt(ground_l)} + tier delta #{fmt(Salience.tier_delta(tier))})"
        ),
        text("[h] role  [t] tier  [g] ground", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  # snippet:start
  defp tier_row(seed, tier, ground_l, selected?) do
    hex = Salience.solve(tier, seed.c, seed.h, ground: ground_l)
    prefix = if selected?, do: "> ", else: "  "

    row style: %{gap: 1} do
      [
        text(prefix <> String.pad_trailing(Atom.to_string(tier), 14)),
        swatch(hex, hex)
      ]
    end
  end

  # snippet:end

  defp ground_swatch(seed, tier, ground_name, ground_l, selected?) do
    hex = Salience.solve(tier, seed.c, seed.h, ground: ground_l)
    prefix = if selected?, do: "> ", else: "  "
    swatch(hex, prefix <> ground_name <> " " <> hex)
  end

  defp swatch(hex, label) do
    {l, _c, _h} = Salience.hex_to_oklch(hex)
    contrast = if l > 0.55, do: :black, else: :white
    text(" #{label} ", bg: hex, fg: contrast)
  end

  defp fmt(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)
end
