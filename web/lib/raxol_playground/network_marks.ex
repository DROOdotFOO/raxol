defmodule RaxolPlayground.NetworkMarks do
  @moduledoc """
  Chain marks for the hero's network row, inlined at compile time.

  Kept apart from `RaxolPlayground.BrandMarks` rather than folded into it,
  because the two hold their files to different contracts and neither one
  bends to the other. A brand mark is a single 24x24 path rendered in
  `currentColor`; a chain mark is the chain's own logo, which is several
  elements in its own viewBox and carries its own fills -- Base is a blue
  disc behind a white cut-out, and reducing it to one monochrome path would
  leave a shape nobody recognises. So this module inlines the whole SVG body
  and keeps each file's viewBox, and the page makes no external request for
  a logo either way.

  Order is the order the row renders, which is chain id ascending with Tron
  last: the six EVM chains are corridors in `Raxol.Payments.Assets`, and Tron
  is reached over the relay rail rather than that table.

  `priv/network_marks/README.md` records where the files came from.
  """

  @dir Path.expand("../../priv/network_marks", __DIR__)

  # `{chain id, display name, file}`. The id is what ties a row to the asset
  # registry: a test holds every EVM chain that carries a token against this
  # list, so a corridor added without a mark fails rather than rendering a
  # network row that quietly omits a chain the product settles on.
  @sources [
    {1, "Ethereum", "ethereum.svg"},
    {10, "Optimism", "optimism.svg"},
    {137, "Polygon", "polygon.svg"},
    {4663, "Robinhood Chain", "robinhood.svg"},
    {8453, "Base", "base.svg"},
    {42_161, "Arbitrum One", "arbitrum.svg"},
    {728_126_428, "Tron", "tron.svg"}
  ]

  for {_id, _name, file} <- @sources do
    @external_resource Path.join(@dir, file)
  end

  # Each file is reduced to `{viewBox, inner markup}` once, here, rather than
  # read per render. A file with no viewBox is a build error: the row sizes
  # every mark to one box and an SVG without one would scale off it.
  @marks (for {id, name, file} <- @sources do
            svg = File.read!(Path.join(@dir, file))

            view_box =
              case Regex.run(~r/viewBox="([^"]+)"/, svg, capture: :all_but_first) do
                [box] -> box
                _ -> raise "#{file} has no viewBox; the row cannot size it"
              end

            body =
              svg
              |> String.replace(~r/<\?xml.*?\?>/s, "")
              |> String.replace(~r/<svg[^>]*>/, "")
              |> String.replace("</svg>", "")
              |> String.trim()

            %{id: id, name: name, view_box: view_box, body: body}
          end)

  @doc "Every chain mark, in row order."
  @spec all() :: [map()]
  def all, do: @marks

  @doc "The chain ids that carry a mark."
  @spec ids() :: [integer()]
  def ids, do: Enum.map(@marks, & &1.id)
end
