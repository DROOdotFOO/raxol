defmodule T0.RingB.Boot do
  @moduledoc """
  Shared `Code.require_file/2` bootstrap. Everything under
  `scripts/harness/t0/ringb/` is deliberately NOT part of `elixirc_paths`
  (see `mix.exs`) — it's a device-control harness, not application code —
  so both `mix t0.ringb` and the `test/harness/ringb_*.exs` suite need to
  load it explicitly. This is the one place that file list is spelled
  out, so the mix task and the tests can never drift out of sync.
  """

  @files ~w(
    driver.ex
    capture.ex
    osa.ex
    guard.ex
    drivers/iterm2.ex
    drivers/terminal_app.ex
    drivers/wezterm.ex
    drivers/kitty.ex
    drivers/ghostty.ex
    measurements.ex
    runner.ex
  )

  @doc """
  Requires every ringb module. `t0_root` (accepted for backward
  compatibility with callers that already resolved it, e.g. the mix
  task) is ignored for path resolution — files are always required
  relative to THIS file's own directory (`ringb/`, via `__DIR__`), never
  relative to the caller's idea of where `scripts/harness/t0` lives.
  """
  @spec require_all!(String.t()) :: :ok
  def require_all!(_t0_root \\ nil) do
    for file <- @files, do: Code.require_file(file, __DIR__)
    :ok
  end
end
