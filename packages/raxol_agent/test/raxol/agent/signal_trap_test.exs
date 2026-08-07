defmodule Raxol.Agent.SignalTrapTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.SignalTrap

  # The handler is exercised on a private :gen_event server, NOT
  # :erl_signal_server: notifying the global server also feeds Erlang's
  # default handler, whose reaction to e.g. :sigusr1 is a crash dump.
  # `install/1` targets the real server in production; the unit seam here
  # is the handler's forwarding behavior.
  setup do
    # start_link: the manager dies with the test process, no cleanup needed.
    {:ok, manager} = :gen_event.start_link()
    :ok = :gen_event.add_handler(manager, SignalTrap, self())
    %{manager: manager}
  end

  test "forwards sigterm to the registered pid as a message", %{
    manager: manager
  } do
    :ok = :gen_event.notify(manager, :sigterm)
    assert_receive {:os_signal, :sigterm}, 1_000
  end

  test "ignores other signals", %{manager: manager} do
    :ok = :gen_event.notify(manager, :sigusr1)
    refute_receive {:os_signal, _}, 200
  end
end
