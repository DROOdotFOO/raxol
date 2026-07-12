defmodule Raxol.Terminal.Driver.SigwinchHandler do
  @moduledoc """
  `:gen_event` handler on `:erl_signal_server` that forwards SIGWINCH to the
  Driver, because prim_tty sends it to `user_drv`, not the traced reader.
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
