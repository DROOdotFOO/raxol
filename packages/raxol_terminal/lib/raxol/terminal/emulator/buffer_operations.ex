defmodule Raxol.Terminal.Emulator.BufferOperations do
  @moduledoc """
  Buffer operation functions extracted from the main emulator module.
  Handles active buffer management and buffer switching operations.
  """

  alias Raxol.Core.Runtime.Log

  # Use map() to accept any emulator-like struct
  @type emulator :: map()

  @doc """
  Gets the active buffer from the emulator based on active_buffer_type.
  """
  @spec get_screen_buffer(map()) :: map() | nil
  def get_screen_buffer(%{active_buffer_type: :alternate, alternate_screen_buffer: buffer})
      when buffer != nil,
      do: buffer

  def get_screen_buffer(%{main_screen_buffer: buffer}), do: buffer
  def get_screen_buffer(_), do: nil

  @doc """
  Updates the active buffer with new buffer data.
  """
  @spec update_active_buffer(emulator(), map()) :: emulator()
  def update_active_buffer(emulator, new_buffer) do
    case emulator.active_buffer_type do
      :main ->
        %{emulator | main_screen_buffer: new_buffer}

      :alternate ->
        %{emulator | alternate_screen_buffer: new_buffer}

      _ ->
        %{emulator | main_screen_buffer: new_buffer}
    end
  end

  @doc """
  Switches to the main screen buffer.
  """
  def switch_to_main_buffer(emulator) do
    %{emulator | active_buffer_type: :main}
  end

  @doc """
  Switches to the alternate screen buffer.
  """
  def switch_to_alternate_buffer(emulator) do
    %{emulator | active_buffer_type: :alternate}
  end

  @doc """
  Clears the entire screen and scrollback buffer.
  """
  def clear_entire_screen_and_scrollback(emulator) do
    emulator = Raxol.Terminal.Operations.ScreenOperations.clear_screen(emulator)
    %{emulator | scrollback_buffer: []}
  end

  @doc """
  Writes data to the output buffer.
  """
  def write_to_output(emulator, data) do
    Raxol.Terminal.OutputManager.write(emulator, data)
  rescue
    error ->
      Log.warning("write_to_output failed: #{inspect(error)}")
      emulator
  end

  @doc """
  Clears the scrollback buffer.
  """
  def clear_scrollback(emulator) do
    %{emulator | scrollback_buffer: []}
  end

  @doc """
  Appends rows evicted by a scroll to the end of the scrollback buffer.

  Order is oldest-first: `emulator.scrollback_buffer` is a chronological
  transcript, so newly evicted rows are appended (never prepended) to keep
  `Emulator.get_scrollback(emulator) ++ <still-on-screen rows>` reading as
  one continuous, in-order history. Trims from the front (the oldest
  entries) when the result would exceed `scrollback_limit`. A no-op for a
  missing/empty eviction list.
  """
  @spec append_scrollback(emulator(), list()) :: emulator()
  def append_scrollback(emulator, lines)

  def append_scrollback(emulator, lines) when lines in [nil, []], do: emulator

  def append_scrollback(emulator, lines) when is_list(lines) do
    combined = (Map.get(emulator, :scrollback_buffer) || []) ++ lines
    limit = Map.get(emulator, :scrollback_limit)

    trimmed =
      case is_integer(limit) and limit >= 0 and length(combined) > limit do
        true -> Enum.drop(combined, length(combined) - limit)
        false -> combined
      end

    %{emulator | scrollback_buffer: trimmed}
  end

  @doc """
  Feeds rows evicted by a scroll-region scroll into the scrollback buffer
  (unit TE).

  Eviction rule: a TOP-ANCHORED scroll region -- `region_top == 0` (screen
  row 1), including the full-screen case where no explicit region is set --
  feeds its evictions into `emulator.scrollback_buffer`; an INTERIOR region
  (`region_top > 0`) discards them; the alternate screen buffer never gets
  scrollback regardless of region, matching real-terminal alt-screen
  semantics.

  Fidelity note: the full-screen and alt-screen halves of this rule match
  real terminals exactly. The PARTIAL top-anchored case (region rows
  1..H-N with footer rows below it) is the harness's print-above scrollback
  model per T0's design -- real terminals vary here (xterm reliably feeds
  native scrollback only for full-screen scrolls), and T0's Ring B measures
  what each tier-1 terminal actually does. The interior-region discard does
  match xterm.

  `region_top` is the 0-based top row of the region that was scrolled,
  captured BEFORE the scroll by the caller (which store it comes from --
  `emulator.scroll_region` vs the buffer's own `scroll_region` -- is the
  caller's concern; see `Raxol.Terminal.Commands.Screen.scroll_up/2`).
  """
  @spec feed_scrollback_from_region_scroll(
          emulator(),
          non_neg_integer(),
          list()
        ) :: emulator()
  def feed_scrollback_from_region_scroll(emulator, region_top, scrolled_lines)

  def feed_scrollback_from_region_scroll(emulator, _region_top, lines)
      when lines in [nil, []],
      do: emulator

  def feed_scrollback_from_region_scroll(
        %{active_buffer_type: :alternate} = emulator,
        _region_top,
        _scrolled_lines
      ),
      do: emulator

  def feed_scrollback_from_region_scroll(emulator, 0, scrolled_lines),
    do: append_scrollback(emulator, scrolled_lines)

  def feed_scrollback_from_region_scroll(
        emulator,
        _interior_region_top,
        _scrolled_lines
      ),
      do: emulator

  @doc """
  Switches to the alternate screen buffer.
  """
  def switch_to_alternate_screen(emulator) do
    switch_to_alternate_buffer(emulator)
  end

  @doc """
  Switches to the normal (main) screen buffer.
  """
  def switch_to_normal_screen(emulator) do
    switch_to_main_buffer(emulator)
  end
end
