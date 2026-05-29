defmodule Raxol.Recording.Video.Rasterizer do
  @moduledoc """
  Behaviour for turning a standalone HTML document into a single PNG frame.

  The video render target computes each frame server-side (a `Raxol.Core.Buffer`
  rendered to themed HTML via `Raxol.LiveView.TerminalBridge`) and then asks a
  rasterizer to produce the pixels. Backends are swappable: a headless-Chrome
  backend for full theme/effect fidelity, or a pure cell-grid backend for
  browser-free CI rendering.
  """

  @type png :: binary()
  @type size_px :: {pos_integer(), pos_integer()}

  @doc "Render an HTML document to PNG bytes at the given viewport size."
  @callback rasterize(html :: String.t(), size_px(), opts :: keyword()) ::
              {:ok, png()} | {:error, term()}

  @doc "Whether this backend can run in the current environment."
  @callback available?() :: boolean()
end
