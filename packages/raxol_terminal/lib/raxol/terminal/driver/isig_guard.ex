defmodule Raxol.Terminal.Driver.IsigGuard do
  @moduledoc false

  # Taking `-isig` back from prim_tty; shared by `Raxol.Terminal.Driver` and
  # `Raxol.Terminal.InlineDriver`.
  #
  # prim_tty applies its own raw mode, which keeps ISIG on, when it
  # (re)initializes the tty and again on every SIGCONT: OTP 26.2 and 27.2
  # `prim_tty:handle_signal(_, cont)` call `tty_set/1`, OTP 29.0
  # `handle_signal(_, sigcont)` calls `tty_init/2`. The SIGCONT write happens
  # whenever `user_drv` gets to the signal, asynchronously to either driver,
  # so a single `raw!` can land first and lose. Hence verify-then-assert:
  # read the LIVE flags, re-assert on ISIG on, and stop only once
  # @confirmations consecutive reads @interval_ms apart show `-isig`, within
  # @attempts reads (a ~3s liveness bound; two or three passes in practice).
  # Where the flags never confirm (no controlling tty, so stty cannot run at
  # all) it gives up silently: nothing here may write bytes into the frame.

  alias Raxol.Terminal.Driver.Stty

  @confirmations 3
  @attempts 60
  @interval_ms 50

  @doc "How many consecutive `-isig` reads `reassert_until_off/1` needs."
  @spec confirmations() :: pos_integer()
  def confirmations, do: @confirmations

  @doc """
  Calls `raw!` whenever the live flags show ISIG on, until they have shown it
  off #{@confirmations} reads in a row (`:confirmed`) or the budget runs out
  (`:gave_up`).
  """
  @spec reassert_until_off((-> term())) :: :confirmed | :gave_up
  def reassert_until_off(raw!), do: reassert(raw!, @attempts, 0)

  defp reassert(_raw!, 0, _confirmed), do: :gave_up
  defp reassert(_raw!, _attempts, @confirmations), do: :confirmed

  defp reassert(raw!, attempts, confirmed) do
    confirmed =
      if Stty.isig_off?() do
        confirmed + 1
      else
        raw!.()
        0
      end

    Process.sleep(@interval_ms)
    reassert(raw!, attempts - 1, confirmed)
  end
end
