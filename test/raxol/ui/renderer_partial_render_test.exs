defmodule Raxol.UI.RendererPartialRenderTest do
  use ExUnit.Case, async: false

  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.ScreenBuffer
  alias Raxol.UI.Rendering.Renderer

  setup do
    # Supervised, linked and :temporary, never start_link plus an on_exit
    # stop (#909, docs/testing/QUICK_REFERENCE.md): on_exit can run while a
    # linked server is still dying, and the stop then exits :noproc or
    # {:shutdown, {:sys, :terminate, _}}.
    start_link_supervised!(Renderer, restart: :temporary)
    Renderer.set_test_pid(self())

    :ok
  end

  test "partial render updates buffer for label text change" do
    # Initial tree: a view with one label
    tree = %{type: :view, children: [%{type: :label, attrs: %{text: "Hello"}}]}
    Renderer.render(tree)
    # Wait for the render to complete
    assert_receive {:renderer_rendered, ops}, 1000
    assert ops == [{:draw_text, 0, "Hello"}]

    # Apply a partial diff: update label text to "World"
    _diff = {:update, [0], :replace, %{type: :label, attrs: %{text: "World"}}}
    # The pipeline expects {:update, path, changes}, so simulate a minimal diff
    # For our renderer, changes is a list of {idx, diff} for children
    diff =
      {:update, [], [{0, {:replace, %{type: :label, attrs: %{text: "World"}}}}]}

    new_tree = %{
      type: :view,
      children: [%{type: :label, attrs: %{text: "World"}}]
    }

    Renderer.apply_diff(diff, new_tree)
    # Wait for the partial update
    assert_receive {:renderer_partial_update, [], updated_subtree,
                    _updated_tree},
                   1000

    assert updated_subtree == %{
             type: :view,
             children: [%{type: :label, attrs: %{text: "World"}}]
           }

    # Fetch the emulator from the Renderer state
    state = :sys.get_state(Renderer)
    emulator = Map.fetch!(state, :emulator)
    buffer = Emulator.get_screen_buffer(emulator)
    content = ScreenBuffer.get_content(buffer)
    # The label is rendered at y=0, x=0, so should be on the first line
    assert String.starts_with?(content, "World")
  end

  test "partial render updates buffer for multiple labels on different lines" do
    tree = %{
      type: :view,
      children: [
        %{type: :label, attrs: %{text: "First"}},
        %{type: :label, attrs: %{text: "Second"}}
      ]
    }

    Renderer.render(tree)
    assert_receive {:renderer_rendered, ops}, 1000

    assert ops == [
             {:draw_text, 0, "First"},
             {:draw_text, 1, "Second"}
           ]

    # Update the second label
    diff =
      {:update, [],
       [
         {1, {:replace, %{type: :label, attrs: %{text: "Changed!"}}}}
       ]}

    new_tree = %{
      type: :view,
      children: [
        %{type: :label, attrs: %{text: "First"}},
        %{type: :label, attrs: %{text: "Changed!"}}
      ]
    }

    Renderer.apply_diff(diff, new_tree)
    assert_receive {:renderer_partial_update, [], updated_subtree, _}, 1000

    assert updated_subtree == %{
             type: :view,
             children: [
               %{type: :label, attrs: %{text: "First"}},
               %{type: :label, attrs: %{text: "Changed!"}}
             ]
           }

    state = :sys.get_state(Renderer)
    emulator = Map.fetch!(state, :emulator)
    buffer = Emulator.get_screen_buffer(emulator)
    content = ScreenBuffer.get_content(buffer)
    [line1, line2 | _] = String.split(content, "\n")
    assert line1 =~ "First"
    assert line2 =~ "Changed!"
  end

  test "partial render updates buffer for nested label" do
    tree = %{
      type: :view,
      children: [
        %{
          type: :view,
          children: [
            %{type: :label, attrs: %{text: "Deep"}}
          ]
        }
      ]
    }

    Renderer.render(tree)
    assert_receive {:renderer_rendered, ops}, 1000

    assert ops == [
             {:draw_text, 0, "Deep"}
           ]

    # Update the nested label
    diff =
      {:update, [],
       [
         {0,
          {:update, [],
           [
             {0, {:replace, %{type: :label, attrs: %{text: "Deeper!"}}}}
           ]}}
       ]}

    new_tree = %{
      type: :view,
      children: [
        %{
          type: :view,
          children: [
            %{type: :label, attrs: %{text: "Deeper!"}}
          ]
        }
      ]
    }

    Renderer.apply_diff(diff, new_tree)
    assert_receive {:renderer_partial_update, [], updated_subtree, _}, 1000

    assert updated_subtree == %{
             type: :view,
             children: [
               %{
                 type: :view,
                 children: [
                   %{type: :label, attrs: %{text: "Deeper!"}}
                 ]
               }
             ]
           }

    state = :sys.get_state(Renderer)
    emulator = Map.fetch!(state, :emulator)
    buffer = Emulator.get_screen_buffer(emulator)
    content = ScreenBuffer.get_content(buffer)
    [line1 | _] = String.split(content, "\n")
    assert line1 =~ "Deeper!"
  end

  test "partial render updates buffer for multiple labels, non-zero index" do
    tree = %{
      type: :view,
      children: [
        %{type: :label, attrs: %{text: "A"}},
        %{type: :label, attrs: %{text: "B"}},
        %{type: :label, attrs: %{text: "C"}}
      ]
    }

    Renderer.render(tree)
    assert_receive {:renderer_rendered, ops}, 1000

    assert ops == [
             {:draw_text, 0, "A"},
             {:draw_text, 1, "B"},
             {:draw_text, 2, "C"}
           ]

    # Update the first and third label
    diff =
      {:update, [],
       [
         {0, {:replace, %{type: :label, attrs: %{text: "X"}}}},
         {2, {:replace, %{type: :label, attrs: %{text: "Z"}}}}
       ]}

    new_tree = %{
      type: :view,
      children: [
        %{type: :label, attrs: %{text: "X"}},
        %{type: :label, attrs: %{text: "B"}},
        %{type: :label, attrs: %{text: "Z"}}
      ]
    }

    Renderer.apply_diff(diff, new_tree)
    assert_receive {:renderer_partial_update, [], updated_subtree, _}, 1000

    assert updated_subtree == %{
             type: :view,
             children: [
               %{type: :label, attrs: %{text: "X"}},
               %{type: :label, attrs: %{text: "B"}},
               %{type: :label, attrs: %{text: "Z"}}
             ]
           }

    state = :sys.get_state(Renderer)
    emulator = Map.fetch!(state, :emulator)
    buffer = Emulator.get_screen_buffer(emulator)
    content = ScreenBuffer.get_content(buffer)
    [line1, line2, line3 | _] = String.split(content, "\n")
    assert line1 =~ "X"
    assert line2 =~ "B"
    assert line3 =~ "Z"
  end

  test "partial render updates buffer for deeply nested label" do
    tree = %{
      type: :view,
      children: [
        %{
          type: :view,
          children: [
            %{
              type: :view,
              children: [
                %{type: :label, attrs: %{text: "Deepest"}}
              ]
            }
          ]
        }
      ]
    }

    Renderer.render(tree)
    assert_receive {:renderer_rendered, ops}, 1000

    assert ops == [
             {:draw_text, 0, "Deepest"}
           ]

    # Update the deepest label
    diff =
      {:update, [],
       [
         {0,
          {:update, [],
           [
             {0,
              {:update, [],
               [
                 {0,
                  {:replace, %{type: :label, attrs: %{text: "Changed Deep!"}}}}
               ]}}
           ]}}
       ]}

    new_tree = %{
      type: :view,
      children: [
        %{
          type: :view,
          children: [
            %{
              type: :view,
              children: [
                %{type: :label, attrs: %{text: "Changed Deep!"}}
              ]
            }
          ]
        }
      ]
    }

    Renderer.apply_diff(diff, new_tree)
    assert_receive {:renderer_partial_update, [], updated_subtree, _}, 1000
    assert updated_subtree == new_tree

    state = :sys.get_state(Renderer)
    emulator = Map.fetch!(state, :emulator)
    buffer = Emulator.get_screen_buffer(emulator)
    content = ScreenBuffer.get_content(buffer)
    [line1 | _] = String.split(content, "\n")
    assert line1 =~ "Changed Deep!"
  end

  test "partial render updates buffer for sibling views with multiple children" do
    tree = %{
      type: :view,
      children: [
        %{
          type: :view,
          children: [
            %{type: :label, attrs: %{text: "A1"}},
            %{type: :label, attrs: %{text: "A2"}}
          ]
        },
        %{
          type: :view,
          children: [
            %{type: :label, attrs: %{text: "B1"}},
            %{type: :label, attrs: %{text: "B2"}}
          ]
        }
      ]
    }

    Renderer.render(tree)
    assert_receive {:renderer_rendered, ops}, 1000

    assert ops == [
             {:draw_text, 0, "A1"},
             {:draw_text, 1, "A2"},
             {:draw_text, 2, "B1"},
             {:draw_text, 3, "B2"}
           ]

    # Update B2
    diff =
      {:update, [],
       [
         {1,
          {:update, [],
           [
             {1, {:replace, %{type: :label, attrs: %{text: "B2 changed"}}}}
           ]}}
       ]}

    new_tree = %{
      type: :view,
      children: [
        %{
          type: :view,
          children: [
            %{type: :label, attrs: %{text: "A1"}},
            %{type: :label, attrs: %{text: "A2"}}
          ]
        },
        %{
          type: :view,
          children: [
            %{type: :label, attrs: %{text: "B1"}},
            %{type: :label, attrs: %{text: "B2 changed"}}
          ]
        }
      ]
    }

    Renderer.apply_diff(diff, new_tree)
    assert_receive {:renderer_partial_update, [], updated_subtree, _}, 1000
    assert updated_subtree == new_tree

    state = :sys.get_state(Renderer)
    emulator = Map.fetch!(state, :emulator)
    buffer = Emulator.get_screen_buffer(emulator)
    content = ScreenBuffer.get_content(buffer)
    lines = String.split(content, "\n")
    assert Enum.any?(lines, &(&1 =~ "B2 changed"))
  end

  test "partial render ignores unknown node types and only renders labels" do
    tree = %{
      type: :view,
      children: [
        %{type: :label, attrs: %{text: "Visible"}},
        %{type: :unknown, attrs: %{foo: "bar"}},
        %{
          type: :view,
          children: [
            %{type: :label, attrs: %{text: "Also visible"}},
            %{type: :unknown2, attrs: %{baz: 123}}
          ]
        }
      ]
    }

    Renderer.render(tree)
    assert_receive {:renderer_rendered, ops}, 1000

    assert ops == [
             {:draw_text, 0, "Visible"},
             {:draw_text, 1, "Also visible"}
           ]

    state = :sys.get_state(Renderer)
    emulator = Map.fetch!(state, :emulator)
    buffer = Emulator.get_screen_buffer(emulator)
    content = ScreenBuffer.get_content(buffer)
    assert content =~ "Visible"
    assert content =~ "Also visible"
    refute content =~ "bar"
    refute content =~ "123"
  end

  test "partial render updates buffer for wide tree with many labels" do
    labels =
      Enum.map(1..12, fn i -> %{type: :label, attrs: %{text: "L#{i}"}} end)

    tree = %{type: :view, children: labels}
    Renderer.render(tree)
    assert_receive {:renderer_rendered, ops}, 1000

    assert ops ==
             Enum.with_index(labels)
             |> Enum.map(fn {label, idx} ->
               {:draw_text, idx, label.attrs.text}
             end)

    # Update several labels at once
    diff =
      {:update, [],
       [
         {0, {:replace, %{type: :label, attrs: %{text: "L1!"}}}},
         {5, {:replace, %{type: :label, attrs: %{text: "L6!"}}}},
         {11, {:replace, %{type: :label, attrs: %{text: "L12!"}}}}
       ]}

    new_labels =
      Enum.with_index(labels, 0)
      |> Enum.map(fn
        {_, 0} -> %{type: :label, attrs: %{text: "L1!"}}
        {_, 5} -> %{type: :label, attrs: %{text: "L6!"}}
        {_, 11} -> %{type: :label, attrs: %{text: "L12!"}}
        {label, _} -> label
      end)

    new_tree = %{type: :view, children: new_labels}
    Renderer.apply_diff(diff, new_tree)
    assert_receive {:renderer_partial_update, [], updated_subtree, _}, 1000
    assert updated_subtree == new_tree

    state = :sys.get_state(Renderer)
    emulator = Map.fetch!(state, :emulator)
    buffer = Emulator.get_screen_buffer(emulator)
    content = ScreenBuffer.get_content(buffer)
    lines = String.split(content, "\n")
    assert Enum.at(lines, 0) =~ "L1!"
    assert Enum.at(lines, 5) =~ "L6!"
    assert Enum.at(lines, 11) =~ "L12!"
  end

  test "partial render updates buffer for multiple updates in one diff" do
    tree = %{
      type: :view,
      children: [
        %{type: :label, attrs: %{text: "A"}},
        %{type: :label, attrs: %{text: "B"}},
        %{type: :label, attrs: %{text: "C"}},
        %{type: :label, attrs: %{text: "D"}}
      ]
    }

    Renderer.render(tree)
    assert_receive {:renderer_rendered, ops}, 1000

    assert ops == [
             {:draw_text, 0, "A"},
             {:draw_text, 1, "B"},
             {:draw_text, 2, "C"},
             {:draw_text, 3, "D"}
           ]

    # Update B and D
    diff =
      {:update, [],
       [
         {1, {:replace, %{type: :label, attrs: %{text: "B!"}}}},
         {3, {:replace, %{type: :label, attrs: %{text: "D!"}}}}
       ]}

    new_tree = %{
      type: :view,
      children: [
        %{type: :label, attrs: %{text: "A"}},
        %{type: :label, attrs: %{text: "B!"}},
        %{type: :label, attrs: %{text: "C"}},
        %{type: :label, attrs: %{text: "D!"}}
      ]
    }

    Renderer.apply_diff(diff, new_tree)
    assert_receive {:renderer_partial_update, [], updated_subtree, _}, 1000
    assert updated_subtree == new_tree

    state = :sys.get_state(Renderer)
    emulator = Map.fetch!(state, :emulator)
    buffer = Emulator.get_screen_buffer(emulator)
    content = ScreenBuffer.get_content(buffer)
    lines = String.split(content, "\n")
    assert Enum.at(lines, 1) =~ "B!"
    assert Enum.at(lines, 3) =~ "D!"
  end
end
