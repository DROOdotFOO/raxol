defmodule Raxol.Core.Defaults do
  @moduledoc """
  Canonical default values for the Raxol framework.

  These compile-time constants eliminate magic numbers across packages.
  All packages depend on raxol_core, so these are universally accessible.
  """

  # -- Terminal --
  @default_terminal_width 80
  @default_terminal_height 24
  @default_scrollback_limit 1000

  def terminal_width, do: @default_terminal_width
  def terminal_height, do: @default_terminal_height
  def terminal_dimensions, do: {@default_terminal_width, @default_terminal_height}
  def scrollback_limit, do: @default_scrollback_limit

  # -- Terminal size ceilings --
  # Two ceilings, because the cost of a size is paid per frame and who picks
  # the size decides who pays it.
  #
  # The kept screen buffer is the smaller cost: a full width*height grid at
  # ~536 bytes a cell flat (`:erts_debug.flat_size/1` of a fresh
  # `Raxol.Terminal.ScreenBuffer` at 80x24 and 200x50: every cell holding its
  # own style, the size of any copy between processes), ~113 bytes a cell
  # in-process once drawn with shared styles. Rendering a frame is the larger
  # one, and it grows faster than the cell count: measured on one full frame
  # under `environment: :ssh` (Apple M-series, test env), a styled full-screen
  # app took 44 ms and +33 MB of VM memory at 200x60, 415 ms / +143 MB at
  # 512x128, 924 ms / +247 MB at 512x256 and 1.3 s / +226 MB at 1024x128;
  # at 4096x256 it took 220 s and +1.4 GB. The playground app took 9 ms at
  # 200x60, 29 ms at 512x256 (140 KB of output) and 506 ms at 4096x256 (1.07
  # MB of output). A frame is drawn for every keystroke and every resize.
  #
  # LOCAL (`max_terminal_*`): the backstop every buffer, grid and rendering
  # engine clamps to, whatever the surface. Sized for the pilot's own cockpit:
  # one 8K panel (7680x4320 px) at a 6x12 px cell is 1280x360 = 460,800 cells
  # (720x640 rotated to portrait), and two side by side are 2560x360 =
  # 921,600. 4096 per axis is a 24,576 px wall at 6 px cells. It bounds one
  # kept buffer at ~562 MB flat, where an unchecked 100000x100000 request
  # asked for ~5.4 TB.
  #
  # REMOTE (`max_remote_terminal_*`): the size a client on the other end of a
  # network surface (SSH, the `raxol_start` MCP tool) may ask for, since it
  # decides how many of those frames a server pays for. A full-screen
  # terminal on a 4K display at 8x16 px cells is 480x135 = 64,800 cells, and
  # 512x256 holds it with room for a smaller font or a taller window. At the
  # ceiling the worst frame measured above is ~0.9 s and +247 MB, against
  # 220 s and +1.4 GB at the local ceiling; the width is capped hardest
  # because the cost grows faster in width than in height.
  @max_terminal_width 4096
  @max_terminal_height 4096
  @max_terminal_cells 1_048_576

  @max_remote_terminal_width 512
  @max_remote_terminal_height 256
  @max_remote_terminal_cells 131_072

  def max_terminal_width, do: @max_terminal_width
  def max_terminal_height, do: @max_terminal_height
  def max_terminal_cells, do: @max_terminal_cells

  def max_remote_terminal_width, do: @max_remote_terminal_width
  def max_remote_terminal_height, do: @max_remote_terminal_height
  def max_remote_terminal_cells, do: @max_remote_terminal_cells

  @doc "The local terminal size ceiling as `%{width:, height:, cells:}`."
  def terminal_size_ceiling,
    do: %{
      width: @max_terminal_width,
      height: @max_terminal_height,
      cells: @max_terminal_cells
    }

  @doc "The remote terminal size ceiling as `%{width:, height:, cells:}`."
  def remote_terminal_size_ceiling,
    do: %{
      width: @max_remote_terminal_width,
      height: @max_remote_terminal_height,
      cells: @max_remote_terminal_cells
    }

  # -- Timeouts (milliseconds) --
  @default_timeout_ms 5_000
  @default_shutdown_timeout_ms 5_000
  @default_health_check_interval_ms 30_000
  @default_idle_timeout_ms 60_000
  @default_cleanup_interval_ms 60_000
  @default_cooldown_ms 300_000

  def timeout_ms, do: @default_timeout_ms
  def shutdown_timeout_ms, do: @default_shutdown_timeout_ms
  def health_check_interval_ms, do: @default_health_check_interval_ms
  def idle_timeout_ms, do: @default_idle_timeout_ms
  def cleanup_interval_ms, do: @default_cleanup_interval_ms
  def cooldown_ms, do: @default_cooldown_ms

  # -- Animation & UI (milliseconds) --
  @default_animation_duration_ms 300
  @default_debounce_ms 300
  @default_sync_interval_ms 500
  @default_monitor_interval_ms 1_000

  def animation_duration_ms, do: @default_animation_duration_ms
  def debounce_ms, do: @default_debounce_ms
  def sync_interval_ms, do: @default_sync_interval_ms
  def monitor_interval_ms, do: @default_monitor_interval_ms

  # -- Circuit Breaker (milliseconds) --
  @default_cb_open_timeout_ms 30_000
  @default_cb_half_open_timeout_ms 15_000
  @default_cb_reset_timeout_ms 120_000

  def cb_open_timeout_ms, do: @default_cb_open_timeout_ms
  def cb_half_open_timeout_ms, do: @default_cb_half_open_timeout_ms
  def cb_reset_timeout_ms, do: @default_cb_reset_timeout_ms

  # -- Rendering --
  @default_frame_interval_ms 16
  @default_page_size 10

  def frame_interval_ms, do: @default_frame_interval_ms
  def page_size, do: @default_page_size

  # -- UI Defaults --
  @default_selected_style %{reverse: true}

  def selected_style, do: @default_selected_style

  # -- Cache & Limits --
  @default_history_limit 1_000
  @default_cache_ttl_seconds 3_600
  @default_cache_max_bytes 100 * 1024 * 1024

  def history_limit, do: @default_history_limit
  def cache_ttl_seconds, do: @default_cache_ttl_seconds
  def cache_max_bytes, do: @default_cache_max_bytes
end
