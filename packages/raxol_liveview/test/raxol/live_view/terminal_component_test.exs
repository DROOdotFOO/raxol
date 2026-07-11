defmodule Raxol.LiveView.TerminalComponentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Raxol.LiveView.TerminalComponent
  alias Raxol.LiveView.Test.BufferHelper, as: Buffer

  describe "coarse live-region reconciliation" do
    test "wrapper div is the single log region; inner pre is application" do
      buffer = Buffer.create_blank_buffer(10, 2)
      html = render_component(TerminalComponent, id: "term", buffer: buffer)

      # The wrapper div carries the sole role="log" aria-live region; the
      # bridge's <pre> renders in :application mode so it is not a second,
      # nested log region announcing the same content.
      assert length(Regex.scan(~r/role="log"/, html)) == 1
      assert html =~ ~s(aria-live="polite")
      assert html =~ ~s(role="application")
      refute html =~ ~r/role="log"[^>]*>\s*<pre[^>]*role="log"/
    end
  end
end
