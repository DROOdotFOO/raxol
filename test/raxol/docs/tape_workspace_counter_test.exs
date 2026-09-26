defmodule Raxol.Docs.TapeWorkspaceCounterTest do
  # assets/tapes/workspace/ is the working directory the MCP-client screenshots
  # are recorded in, so counter.exs is Raxol code shown on camera. It has to be
  # code that runs. Not async: the headless session manager is shared.
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Raxol.Test.GeneratedApp

  @counter Path.expand("../../../assets/tapes/workspace/counter.exs", __DIR__)

  test "the tape workspace counter compiles and renders" do
    assert [counter] = GeneratedApp.compile!([@counter])
    assert counter == Counter

    assert GeneratedApp.render!(counter, "count: 0") =~
             "+/- to change, q to quit"

    ctrl_c = %Raxol.Core.Events.Event{
      type: :key,
      data: %{key: :char, char: "c", ctrl: true}
    }

    assert {_model, [quit]} = counter.update(ctrl_c, counter.init(nil))
    assert quit == Raxol.Core.Runtime.Directive.stop()
  end
end
