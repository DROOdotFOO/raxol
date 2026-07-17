defmodule Raxol.Harness.PanelProjectionTest do
  @moduledoc """
  Red-first acceptance tests for `Raxol.Harness.PanelProjection` (phase 1
  of the projection-panels build). Anchors on the tolerant-reading rule
  (unknown class/op/type/fields are skipped, never an error), the
  hostile-content clamp, the no-atom-creation guarantee, and the
  contract-shape fixture `test/fixtures/harness/sessions/projection-panels.jsonl`.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Fixture
  alias Raxol.Harness.Fixture.Session
  alias Raxol.Harness.PanelProjection

  @fixture_path "test/fixtures/harness/sessions/projection-panels.jsonl"

  defp extract_event(class, op, item, opts \\ []) do
    payload =
      Keyword.get_lazy(opts, :payload, fn ->
        %{"class" => class, "op" => op, "item" => item, "refs" => []}
      end)

    %{
      id: Keyword.get(opts, :id, 1),
      turn_id: nil,
      family: Keyword.get(opts, :family, :meta),
      type: Keyword.get(opts, :type, :extract),
      tier: :durable,
      scope: :session,
      payload: payload
    }
  end

  defp loop_event(type, payload, id) do
    %{
      id: id,
      turn_id: "t1",
      family: :loop,
      type: type,
      tier: :durable,
      payload: payload
    }
  end

  describe "kinds/0" do
    test "returns worktracks, memory, plan" do
      assert PanelProjection.kinds() == [:worktracks, :memory, :plan]
    end
  end

  describe "worktracks fold" do
    test "add/update/remove shapes fold with first-seen lane ordering" do
      events = [
        extract_event("worktracks", "add", %{
          "id" => "wt-1",
          "lane" => "todo",
          "title" => "Design schema",
          "status" => "open"
        }),
        extract_event("worktracks", "add", %{
          "id" => "wt-2",
          "lane" => "doing",
          "title" => "Wire panel",
          "status" => "in_progress"
        }),
        extract_event("worktracks", "update", %{
          "id" => "wt-1",
          "status" => "done"
        }),
        extract_event("worktracks", "add", %{
          "id" => "wt-3",
          "lane" => "todo",
          "title" => "Write tests",
          "status" => "open"
        })
      ]

      assert PanelProjection.fold(:worktracks, events) == [
               %{
                 name: "todo",
                 items: [
                   %{title: "Design schema", status: "done"},
                   %{title: "Write tests", status: "open"}
                 ]
               },
               %{
                 name: "doing",
                 items: [%{title: "Wire panel", status: "in_progress"}]
               }
             ]
    end

    test "remove drops the identity and, if it was the sole occupant, its lane" do
      events = [
        extract_event("worktracks", "add", %{
          "id" => "wt-1",
          "lane" => "todo",
          "title" => "Design schema",
          "status" => "open"
        }),
        extract_event("worktracks", "remove", %{"id" => "wt-1"})
      ]

      assert PanelProjection.fold(:worktracks, events) == []
    end

    test "update against an unknown identity is skipped" do
      events = [
        extract_event("worktracks", "update", %{
          "id" => "missing",
          "status" => "done"
        })
      ]

      assert PanelProjection.fold(:worktracks, events) == []
    end

    test "title falls back to identity, status falls back to empty string" do
      events = [
        extract_event("worktracks", "add", %{"id" => "wt-1", "lane" => "todo"})
      ]

      assert PanelProjection.fold(:worktracks, events) == [
               %{name: "todo", items: [%{title: "wt-1", status: ""}]}
             ]
    end

    test "lane falls back to status, then to \"todo\"" do
      events = [
        extract_event("worktracks", "add", %{
          "id" => "wt-1",
          "status" => "blocked"
        }),
        extract_event("worktracks", "add", %{"id" => "wt-2"})
      ]

      assert PanelProjection.fold(:worktracks, events) == [
               %{name: "blocked", items: [%{title: "wt-1", status: "blocked"}]},
               %{name: "todo", items: [%{title: "wt-2", status: ""}]}
             ]
    end
  end

  describe "memory fold" do
    test "add/update shapes fold in first-seen order" do
      events = [
        extract_event("memory", "add", %{"key" => "topic", "value" => "harness"}),
        extract_event("memory", "add", %{"key" => "mode", "value" => "build"}),
        extract_event("memory", "update", %{
          "key" => "topic",
          "value" => "harness ui"
        })
      ]

      assert PanelProjection.fold(:memory, events) == [
               %{key: "topic", value: "harness ui"},
               %{key: "mode", value: "build"}
             ]
    end

    test "remove drops the key" do
      events = [
        extract_event("memory", "add", %{"key" => "topic", "value" => "harness"}),
        extract_event("memory", "remove", %{"key" => "topic"})
      ]

      assert PanelProjection.fold(:memory, events) == []
    end
  end

  describe "plan fold" do
    test "add/update shapes fold in first-seen 1-based order" do
      events = [
        extract_event("plan", "add", %{
          "id" => "step-1",
          "title" => "Draft",
          "status" => "todo"
        }),
        extract_event("plan", "add", %{
          "id" => "step-2",
          "title" => "Ship",
          "status" => "todo"
        }),
        extract_event("plan", "update", %{"id" => "step-1", "status" => "done"})
      ]

      assert PanelProjection.fold(:plan, events) == [
               %{title: "Draft", status: "done"},
               %{title: "Ship", status: "todo"}
             ]
    end
  end

  describe "dual payload-key convention" do
    test "string-keyed and atom-keyed payloads fold identically" do
      string_event =
        extract_event(nil, nil, nil,
          payload: %{
            "class" => "worktracks",
            "op" => "add",
            "item" => %{
              "id" => "wt-1",
              "lane" => "todo",
              "title" => "T",
              "status" => "S"
            },
            "refs" => []
          }
        )

      atom_event =
        extract_event(nil, nil, nil,
          payload: %{
            class: :worktracks,
            op: :add,
            item: %{id: "wt-1", lane: "todo", title: "T", status: "S"},
            refs: []
          }
        )

      assert PanelProjection.fold(:worktracks, [string_event]) ==
               PanelProjection.fold(:worktracks, [atom_event])
    end
  end

  describe "tolerant-reading skip rules" do
    test "unknown class is skipped, never an error" do
      events = [
        extract_event("scratchpad", "add", %{"id" => "x", "title" => "y"})
      ]

      assert PanelProjection.fold(:worktracks, events) == []
      assert PanelProjection.fold(:memory, events) == []
      assert PanelProjection.fold(:plan, events) == []
    end

    test "unknown op is skipped, never an error" do
      events = [
        extract_event("worktracks", "annotate", %{
          "id" => "wt-1",
          "lane" => "todo",
          "title" => "T"
        })
      ]

      assert PanelProjection.fold(:worktracks, events) == []
    end

    test "non-map item is skipped" do
      events = [extract_event("worktracks", "add", "not-a-map")]
      assert PanelProjection.fold(:worktracks, events) == []
    end

    test "missing identity field is skipped" do
      # memory's only identity key is "key" -- absent here, with no fallback.
      events = [extract_event("memory", "add", %{"value" => "no key at all"})]
      assert PanelProjection.fold(:memory, events) == []
    end

    test "loop-family events never contribute" do
      events = [loop_event(:item_completed, %{"item_id" => "i1"}, 1)]
      assert PanelProjection.fold(:worktracks, events) == []
    end

    test "non-extract meta events never contribute" do
      events = [
        extract_event("worktracks", "add", %{"id" => "wt-1", "title" => "T"},
          type: :gate_decision
        )
      ]

      assert PanelProjection.fold(:worktracks, events) == []
    end
  end

  describe "hostile-content discipline" do
    test "binary fields are clamped to 512 bytes" do
      long_value = String.duplicate("x", 900)

      events = [
        extract_event("memory", "add", %{"key" => "k", "value" => long_value})
      ]

      [%{value: value}] = PanelProjection.fold(:memory, events)
      assert byte_size(value) <= 512
    end

    test "binary fields are byte-bounded even when the clamp splits a codepoint (M1)" do
      # 400 x "→" = 1200 bytes. @max_field_bytes (512) is not divisible by 3,
      # so `binary_part(v, 0, 512)` lands mid-codepoint -> invalid UTF-8 ->
      # the fallback path. The old `String.slice(v, 0, 512)` fallback was a
      # *grapheme* clamp: 400 graphemes <= 512, so it returned all 1200 bytes
      # unclamped. This asserts the fallback actually bounds bytes.
      long_value = String.duplicate("→", 400)
      assert byte_size(long_value) == 1200

      events = [
        extract_event("memory", "add", %{"key" => "k", "value" => long_value})
      ]

      [%{value: value}] = PanelProjection.fold(:memory, events)
      assert byte_size(value) <= 512
      assert String.valid?(value), "the clamp must never emit invalid UTF-8"
    end

    test "render_lines output contains no raw newline or carriage return" do
      events = [
        extract_event("worktracks", "add", %{
          "id" => "wt-1",
          "lane" => "todo",
          "title" => "evil\ntitle\r\nhere",
          "status" => "open"
        })
      ]

      lines = PanelProjection.render_lines(:worktracks, events)
      refute Enum.any?(lines, &String.contains?(&1, "\n"))
      refute Enum.any?(lines, &String.contains?(&1, "\r"))
    end

    test "control bytes pass through untouched (sanitization is downstream's job)" do
      hostile = "[2Jevil"

      events = [
        extract_event("memory", "add", %{"key" => "k", "value" => hostile})
      ]

      [%{value: value}] = PanelProjection.fold(:memory, events)
      assert value == hostile
      assert String.starts_with?(value, "\e")
    end
  end

  describe "no atom creation" do
    test "fold never creates atoms from an untrusted class value" do
      unique = "unforeseen-class-#{System.unique_integer([:positive])}"
      events = [extract_event(unique, "add", %{"id" => "x", "title" => "y"})]

      assert PanelProjection.fold(:worktracks, events) == []
      assert_raise ArgumentError, fn -> String.to_existing_atom(unique) end
    end
  end

  describe "flood clamp" do
    test "501 distinct adds keep 500, oldest dropped" do
      events =
        for i <- 1..501 do
          extract_event(
            "memory",
            "add",
            %{"key" => "k#{i}", "value" => "v#{i}"},
            id: i
          )
        end

      result = PanelProjection.fold(:memory, events)
      assert length(result) == 500
      refute Enum.any?(result, &(&1.key == "k1"))
      assert Enum.any?(result, &(&1.key == "k2"))
      assert Enum.any?(result, &(&1.key == "k501"))
    end
  end

  describe "determinism" do
    test "same input twice yields an identical read-model" do
      events = [
        extract_event("plan", "add", %{
          "id" => "step-1",
          "title" => "Draft",
          "status" => "todo"
        })
      ]

      assert PanelProjection.fold(:plan, events) ==
               PanelProjection.fold(:plan, events)
    end
  end

  describe "fixture integration" do
    test "projection-panels.jsonl loads without decode errors" do
      assert {:ok, %Session{}} = Fixture.load(@fixture_path)
    end

    test "folding the fixture's decoded envelopes yields the expected read-models" do
      {:ok, %Session{envelopes: envelopes}} = Fixture.load(@fixture_path)
      bodies = Enum.map(envelopes, & &1.body)

      assert PanelProjection.fold(:worktracks, bodies) == [
               %{
                 name: "todo",
                 items: [%{title: "Design schema", status: "done"}]
               },
               %{
                 name: "security",
                 # ESC form (C0) + U+009B (8-bit C1 CSI) -- fold/2 passes both
                 # through raw; sanitizing control bytes is ViewText's job,
                 # downstream. See the C1 wire test in
                 # projection_panels_surface_test.exs.
                 items: [
                   %{
                     title: "\e[2Jevil\ntitle" <> <<0x9B::utf8>> <> "3Gc1",
                     status: "flagged"
                   }
                 ]
               }
             ]

      assert PanelProjection.fold(:memory, bodies) == [
               %{key: "topic", value: "harness ui projection panels"},
               %{key: "mode", value: "build"}
             ]

      assert PanelProjection.fold(:plan, bodies) == [
               %{title: "Draft read-model", status: "done"},
               %{title: "Draft overlay panel", status: "todo"},
               %{title: "Write fixture", status: "todo"}
             ]
    end
  end
end
