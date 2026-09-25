defmodule Raxol.Terminal.Driver.TermboxLifecycleTest do
  @moduledoc """
  `cleanup_terminal/1` runs in the Terminal Driver's `terminate/2`, and so on
  every quit.

  On a TTY the Driver does not own its input reader: it traces the sends of
  OTP's prim_tty reader (`:user_drv_reader`, see `start_stdin_reader/1`).
  `user_drv` treats any non-normal exit of that reader as a crash and stops,
  taking every group leader, and so `:standard_io`, down with it. If cleanup
  exits the reader, the terminal restore it writes next raises `:terminated`,
  the Driver dies mid-cleanup, and quitting an app under `mix run` exits 1
  with the terminal left in the alternate screen (#1115).

  A plain process stands in for the reader: the test must not touch the test
  VM's own `user_drv`.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Driver
  alias Raxol.Terminal.Driver.TermboxLifecycle

  describe "cleanup_terminal/1" do
    test "releases the borrowed input reader without exiting it" do
      {reader, ref} = spawn_monitor(fn -> receive do: (:stop -> :ok) end)
      # As the Driver does at init: trace the reader's sends from the process
      # that later runs cleanup_terminal/1.
      :erlang.trace(reader, true, [:send])

      assert TermboxLifecycle.cleanup_terminal(state_with_reader(reader)) == :ok

      assert Process.alive?(reader)
      refute_received {:DOWN, ^ref, :process, ^reader, _}
      assert :erlang.trace_info(reader, :flags) == {:flags, []}

      send(reader, :stop)
      assert_receive {:DOWN, ^ref, :process, ^reader, :normal}
    end

    @tag :capture_log
    test "completes when the input reader has already exited" do
      {reader, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^reader, :normal}

      assert TermboxLifecycle.cleanup_terminal(state_with_reader(reader)) == :ok
    end
  end

  defp state_with_reader(reader) do
    %Driver.State{
      termbox_state: :initialized,
      io_terminal_state: %{input_reader: reader, tty_fd: nil, tty_port: nil}
    }
  end
end
