defmodule Raxol.Terminal.InlineDriver.ReaderGateTest do
  @moduledoc """
  Direct protocol suite for `Raxol.Terminal.InlineDriver.ReaderGate`
  against SCRIPTED reader processes -- no real prim_tty reader, no tty.
  Covers the alias-call request/reply, the timeout bound (the fail-closed
  path a future OTP protocol drift degrades to), the dead-reader monitor
  path, and the nil no-op.
  """

  use ExUnit.Case, async: true

  alias Raxol.Terminal.InlineDriver.ReaderGate

  # A process speaking prim_tty's reader protocol: acks disable, then
  # blocks in a selective receive for enable (exactly reader_loop/2's
  # disabled state).
  defp scripted_reader do
    spawn(fn ->
      receive do
        {disable_ref, :disable} ->
          send(disable_ref, {disable_ref, :ok})

          receive do
            {enable_ref, :enable} -> send(enable_ref, {enable_ref, :ok})
          end
      end
    end)
  end

  test "disable then enable against a protocol-speaking reader" do
    reader = scripted_reader()

    assert :ok = ReaderGate.disable(reader, 1_000)
    assert :ok = ReaderGate.enable(reader, 1_000)
  end

  test "a reader that ignores the message (protocol drift) degrades to a bounded timeout -- fail-closed" do
    # This IS the documented failure mode when OTP changes the reader wire
    # protocol: the reader loop's catch-all ignores the unknown message,
    # the gate times out, and the caller ABORTS the suspend rather than
    # handing a contested tty to the editor.
    deaf = spawn(fn -> Process.sleep(:infinity) end)

    assert {:error, :timeout} = ReaderGate.disable(deaf, 50)
    assert {:error, :timeout} = ReaderGate.enable(deaf, 50)
  end

  test "a dead reader surfaces as {:reader_down, reason} via the monitor, not a timeout" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

    assert {:error, {:reader_down, :noproc}} = ReaderGate.disable(dead, 1_000)
    assert {:error, {:reader_down, :noproc}} = ReaderGate.enable(dead, 1_000)
  end

  test "nil reader (headless / piped stdin / no prim_tty) is a documented no-op" do
    assert :ok = ReaderGate.disable(nil, 50)
    assert :ok = ReaderGate.enable(nil, 50)
  end
end
