defmodule RaxolPlaygroundWeb.ReplayLive do
  @moduledoc """
  Scrubs a real recorded terminal session in the browser.

  Everything else on this site that looks like a terminal recording is a
  sequence of prerecorded HTML frames: the hero and the gallery cards ship
  every frame to the browser up front and a seek reveals one by toggling
  `hidden`. This page reads an asciicast `.cast` file instead, and computes
  the screen at the scrubbed instant from `Raxol.Terminal.Emulator`.

  ## Why seeking is server-side here, when the other players' is not

  The prerecorded players are right to seek in the browser: every frame is
  already on the page as a hidden sibling of the visible one, so revealing one
  is a `hidden` toggle and a round trip would spend a diff and a patch to show
  markup the browser is already holding.

  A `.cast` has no frames. It is a stream of ANSI bytes, and the screen at
  time `t` only exists once an emulator has consumed everything before `t`, so
  the work cannot happen anywhere but the server. Shipping the whole recording
  plus an emulator to the browser to avoid a round trip would be a far worse
  trade than the round trip.

  What makes that affordable is `TerminalBridge.buffer_to_rows/2`: the screen
  renders as one keyed DOM node per row, so a seek's diff carries only the rows
  whose markup changed. A one-row change is ~0.3 KB where re-rendering the
  screen as a single string would be ~4 KB, and the cost is set by how much of
  the screen moved rather than by how big the screen is.

  ## What is held where

  `Raxol.Recording.Index.build/2` walks the recording once and keeps an
  emulator snapshot every 150 ms, so a seek replays one repaint forward from
  the nearest snapshot instead of the whole prefix. That index holds full
  emulator state and is orders of magnitude larger than the file it indexes,
  so it is built once per node into `:persistent_term` and shared by every
  viewer: `:persistent_term` reads hand back the term without copying it into
  the reader's heap, which is exactly the read-mostly shape this has.

  It never reaches a socket assign that the template touches, so it is never
  serialized: what crosses the wire per seek is the changed rows and the clock.

  ## Surface

  One committed recording, named at compile time. No upload and no path
  parameter: on a public host that is a traversal and abuse surface, and it
  would demonstrate nothing this does not.
  """

  use RaxolPlaygroundWeb, :live_view

  import RaxolPlaygroundWeb.PlaygroundComponents

  alias Raxol.LiveView.TerminalBridge
  alias Raxol.Recording.{Asciicast, Index}
  alias RaxolPlaygroundWeb.Playground.Helpers

  @recording "tour.cast"

  @terminal_theme :synthwave84
  @css_prefix "replay"

  # Keyframe spacing. `Raxol.Recording.Index` defaults to 15 s, which is sized
  # for a long session where the index's memory dominates. This recording is
  # 4 s, so the number that matters instead is how long one drag step blocks
  # the LiveView process, and the index is small enough at any spacing to buy
  # that down. Measured over every position in this recording, MIX_ENV=test:
  #
  #     spacing   keyframes   index    median seek
  #      500 ms       7       1.2 MB      111 ms
  #      250 ms      12       1.9 MB       95 ms
  #      150 ms      17       2.5 MB       70 ms
  #      120 ms      34       4.6 MB       34 ms
  #
  # 150 ms is one repaint of forward replay at this recording's ~120 ms tick,
  # which is where the curve stops paying: 120 ms makes every frame its own
  # keyframe and doubles the index to save 36 ms. The cost is one emulator
  # replay of a ~190 byte frame, measured at ~17 ms; rendering the rows it
  # produces is under a millisecond, so the emulator is the whole seek.
  @interval_us 150_000

  # `Index.buffer_at/3` applies every output event STRICTLY BEFORE its bound,
  # matching `Raxol.Recording.Player.jump_to_us/2` so an indexed seek and a
  # prefix replay land on the same screen. A playhead sitting on a frame should
  # show that frame, so the inclusive position the transport works in converts
  # to that exclusive bound by one microsecond.
  @inclusive 1

  @impl true
  def mount(_params, _session, socket) do
    recording = recording()

    socket
    |> assign_page()
    |> assign_recording(recording)
    |> seek_to(0)
    |> then(&{:ok, &1})
  end

  defp assign_page(socket) do
    socket
    |> assign(:page_title, "Session replay")
    |> assign(:og_title, "Raxol session replay")
    |> assign(:canonical_url, "https://raxol.io/replay")
    |> assign(:theme, @terminal_theme)
    |> assign(:theme_bg, Helpers.theme_bg(@terminal_theme))
    |> assign(:recording_name, @recording)
    # `:application`, not the `:log` default. A log region re-announces its
    # changed rows, and auto-advance repaints ~8x a second, so a screen
    # reader got an unusable stream of partial grids. The slider already
    # announces the position through `aria-valuetext`, which is the thing a
    # listener actually needs from a replay; the screen is then read on
    # demand. `gen_landing_frames.exs` records its frames in this mode for
    # the same reason.
    |> assign(:container_attrs, TerminalBridge.container_attrs(:application))
  end

  defp assign_recording(socket, %{
         session: session,
         index: index,
         frames: frames
       }) do
    socket
    |> assign(:session, session)
    |> assign(:index, index)
    |> assign(:frames, frames)
    |> assign(:frame_count, tuple_size(frames))
    |> assign(:duration_us, index.duration_us)
    |> assign(:tick_ms, tick_ms(frames))
    |> assign(:frame_secs, frame_secs(frames))
    |> assign(:marks, marks(index, frames))
  end

  # -- Events --

  @impl true
  def handle_event("seek", %{"frame" => frame}, socket) do
    {:noreply, seek_to(socket, to_frame(frame))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main-content" tabindex="-1" class="min-h-[100dvh] flex flex-col bg-obsidian">
      <header class="px-8 py-5 surface-bar">
        <div class="flex items-center justify-between gap-8">
          <div class="flex items-center gap-6 min-w-0">
            <a href="/gallery" class="font-mono text-sm subtle-link whitespace-nowrap" aria-label="Back to all components">&larr; Back</a>
            <div class="min-w-0">
              <h1 class="font-mono font-semibold text-pearl" style="font-size: clamp(1rem, 0.9rem + 0.5vw, 1.25rem);">Session replay</h1>
              <p class="font-mono detail-text">
                <%= @session.title %>, recorded to
                <code><%= @recording_name %></code>:
                <%= @frame_count %> frames over <%= format_secs(@duration_us) %>, <%= @session.width %>x<%= @session.height %>
              </p>
            </div>
          </div>
        </div>
      </header>

      <div class="flex-1 flex flex-col min-h-0 p-8 gap-4">
        <%!-- ReplayTransport owns the slider's value and the play loop; the
             server owns the screen, the clock and the marks. The slider's
             value is deliberately NOT a server-rendered dynamic: a value
             arriving from a round trip mid-drag would yank the thumb back to
             where the pointer was one frame ago. --%>
        <div
          id="replay-player"
          phx-hook="ReplayTransport"
          data-frame-count={@frame_count}
          data-frame-ms={@tick_ms}
          data-frame-secs={@frame_secs}
          class="panel flex flex-col"
        >
          <.terminal_chrome title={"asciinema replay: #{@recording_name}"} />
          <div class="replay-screen" style={"background: #{@theme_bg};"} data-theme={@theme}>
            <%!-- One DOM node per row, keyed by the id TerminalBridge mints,
                 so a seek patches only the rows whose markup changed. This is
                 the same shape Raxol.LiveView.TEALive renders; do not collapse
                 it back into one raw string. --%>
            <pre
              id="replay-screen"
              class="raxol-terminal raxol-terminal-rows"
              {@container_attrs}
            ><div :for={row <- @rows} id={row.id} class="raxol-row"><%= Phoenix.HTML.raw(row.html) %></div></pre>
          </div>

          <div class="replay-transport">
            <%!-- Everything the hook writes to lives behind
                 phx-update="ignore". Without it every seek's own patch undoes
                 the hook: LiveView restores a non-focused input's value from
                 the server's markup and morphdom rewrites the button's glyph,
                 so the thumb snapped back to zero and the pause button
                 re-labelled itself on the very round trip it triggered.

                 The marks sit inside it too, and lose nothing by it: they come
                 from the recording's input events, which are fixed for the
                 whole mount.

                 Rendered here rather than left empty for the hook to fill, so
                 the dead render before the socket connects already shows a
                 transport rather than a gap. The clock stays outside: it is
                 the playhead the server just computed, it costs about 20 bytes
                 in the diff, and duplicating the formatting in JS to save that
                 would be the wrong trade. --%>
            <div id="replay-controls" class="replay-transport__controls" phx-update="ignore">
              <button
                type="button"
                data-role="player-toggle"
                data-name={@session.title}
                class="replay-transport__btn"
                aria-label={"Pause the #{@session.title} replay"}
                title={"Pause the #{@session.title} replay"}
              >||</button>
              <div class="replay-track">
                <%!-- A native range, as on the prerecorded players: the
                     arrows, Home, End and PageUp already move it and it
                     announces as a slider. `aria-valuetext` is set by the
                     hook, because the raw value is a frame offset and what a
                     reader wants is the time. --%>
                <input
                  type="range"
                  class="player-seek player-seek--card"
                  data-role="player-seek"
                  min="0"
                  max={@frame_count - 1}
                  step="1"
                  value="0"
                  aria-label={"Scrub the #{@session.title} replay"}
                  aria-valuetext={"0.0s of #{format_secs(@duration_us)}"}
                  title="Space plays and pauses. Left and right step one frame. Home and End jump to the ends. 0 to 9 jump by tenths."
                />
                <%!-- The moments a human typed, straight off `index.marks`.
                     They are buttons rather than decoration on the track
                     because a keystroke is the jump target a reader of a
                     recording actually wants, and a tick that cannot be
                     clicked or focused is just a picture. In the track's own
                     box, under it rather than over it, so a mark lines up with
                     the thumb position it seeks to and never swallows a drag
                     aimed at the slider.

                     `data-frame` rather than phx-click: a mark is a seek, and
                     every seek goes through the transport hook so the thumb,
                     the announced time and the screen move together. Wired
                     straight to the server instead, a mark moved the screen
                     and left the thumb behind. --%>
                <div class="replay-marks" role="group" aria-label="Keystrokes in this recording">
                  <button
                    :for={mark <- @marks}
                    type="button"
                    class="replay-mark"
                    style={"left: #{mark.pct}%;"}
                    data-frame={mark.frame}
                    aria-label={"Jump to the keystroke at #{format_secs(mark.us)}"}
                    title={"Keystroke at #{format_secs(mark.us)}"}
                  ></button>
                </div>
              </div>
            </div>
            <%!-- Decoration: the slider beside it announces the same instant,
                 and a second live number would be read out twice. --%>
            <span class="player-clock" data-role="player-clock" aria-hidden="true"><%= format_secs(@position_us) %> / <%= format_secs(@duration_us) %></span>
          </div>
        </div>

        <p class="font-mono detail-text max-w-3xl">
          Seeking runs on the server. There are no frames in a
          <code>.cast</code> file: the screen at an instant is what
          <code>Raxol.Terminal.Emulator</code> has consumed up to it, replayed
          forward from the nearest keyframe in
          <code>Raxol.Recording.Index</code>. Only the rows whose markup
          changed cross the wire, so a scrub step costs about the same whatever
          the terminal's size.
        </p>
      </div>

      <div class="pg-statusbar font-mono">
        <span class="pg-statusbar-chip">replay</span>
        <span class="pg-statusbar-keys">
          <span :for={{key, action} <- statusbar_keys()} class="pg-key">
            <b><%= key %></b> <%= action %>
          </span>
        </span>
        <span class="pg-statusbar-count">
          <%= @frame_count %> frames, <%= length(@marks) %> keystrokes
        </span>
      </div>
    </main>
    """
  end

  # -- Seeking --

  defp seek_to(socket, frame) do
    frame = clamp(frame, socket.assigns.frame_count)
    us = elem(socket.assigns.frames, frame)

    buffer =
      Index.buffer_at(
        socket.assigns.index,
        socket.assigns.session,
        us + @inclusive
      )

    rows =
      TerminalBridge.buffer_to_rows(buffer,
        theme: @terminal_theme,
        css_prefix: @css_prefix
      )

    socket
    |> assign(:frame, frame)
    |> assign(:position_us, us)
    |> assign(:rows, rows)
  end

  defp clamp(frame, count), do: frame |> max(0) |> min(count - 1)

  defp to_frame(frame) when is_integer(frame), do: frame

  defp to_frame(frame) when is_binary(frame) do
    case Integer.parse(frame) do
      {n, _rest} -> n
      :error -> 0
    end
  end

  # -- Recording --

  # Built once per node. The index is ~1.9 MB of emulator snapshots for a 4 s
  # recording and takes about a second to build, which is not something to
  # repeat per mount (a LiveView mounts twice: dead render, then connected) let
  # alone per seek. `:persistent_term` rather than an ETS table or a GenServer
  # because reads hand the term back without copying it, and there is exactly
  # one writer, once.
  #
  # A cold cache raced by two mounts builds twice and writes the same value
  # twice, which is wasted work rather than a wrong answer, so it is not worth
  # a process to serialize.
  defp recording do
    key = {__MODULE__, @recording}

    case :persistent_term.get(key, nil) do
      nil ->
        built = build_recording()
        :persistent_term.put(key, built)
        built

      built ->
        built
    end
  end

  defp build_recording do
    session = Asciicast.read!(recording_path())
    index = Index.build(session, interval_us: @interval_us)

    # The transport addresses FRAMES, not microseconds: one step of the slider
    # is one repaint the recording actually contains, so there is no dead
    # travel between paints and the keymap the prerecorded players use (arrows
    # step one frame, digits jump by tenths) transfers unchanged. A tuple
    # rather than a list because a drag turns index into time on every step.
    frames =
      for({us, :output, _data} <- session.events, do: us) |> List.to_tuple()

    %{session: session, index: index, frames: frames}
  end

  defp recording_path do
    Application.app_dir(:raxol_playground, ["priv", "recordings", @recording])
  end

  # Marks are the elapsed time of every `:input` event in the recording. Each
  # is resolved to the frame it lands in so clicking one lands the playhead on
  # a real repaint, and to a percentage of the duration so it draws where the
  # slider's thumb will be when it gets there.
  defp marks(index, frames) do
    for us <- index.marks do
      %{us: us, frame: frame_at(frames, us), pct: pct(us, index.duration_us)}
    end
  end

  defp frame_at(frames, us) do
    last = tuple_size(frames) - 1

    Enum.reduce_while(0..last, 0, fn i, acc ->
      if elem(frames, i) <= us, do: {:cont, i}, else: {:halt, acc}
    end)
  end

  defp pct(_us, 0), do: 0.0
  defp pct(us, duration_us), do: Float.round(us * 100 / duration_us, 3)

  # The hook labels the slider with the time at each frame. Shipped as one
  # static attribute at mount rather than re-rendered per seek, so the element
  # the reader is dragging is never patched from the server.
  defp frame_secs(frames) do
    frames
    |> Tuple.to_list()
    |> Enum.map_join(",", &:erlang.float_to_binary(&1 / 1_000_000, decimals: 1))
  end

  # What the hook auto-advances at: the recording's own median gap between
  # repaints, so playback runs at the speed the recorded program ran. Median
  # rather than mean because a recording that pauses while someone types would
  # otherwise play back slower than it happened.
  defp tick_ms(frames) when tuple_size(frames) < 2, do: 120

  defp tick_ms(frames) do
    gaps =
      frames
      |> Tuple.to_list()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)
      |> Enum.sort()

    div(Enum.at(gaps, div(length(gaps), 2)), 1000)
  end

  defp format_secs(us) do
    :erlang.float_to_binary(us / 1_000_000, decimals: 1) <> "s"
  end

  defp statusbar_keys do
    [
      {"space", "play/pause"},
      {"left/right", "step"},
      {"home/end", "ends"},
      {"0-9", "tenths"}
    ]
  end
end
