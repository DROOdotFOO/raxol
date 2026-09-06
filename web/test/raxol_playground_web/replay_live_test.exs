defmodule RaxolPlaygroundWeb.ReplayLiveTest do
  @moduledoc """
  /replay is the one surface on this site that reads a real recorded session,
  so what is asserted here is the loop that makes that possible: the committed
  `.cast` decodes, a position resolves to a screen, and the screen ships as
  addressable rows rather than as one string.

  Everything is derived from the recording rather than named, so re-recording
  it cannot leave this asserting against frames that no longer exist.

  Seeks are driven through the LiveView's own `handle_event/3` and `render/1`
  rather than through a connected `live/2` session, because `live/2` needs
  `lazy_html`, which this app does not carry. The path exercised is the real
  one either way: `phx-click` and the transport hook both arrive as the same
  `"seek"` event, and `render/1` produces the same document the socket would
  diff.
  """
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  alias Phoenix.LiveViewTest
  alias Raxol.Recording.{Asciicast, Index}
  alias RaxolPlaygroundWeb.ReplayLive

  @endpoint RaxolPlaygroundWeb.Endpoint

  # The interval /replay builds its index at. Named here only so the memory
  # assertion measures the same index the page holds.
  @interval_us 150_000

  setup_all do
    path =
      Application.app_dir(:raxol_playground, [
        "priv",
        "recordings",
        "tour.cast"
      ])

    session = Asciicast.read!(path)
    frames = for {us, :output, _data} <- session.events, do: us

    %{session: session, frames: frames, total: secs(List.last(frames))}
  end

  defp dead_render do
    build_conn() |> get("/replay") |> html_response(200)
  end

  defp mounted do
    {:ok, socket} = ReplayLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    socket
  end

  defp seek(socket, frame) do
    {:noreply, socket} = ReplayLive.handle_event("seek", %{"frame" => frame}, socket)
    socket
  end

  defp document(socket) do
    socket.assigns |> ReplayLive.render() |> LiveViewTest.rendered_to_string()
  end

  # The clock the page draws, so the assertions read the same rounding the
  # page does rather than a number transcribed by hand.
  defp secs(us), do: :erlang.float_to_binary(us / 1_000_000, decimals: 1)

  test "GET /replay renders the recording's first frame", ctx do
    html = dead_render()

    # The screen at the first paint: the recorded run has not started, so
    # every suite is pending and its own elapsed clock reads zero.
    assert html =~ "raxol test run"
    assert html =~ "pending"
    assert html =~ "0/380 tests"
    refute html =~ "380/380 tests"

    # The transport addresses the whole recording. An off-by-one `max` makes
    # the last frame unreachable in silence.
    frame_count = Enum.count(ctx.session.events, &(elem(&1, 1) == :output))
    assert html =~ ~s(max="#{frame_count - 1}")
    assert html =~ "0.0s / #{ctx.total}s"
  end

  # A row's markup is the unit the wire cost is measured in: with the screen as
  # one string, a LiveView resends all of it whenever one cell moves. The ids
  # are what the DOM patch keys on, so "one node per row, every row
  # addressable" is the property here, not an implementation detail.
  test "the screen renders one addressable node per terminal row", %{
    session: session
  } do
    html = dead_render()

    for y <- 0..(session.height - 1) do
      assert html =~ ~s(id="replay-row-#{y}")
    end

    refute html =~ ~s(id="replay-row-#{session.height}")
  end

  test "a seek moves the playhead and repaints the screen", ctx do
    html = mounted() |> seek(length(ctx.frames) - 1) |> document()

    # The recorded run finished, which is a different screen and a different
    # clock from the one mount rendered.
    assert html =~ "380/380 tests"
    refute html =~ "pending"
    assert html =~ "#{ctx.total}s / #{ctx.total}s"
  end

  test "an out-of-range seek clamps instead of crashing", %{frames: frames} do
    socket = mounted()

    assert socket |> seek(length(frames) + 500) |> document() =~ "380/380 tests"
    assert socket |> seek(-20) |> document() =~ "0/380 tests"
  end

  test "every keystroke in the recording is a jumpable mark", ctx do
    index = Index.build(ctx.session, interval_us: @interval_us)
    assert index.marks != [], "the recording has no input events to mark"

    html = dead_render()

    assert length(String.split(html, ~s(class="replay-mark"))) - 1 ==
             length(index.marks)

    # A mark is a seek target, not decoration: the frame it points at has to
    # be the frame that keystroke landed in.
    last_mark = List.last(index.marks)
    expected = Enum.find_index(ctx.frames, &(&1 >= last_mark))

    assert html =~ ~s(data-frame="#{expected}")

    assert mounted() |> seek(expected) |> document() =~
             "#{secs(last_mark)}s / #{ctx.total}s"
  end

  # The keyframe index carries full emulator snapshots. It lives in the
  # LiveView's state, and the guarantee is that it stays there.
  #
  # Asserting against the rendered document is not a weaker proxy for the
  # payload: a LiveView's wire diff is exactly its template's dynamics, so an
  # assign absent from the document cannot be in the payload either. The size
  # bound is the blunt half of the same check, since any accidental render of
  # the index (an `inspect`, a stray attribute) would be megabytes.
  test "the index is never serialized to the client", %{session: session} do
    index = Index.build(session, interval_us: @interval_us)
    assert Index.memory_bytes(index) > 1_000_000

    socket = mounted()

    for html <- [document(socket), socket |> seek(12) |> document()] do
      refute html =~ "event_index"
      refute html =~ "keyframes"
      refute html =~ "scroll_region"
      refute html =~ "charset_state"
      assert byte_size(html) < 64_000
    end
  end
end
