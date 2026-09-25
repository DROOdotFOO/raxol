defmodule Raxol.Core.Events.EventManagerStartTest do
  # EventManager is a singleton registered under a global name.
  use ExUnit.Case, async: false

  alias Raxol.Core.Events.EventManager

  # The package README tells applications to list it as a bare child.
  test "a server started as a bare child delivers subscribed events" do
    start_supervised!(EventManager)

    assert {:ok, ref} = EventManager.subscribe([:bare_child_check])
    assert is_reference(ref)

    :ok = EventManager.dispatch(:bare_child_check, %{n: 1})

    assert_receive {:event, :bare_child_check, %{n: 1}}
  end
end
