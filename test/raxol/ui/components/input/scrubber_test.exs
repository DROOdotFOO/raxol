defmodule Raxol.UI.Components.Input.ScrubberTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Accessibility.Projection
  alias Raxol.Core.Events.Event
  alias Raxol.MCP.TreeWalker
  alias Raxol.UI.Components.Input.Scrubber

  # The moduledoc's rendered example drifted six ways from its own props while
  # nothing executed it. It is a doctest now, so it cannot.
  doctest Raxol.UI.Components.Input.Scrubber

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

      assert Scrubber.clock(elapsed_ms: 0, duration_ms: 4_300) ==
               "00:00 / 00:04"
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

      assert {%{position: 33}, []} =
               Scrubber.handle_event(char("]"), past_last, %{})
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
        Scrubber.new(
          min: 0,
          max: 9,
          position: 4,
          disabled: true,
          playing?: true
        )

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
      state =
        Scrubber.new(id: "replay", min: 0, max: 9, position: 3, label: "Replay")

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

      refute Enum.any?(
               Scrubber.render(state, %{}).children,
               &(&1.id == "s-speed")
             )

      fast = %{state | speed: 4.0}

      assert Enum.any?(
               Scrubber.render(fast, %{}).children,
               &(&1.id == "s-speed")
             )
    end

    test "draws every text attribute its style sets" do
      state =
        Scrubber.new(
          id: "s",
          min: 0,
          max: 9,
          label: "Replay",
          style: %{bold: true, dim: true, reverse: true, strikethrough: true}
        )

      cells =
        state
        |> Scrubber.render(%{})
        |> Raxol.UI.Layout.Engine.apply_layout(%{width: 60, height: 1})
        |> Raxol.UI.Renderer.render_to_cells(nil)

      label_cells =
        Enum.filter(cells, fn {x, _y, _char, _fg, _bg, _attrs} -> x < 6 end)

      assert Enum.map_join(label_cells, fn {_x, _y, char, _, _, _} -> char end) ==
               "Replay"

      for {_x, _y, _char, _fg, _bg, attrs} <- label_cells,
          attr <- [:bold, :dim, :reverse, :strikethrough] do
        assert attr in attrs,
               "label cell attrs #{inspect(attrs)} lack #{inspect(attr)}"
      end
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

    test "scrubber/1 is stable across frames when no :id is given" do
      # A view/1 helper runs every frame. Minting an id here produced
      # scrubber-1, scrubber-2, ... so an agent's tool handle
      # ("#{widget_id}.seek") went stale one frame after it was derived and
      # FocusHelper could never match a stable focused_element.
      first = Raxol.View.Components.scrubber(min: 0, max: 47)
      second = Raxol.View.Components.scrubber(min: 0, max: 47)

      assert first.id == second.id
      assert first == second
    end

    test "an unnamed scrubber derives no tools rather than unaddressable ones" do
      # TreeWalker requires a non-empty binary id, so nil is the safe
      # stable value: no handle at all beats a handle that names nothing.
      node = Raxol.View.Components.scrubber(min: 0, max: 47)

      assert node.id == nil
      assert TreeWalker.derive_tools(node, %{dispatcher_pid: nil}) == []
    end
  end

  describe "mcp_tools/1 and handle_tool_call/3" do
    test "a disabled scrubber offers no tools" do
      assert Scrubber.mcp_tools(
               Raxol.View.Components.scrubber(id: "s", disabled: true)
             ) == []
    end

    test "a disabled scrubber also refuses to EXECUTE a transport tool" do
      # Not advertising is not the same as not accepting.
      # TreeWalker.build_tool_def/5 closes over the node at walk time, so an
      # agent holding a def registered before the widget was disabled would
      # otherwise still move an inert transport.
      node = Raxol.View.Components.scrubber(id: "s", disabled: true)
      ctx = %{widget_id: "s", widget_state: node, dispatcher_pid: nil}

      assert {:error, message} =
               Scrubber.handle_tool_call("seek", %{"position" => 3}, ctx)

      assert message =~ "disabled"

      assert {:error, _} = Scrubber.handle_tool_call("play", %{}, ctx)
      assert {:error, _} = Scrubber.handle_tool_call("pause", %{}, ctx)

      # Reading is still allowed: the a11y projection exposes the same fields.
      assert {:ok, %{position: _}} =
               Scrubber.handle_tool_call("get_position", %{}, ctx)
    end

    test "seek dispatches the position and rejects one out of range" do
      node =
        Raxol.View.Components.scrubber(
          id: "replay",
          min: 0,
          max: 47,
          position: 12
        )

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
               Scrubber.handle_tool_call(
                 "get_position",
                 %{},
                 tool_context(node)
               )
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

  describe "the speed ladder reports out" do
    # The widget holds the rate but does not own the timer that reads it, so
    # without a callback `+` moved nothing outside the widget's own render and
    # a parent driving playback could not learn the rate had changed.
    test "stepping up and down runs :on_speed with the new rate" do
      state =
        Scrubber.new(max: 10, speed: 1.0, on_speed: &{:speed_changed, &1})

      assert {%{speed: 2.0}, [{:speed_changed, 2.0}]} =
               Scrubber.handle_event(char("+"), state, %{})

      assert {%{speed: 0.5}, [{:speed_changed, 0.5}]} =
               Scrubber.handle_event(char("-"), state, %{})
    end

    # Silent at the ends, as a clamped seek is at the ends of the track.
    test "no callback when the ladder is already at its end" do
      top = Scrubber.new(max: 10, speed: 8.0, on_speed: &{:speed_changed, &1})

      assert {%{speed: 8.0}, []} = Scrubber.handle_event(char("+"), top, %{})
    end

    # `speed_label/1` matched `1.0 ->` exactly, so integer `1` rendered "1x",
    # while `step_speed/2` twelve lines up compares with `==` and does accept
    # it. Two comparison semantics for one field in one module.
    test "the label is suppressed for integer 1 as well as 1.0" do
      for speed <- [1, 1.0] do
        refute Scrubber.line(Scrubber.new(max: 10, speed: speed)) =~ "1x"
      end

      assert Scrubber.line(Scrubber.new(max: 10, speed: 2)) =~ "2x"
    end
  end

  describe "width boundaries" do
    # `Map.get/3`'s default only fires on an ABSENT key, and in Erlang term
    # order an atom sorts above every number, so `max(3, nil)` was `nil` and
    # the next `nil - 1` raised ArithmeticError.
    test "an explicit nil width falls back to the default" do
      assert %{width: width} = Scrubber.new(max: 10, width: nil)
      assert width == 24
      assert is_binary(Scrubber.line(Scrubber.new(max: 10, width: nil)))
    end

    test "a width under the floor is raised to it rather than crashing" do
      for requested <- [0, 1, 2] do
        assert %{width: 3} = Scrubber.new(max: 10, width: requested)
      end
    end

    test "nil survives a prop merge back onto live state" do
      state = Scrubber.new(max: 10)
      assert {%{width: 3}, _} = Scrubber.update(%{width: 1}, state)
      assert {%{width: 24}, _} = Scrubber.update(%{width: nil}, state)
    end
  end

  describe "digit bindings" do
    # The keymap is read from BOTH `:char` and `:key` for every other binding.
    # The decile jump was read only from `:char`, so on a backend that delivers
    # "5" in `:key` it silently did not exist.
    test "a decile jump arrives on either field" do
      state = Scrubber.new(min: 0, max: 100)

      assert {%{position: 50}, _} =
               Scrubber.handle_event(char("5"), state, %{})

      assert {%{position: 50}, _} = Scrubber.handle_event(key("5"), state, %{})
    end
  end

  describe "measuring without rendering" do
    # `chrome_width/1` and `mark_columns/1` exist so a per-frame caller does not
    # have to render a whole line, and re-sort every mark, just to size a track.
    # They have to agree with what `line/1` actually draws or the sizing is
    # wrong in a way only a narrow terminal would show.
    test "chrome_width/1 is line/1 minus the track it drew" do
      for props <- [
            %{min: 0, max: 47, position: 12, width: 3},
            %{min: 0, max: 47, position: 12, width: 3, speed: 2.0},
            %{min: 0, max: 47, position: 12, width: 3, playing?: true},
            %{
              min: 0,
              max: 47,
              position: 12,
              width: 3,
              elapsed_ms: 1_100,
              duration_ms: 4_300
            }
          ] do
        assert Scrubber.chrome_width(props) ==
                 String.length(Scrubber.line(props)) - props.width,
               "chrome_width disagreed with line/1 for #{inspect(props)}"
      end
    end

    test "a precomputed mark_columns draws the same track" do
      props = %{min: 0, max: 47, position: 12, width: 24, marks: [0, 18, 33]}

      assert Scrubber.track(props) ==
               Scrubber.track(
                 Map.put(props, :mark_columns, Scrubber.mark_columns(props))
               )
    end
  end
end
