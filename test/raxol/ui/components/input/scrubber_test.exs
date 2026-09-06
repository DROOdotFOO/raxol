defmodule Raxol.UI.Components.Input.ScrubberTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Accessibility.Projection
  alias Raxol.Core.Events.Event
  alias Raxol.MCP.TreeWalker
  alias Raxol.UI.Components.Input.Scrubber

  defp key(k), do: %Event{type: :key, data: %{key: k}}
  defp char(c), do: %Event{type: :key, data: %{key: :char, char: c}}

  defp tool_context(node),
    do: %{widget_id: node.id, widget_state: node, dispatcher_pid: nil}

  describe "track/1" do
    test "puts the playhead on the column matching the position" do
      at = fn position ->
        Scrubber.track(position: position, width: 11, min: 0, max: 10)
      end

      assert at.(0) == "●──────────"
      assert at.(5) == "━━━━━●─────"
      assert at.(10) == "━━━━━━━━━━●"
    end

    test "renders the requested width regardless of range size" do
      assert String.length(Scrubber.track(width: 7, min: 0, max: 999)) == 7
      assert String.length(Scrubber.track(width: 40, min: 0, max: 3)) == 40
    end

    test "addresses a range that does not start at zero" do
      # A wrapped TimeTravel ring addresses first..last, not 0..count-1.
      assert Scrubber.track(width: 5, min: 7, max: 11, position: 7) ==
               "●────"

      assert Scrubber.track(width: 5, min: 7, max: 11, position: 11) ==
               "━━━━●"
    end

    test "collapses a single-position range onto the first column" do
      assert Scrubber.track(width: 4, min: 5, max: 5, position: 5) == "●───"
    end

    test "shows marks and never lets one hide the playhead" do
      assert Scrubber.track(width: 11, min: 0, max: 10, position: 8, marks: [3]) ==
               "━━━┃━━━━●──"

      assert Scrubber.track(width: 11, min: 0, max: 10, position: 4, marks: [4]) ==
               "━━━━●──────"
    end

    test "drops out-of-range marks instead of stacking them on the ends" do
      assert Scrubber.track(
               width: 11,
               min: 0,
               max: 10,
               position: 5,
               marks: [-3, 42]
             ) == "━━━━━●─────"
    end

    test "clamps a position outside the range" do
      assert Scrubber.track(width: 5, min: 0, max: 4, position: 99) == "━━━━●"
      assert Scrubber.track(width: 5, min: 0, max: 4, position: -9) == "●────"
    end
  end

  describe "clock/1" do
    test "reads mm:ss against a known duration" do
      assert Scrubber.clock(elapsed_ms: 63_000, duration_ms: 125_000) ==
               "01:03 / 02:05"

      assert Scrubber.clock(elapsed_ms: 0, duration_ms: 4_300) == "00:00 / 00:04"
    end

    test "falls back to the index pair when no duration is known" do
      # An asciicast has no linear index-to-time map, so inventing a
      # timestamp from the index would be a lie.
      assert Scrubber.clock(position: 12, min: 0, max: 47) == "12/47"
    end
  end

  describe "line/1" do
    test "omits the speed label at 1x and shows it otherwise" do
      at = fn speed ->
        Scrubber.line(speed: speed, width: 5, min: 0, max: 4, position: 0)
      end

      refute at.(1.0) =~ "x"
      assert at.(2.0) =~ "2x"
      assert at.(0.5) =~ "0.5x"
    end

    test "keeps the clock in the same column when the transport toggles" do
      playing = Scrubber.line(width: 5, min: 0, max: 4, playing?: true)
      paused = Scrubber.line(width: 5, min: 0, max: 4, playing?: false)

      assert String.length(playing) == String.length(paused)
    end
  end

  describe "handle_event/3 transport" do
    test "space toggles play and runs the matching callback" do
      state =
        Scrubber.new(
          min: 0,
          max: 9,
          on_play: fn -> :played end,
          on_pause: fn -> :paused end
        )

      assert {%{playing?: true}, [:played]} =
               Scrubber.handle_event(key(:space), state, %{})

      assert {%{playing?: false}, [:paused]} =
               Scrubber.handle_event(
                 key(:space),
                 %{state | playing?: true},
                 %{}
               )
    end

    test "steps one position and reports the new position" do
      state = Scrubber.new(min: 0, max: 9, position: 4, on_seek: &{:seek, &1})

      assert {%{position: 5}, [{:seek, 5}]} =
               Scrubber.handle_event(key(:right), state, %{})

      assert {%{position: 3}, [{:seek, 3}]} =
               Scrubber.handle_event(key(:left), state, %{})
    end

    test "emits nothing when a step is already clamped at an end" do
      # Holding an arrow at the end must not fire a seek per repeat.
      at_end = Scrubber.new(min: 0, max: 9, position: 9, on_seek: &{:seek, &1})

      assert {%{position: 9}, []} =
               Scrubber.handle_event(key(:right), at_end, %{})

      at_start = %{at_end | position: 0}

      assert {%{position: 0}, []} =
               Scrubber.handle_event(key(:left), at_start, %{})
    end

    test "home and end jump to the range bounds" do
      state = Scrubber.new(min: 7, max: 11, position: 9)

      assert {%{position: 7}, _} = Scrubber.handle_event(key(:home), state, %{})
      assert {%{position: 11}, _} = Scrubber.handle_event(key(:end), state, %{})
    end

    test "a digit jumps to that decile of the range" do
      state = Scrubber.new(min: 0, max: 100, position: 0)

      assert {%{position: 0}, _} = Scrubber.handle_event(char("0"), state, %{})
      assert {%{position: 50}, _} = Scrubber.handle_event(char("5"), state, %{})
      assert {%{position: 90}, _} = Scrubber.handle_event(char("9"), state, %{})
    end

    test "bracket keys jump between marks, not past the ends" do
      state = Scrubber.new(min: 0, max: 40, position: 12, marks: [0, 18, 33])

      assert {%{position: 18}, _} = Scrubber.handle_event(char("]"), state, %{})
      assert {%{position: 0}, _} = Scrubber.handle_event(char("["), state, %{})

      past_last = %{state | position: 33}
      assert {%{position: 33}, []} = Scrubber.handle_event(char("]"), past_last, %{})
    end

    test "speed walks the ladder and stops at both ends" do
      state = Scrubber.new(min: 0, max: 9)

      assert {%{speed: 2.0}, _} = Scrubber.handle_event(char("+"), state, %{})

      assert {%{speed: 8.0}, _} =
               Scrubber.handle_event(char("+"), %{state | speed: 8.0}, %{})

      assert {%{speed: 0.25}, _} =
               Scrubber.handle_event(char("-"), %{state | speed: 0.25}, %{})
    end

    test "an unbound key changes nothing" do
      state = Scrubber.new(min: 0, max: 9, position: 4)

      assert {^state, []} = Scrubber.handle_event(char("z"), state, %{})
    end

    test "disabled ignores every key" do
      state =
        Scrubber.new(min: 0, max: 9, position: 4, disabled: true, playing?: true)

      assert {^state, []} = Scrubber.handle_event(key(:right), state, %{})
      assert {^state, []} = Scrubber.handle_event(key(:space), state, %{})
    end

    test "focus and blur track focus state" do
      state = Scrubber.new(min: 0, max: 9)

      assert {%{focused: true}, _} =
               Scrubber.handle_event(%Event{type: :focus}, state, %{})

      assert {%{focused: false}, _} =
               Scrubber.handle_event(
                 %Event{type: :blur},
                 %{state | focused: true},
                 %{}
               )
    end
  end

  describe "update/2" do
    test "seek clamps into the range" do
      state = Scrubber.new(min: 0, max: 9, position: 0)

      assert {%{position: 9}, []} = Scrubber.update({:seek, 99}, state)
      assert {%{position: 0}, []} = Scrubber.update({:seek, -1}, state)
    end

    test "play and pause set the transport" do
      state = Scrubber.new(min: 0, max: 9)

      assert {%{playing?: true}, []} = Scrubber.update(:play, state)
      assert {%{playing?: false}, []} = Scrubber.update(:pause, state)
    end

    test "a shrinking range pulls the playhead and marks back in" do
      # A live timeline can shorten (ring wrap, reloaded recording). Leaving
      # the playhead past the new end renders it off the track.
      state = Scrubber.new(min: 0, max: 47, position: 40, marks: [5, 40])

      assert {%{position: 10, marks: [5], max: 10}, []} =
               Scrubber.update(%{max: 10}, state)
    end
  end

  describe "render/2" do
    test "emits a row of identified segments" do
      state = Scrubber.new(id: "replay", min: 0, max: 9, position: 3, label: "Replay")

      row = Scrubber.render(state, %{})

      assert row.type == :row
      ids = Enum.map(row.children, & &1.id)

      assert ids == [
               "replay-label",
               "replay-transport",
               "replay-clock",
               "replay-track"
             ]
    end

    test "drops the speed segment at 1x" do
      state = Scrubber.new(id: "s", min: 0, max: 9)

      refute Enum.any?(Scrubber.render(state, %{}).children, &(&1.id == "s-speed"))

      fast = %{state | speed: 4.0}
      assert Enum.any?(Scrubber.render(fast, %{}).children, &(&1.id == "s-speed"))
    end
  end

  describe "declaration node" do
    test "scrubber/1 stamps the discovery type and carries transport fields" do
      node =
        Raxol.View.Components.scrubber(
          id: "replay",
          min: 0,
          max: 47,
          position: 12,
          marks: [0, 18],
          playing?: true
        )

      assert node.type == :scrubber
      assert node.id == "replay"
      assert node.position == 12
      assert node.max == 47
      assert node.playing? == true
    end

    test "TreeWalker derives namespaced transport tools from the node" do
      node = Raxol.View.Components.scrubber(id: "replay", min: 0, max: 47)

      names =
        node
        |> TreeWalker.derive_tools(%{dispatcher_pid: nil})
        |> Enum.map(& &1.name)

      assert names == [
               "replay.seek",
               "replay.play",
               "replay.pause",
               "replay.get_position"
             ]
    end
  end

  describe "mcp_tools/1 and handle_tool_call/3" do
    test "a disabled scrubber offers no tools" do
      assert Scrubber.mcp_tools(
               Raxol.View.Components.scrubber(id: "s", disabled: true)
             ) == []
    end

    test "seek dispatches the position and rejects one out of range" do
      node =
        Raxol.View.Components.scrubber(id: "replay", min: 0, max: 47, position: 12)

      assert {:ok, _, [{:scrubber_seek, "replay", 20}]} =
               Scrubber.handle_tool_call(
                 "seek",
                 %{"position" => 20},
                 tool_context(node)
               )

      assert {:error, message} =
               Scrubber.handle_tool_call(
                 "seek",
                 %{"position" => 99},
                 tool_context(node)
               )

      assert message =~ "0..47"
    end

    test "seek rejects a non-integer position" do
      node = Raxol.View.Components.scrubber(id: "replay", min: 0, max: 47)

      assert {:error, _} =
               Scrubber.handle_tool_call(
                 "seek",
                 %{"position" => "middle"},
                 tool_context(node)
               )
    end

    test "play and pause dispatch transport messages" do
      node = Raxol.View.Components.scrubber(id: "replay", min: 0, max: 9)

      assert {:ok, _, [{:scrubber_play, "replay"}]} =
               Scrubber.handle_tool_call("play", %{}, tool_context(node))

      assert {:ok, _, [{:scrubber_pause, "replay"}]} =
               Scrubber.handle_tool_call("pause", %{}, tool_context(node))
    end

    test "get_position reads the node without dispatching" do
      node =
        Raxol.View.Components.scrubber(
          id: "replay",
          min: 7,
          max: 11,
          position: 9,
          playing?: true
        )

      assert {:ok, %{position: 9, min: 7, max: 11, playing: true}} =
               Scrubber.handle_tool_call("get_position", %{}, tool_context(node))
    end

    test "an unknown action is an error, not a crash" do
      node = Raxol.View.Components.scrubber(id: "replay")

      assert {:error, message} =
               Scrubber.handle_tool_call("rewind", %{}, tool_context(node))

      assert message =~ "rewind"
    end
  end

  describe "a11y_node/1" do
    test "projects as a slider carrying position and range" do
      node =
        Raxol.View.Components.scrubber(
          id: "replay",
          label: "Replay",
          min: 0,
          max: 47,
          position: 12,
          playing?: true
        )

      assert %{
               role: :slider,
               label: "Replay",
               value: 12,
               state: %{min: 0, max: 47, playing?: true}
             } = Scrubber.a11y_node(node)
    end

    test "a paused transport survives projection" do
      # `playing?: false` is meaningful: dropping it reads as "no transport".
      node = Raxol.View.Components.scrubber(id: "replay", min: 0, max: 9)

      assert %{state: %{playing?: false}} = Projection.project(node)
    end
  end
end
