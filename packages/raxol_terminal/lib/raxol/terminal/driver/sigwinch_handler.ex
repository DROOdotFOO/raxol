defmodule Raxol.Terminal.Driver.SigwinchHandler do
  @moduledoc """
  A `:gen_event` handler installed on `:erl_signal_server` that forwards
  SIGWINCH (terminal window resize) signals to the Driver process.

  Raxol's Driver reads input by trace-intercepting the prim_tty reader's
  data messages, but SIGWINCH is not delivered through the reader: OTP's
  `prim_tty_sighandler` sends it from the `:erl_signal_server` gen_event
  process directly to `user_drv`. So without our own handler the Driver
  never learns the terminal was resized.

  On `:sigwinch` this handler sends `:sigwinch` to the Driver, which then
  queries the fresh terminal size and dispatches a `%Event{type: :resize}`.

  Requires OTP 26+ (`:os.set_signal(:sigwinch, :handle)`); installation
  fails gracefully on older releases.
  """

  @behaviour :gen_event

  @impl true
  def init(%{driver: driver_pid}) when is_pid(driver_pid) do
    # Idempotent; prim_tty_sighandler may have set this already. On OTP < 26
    # :sigwinch is not a valid signal name and this raises, failing the
    # add_handler call cleanly.
    :ok = :os.set_signal(:sigwinch, :handle)
    {:ok, %{driver: driver_pid}}
  rescue
    _ -> {:error, :sigwinch_unsupported}
  end

  @impl true
  def handle_event(:sigwinch, %{driver: driver_pid} = state) do
    send(driver_pid, :sigwinch)
    {:ok, state}
  end

  def handle_event(_signal, state), do: {:ok, state}

  @impl true
  def handle_call(_request, state), do: {:ok, :ok, state}
end
