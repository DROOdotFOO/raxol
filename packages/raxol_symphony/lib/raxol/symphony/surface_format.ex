defmodule Raxol.Symphony.SurfaceFormat do
  @moduledoc """
  Shared display formatting for Symphony surfaces.

  Consolidates the millisecond duration formatter that the terminal,
  LiveView, and Telegram surfaces each rendered identically.
  """

  @doc """
  Formats a millisecond duration into a compact human string.

  Sub-second values render as `"<n>ms"`, sub-minute as `"<n>s"`, longer as
  `"<m>m<s>s"`. Non-integer input yields `"?"`.
  """
  @spec format_ms(term()) :: String.t()
  def format_ms(ms) when is_integer(ms) and ms < 1_000, do: "#{ms}ms"
  def format_ms(ms) when is_integer(ms) and ms < 60_000, do: "#{div(ms, 1000)}s"

  def format_ms(ms) when is_integer(ms) do
    mins = div(ms, 60_000)
    secs = div(rem(ms, 60_000), 1000)
    "#{mins}m#{secs}s"
  end

  def format_ms(_), do: "?"
end
