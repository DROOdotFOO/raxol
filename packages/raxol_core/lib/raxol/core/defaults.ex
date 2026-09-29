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

  # -- Terminal size ceiling --
  # The largest session any surface (local TTY, SSH, MCP/headless, LiveView,
  # gateway) may allocate. A screen buffer is a full width*height grid, and a
  # grid cell costs ~536 bytes flat (measured: `:erts_debug.flat_size/1` of a
  # fresh `Raxol.Terminal.ScreenBuffer` at 80x24 and 200x50, i.e. every cell
  # holding its own style -- the size of any copy sent between processes) and
  # ~113 bytes in-process once rendered with shared styles. The cell ceiling
  # therefore bounds one buffer at ~562 MB worst case (~118 MB typical), where
  # an unchecked 100000x100000 request asked for ~5.4 TB.
  #
  # Sized for the pilot's own cockpit, not for remote clients: one 8K panel
  # (7680x4320 px) at a 6x12 px cell is 1280x360 = 460,800 cells (640x640
  # rotated to portrait), and two side by side are 2560x360 = 921,600 cells.
  # 4096 per axis is a 24,576 px wall at 6 px cells.
  @max_terminal_width 4096
  @max_terminal_height 4096
  @max_terminal_cells 1_048_576

  def max_terminal_width, do: @max_terminal_width
  def max_terminal_height, do: @max_terminal_height
  def max_terminal_cells, do: @max_terminal_cells

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
