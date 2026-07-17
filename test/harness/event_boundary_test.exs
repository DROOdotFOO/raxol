defmodule Raxol.Harness.EventBoundaryTest do
  @moduledoc """
  The security-seam normalization matrix for `Raxol.Harness.EventBoundary`.

  A live agent event (atom-keyed, atom payload keys AND atom payload
  values) crosses a process boundary into this package (which must never
  depend on `raxol_agent`) and must come out shaped exactly like a fixture
  event -- atom top-level fields, STRING-keyed payload with JSON-shaped
  values. Every rule below gets its own named test.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.EventBoundary

  defmodule FakeContractEvent do
    @moduledoc "A minimal atom-keyed struct standing in for a live contract event."
    defstruct id: 0,
              turn_id: nil,
              ts: 0,
              family: :loop,
              type: nil,
              tier: :durable,
              scope: :session,
              provenance: %{source: :primary, trust: :trusted},
              payload: %{},
              extra_field: "must be dropped"
  end

  defmodule ToolUsePayloadValue do
    @moduledoc "A struct that can appear as a nested payload VALUE."
    defstruct name: "read_file", args: %{path: "/tmp/x"}
  end

  defp base_event(overrides \\ %{}) do
    Map.merge(
      %{
        id: 1,
        turn_id: "turn-1",
        ts: 1000,
        family: :loop,
        type: :item_completed,
        tier: :durable,
        scope: :session,
        provenance: %{source: :primary, trust: :trusted},
        payload: %{item_type: :tool_use}
      },
      overrides
    )
  end

  describe "shape: only the allowed keys survive" do
    test "output map carries exactly the nine allowed keys, nothing else" do
      event = base_event(%{unexpected: "nope", another: 123})

      assert {:ok, result} = EventBoundary.normalize(event)

      assert Map.keys(result) |> Enum.sort() ==
               Enum.sort([
                 :id,
                 :turn_id,
                 :ts,
                 :family,
                 :type,
                 :tier,
                 :scope,
                 :provenance,
                 :payload
               ])

      refute Map.has_key?(result, :unexpected)
      refute Map.has_key?(result, :another)
    end

    test "accepts a struct source, reading fields via Map.get (extra struct fields dropped)" do
      event = %FakeContractEvent{
        id: 5,
        turn_id: "t-5",
        ts: 5000,
        family: :loop,
        type: :turn_started,
        tier: :durable,
        scope: :session,
        provenance: %{source: :primary, trust: :trusted},
        payload: %{prompt: "hi"}
      }

      assert {:ok, result} = EventBoundary.normalize(event)
      assert result.id == 5
      assert result.turn_id == "t-5"
      assert result.ts == 5000
      refute Map.has_key?(result, :extra_field)
      refute Map.has_key?(result, :__struct__)
    end
  end

  describe ":id must be a non-negative integer" do
    test "a negative id is rejected" do
      assert {:error, :invalid_event} =
               EventBoundary.normalize(base_event(%{id: -1}))
    end

    test "a non-integer id is rejected" do
      assert {:error, :invalid_event} =
               EventBoundary.normalize(base_event(%{id: "1"}))
    end

    test "zero is accepted (non-negative, not just positive)" do
      assert {:ok, %{id: 0}} = EventBoundary.normalize(base_event(%{id: 0}))
    end
  end

  describe ":ts must be an integer" do
    test "a non-integer ts is rejected" do
      assert {:error, :invalid_event} =
               EventBoundary.normalize(base_event(%{ts: "not a timestamp"}))
    end

    test "a float ts is rejected" do
      assert {:error, :invalid_event} =
               EventBoundary.normalize(base_event(%{ts: 1.5}))
    end
  end

  describe ":payload must be a map" do
    test "a non-map payload is rejected" do
      assert {:error, :invalid_event} =
               EventBoundary.normalize(base_event(%{payload: "not a map"}))
    end

    test "a nil payload is rejected" do
      assert {:error, :invalid_event} =
               EventBoundary.normalize(base_event(%{payload: nil}))
    end
  end

  describe ":tier must be :durable or :ephemeral, never guessed" do
    test "an unrelated atom tier is rejected" do
      assert {:error, :invalid_event} =
               EventBoundary.normalize(base_event(%{tier: :sometimes}))
    end

    test "a string tier is rejected (never coerced)" do
      assert {:error, :invalid_event} =
               EventBoundary.normalize(base_event(%{tier: "durable"}))
    end

    test "a missing tier is rejected" do
      event = base_event() |> Map.delete(:tier)
      assert {:error, :invalid_event} = EventBoundary.normalize(event)
    end

    test ":ephemeral passes through" do
      assert {:ok, %{tier: :ephemeral}} =
               EventBoundary.normalize(base_event(%{tier: :ephemeral}))
    end
  end

  describe ":type and :family pass through unchanged -- never minted into a fixed atom" do
    test "an atom type/family passes through as the same atom" do
      assert {:ok, %{type: :item_completed, family: :loop}} =
               EventBoundary.normalize(base_event())
    end

    test "a non-atom (binary) type/family passes through UNCHANGED, never coerced" do
      event = base_event(%{type: "smuggled_type", family: "smuggled_family"})
      assert {:ok, result} = EventBoundary.normalize(event)
      assert result.type == "smuggled_type"
      assert result.family == "smuggled_family"
    end

    test "a smuggled binary type never mints a new atom" do
      unique = "unheard_of_type_#{System.unique_integer([:positive])}"
      event = base_event(%{type: unique})

      assert {:ok, %{type: ^unique}} = EventBoundary.normalize(event)

      assert_raise ArgumentError, fn -> String.to_existing_atom(unique) end
    end
  end

  describe ":turn_id -- binary or nil passes, anything else is inspected" do
    test "a binary turn_id passes through" do
      assert {:ok, %{turn_id: "turn-42"}} =
               EventBoundary.normalize(base_event(%{turn_id: "turn-42"}))
    end

    test "a nil turn_id passes through as nil" do
      assert {:ok, %{turn_id: nil}} =
               EventBoundary.normalize(base_event(%{turn_id: nil}))
    end

    test "a non-binary, non-nil turn_id (e.g. a tuple) is inspected to a string" do
      assert {:ok, %{turn_id: turn_id}} =
               EventBoundary.normalize(base_event(%{turn_id: {:turn, 7}}))

      assert turn_id == inspect({:turn, 7})
    end
  end

  describe ":scope -- atom passes, else nil" do
    test "an atom scope passes through" do
      assert {:ok, %{scope: :global}} =
               EventBoundary.normalize(base_event(%{scope: :global}))
    end

    test "a non-atom scope becomes nil" do
      assert {:ok, %{scope: nil}} =
               EventBoundary.normalize(base_event(%{scope: "session"}))
    end

    test "a missing scope becomes nil" do
      event = base_event() |> Map.delete(:scope)
      assert {:ok, %{scope: nil}} = EventBoundary.normalize(event)
    end
  end

  describe ":provenance -- taint-absorbing, never laundering" do
    test "trusted source/trust normalizes cleanly" do
      event =
        base_event(%{provenance: %{source: :primary, trust: :trusted}})

      assert {:ok, %{provenance: %{source: "primary", trust: :trusted}}} =
               EventBoundary.normalize(event)
    end

    test "tainted trust passes through as tainted" do
      event = base_event(%{provenance: %{source: "tool", trust: :tainted}})

      assert {:ok, %{provenance: %{source: "tool", trust: :tainted}}} =
               EventBoundary.normalize(event)
    end

    test "any other trust value is absorbed to :tainted, never passed through raw" do
      event = base_event(%{provenance: %{source: :primary, trust: :maybe}})

      assert {:ok, %{provenance: %{trust: :tainted}}} =
               EventBoundary.normalize(event)
    end

    test "a binary source stringifies as-is; a non-atom non-binary source is inspected" do
      event = base_event(%{provenance: %{source: {:weird, 1}, trust: :trusted}})

      assert {:ok, %{provenance: %{source: source}}} =
               EventBoundary.normalize(event)

      assert source == inspect({:weird, 1})
    end

    test "absent provenance yields nil, never a fabricated default" do
      event = base_event() |> Map.delete(:provenance)
      assert {:ok, %{provenance: nil}} = EventBoundary.normalize(event)
    end

    test "nil provenance yields nil" do
      assert {:ok, %{provenance: nil}} =
               EventBoundary.normalize(base_event(%{provenance: nil}))
    end
  end

  describe "payload deep-normalization" do
    test "atom payload keys and atom payload values both become strings" do
      event = base_event(%{payload: %{item_type: :tool_use}})

      assert {:ok, %{payload: %{"item_type" => "tool_use"}}} =
               EventBoundary.normalize(event)
    end

    test "binaries, numbers, booleans, and nil pass through unchanged" do
      event =
        base_event(%{
          payload: %{
            "name" => "read_file",
            "count" => 3,
            "cost" => 1.5,
            "ok?" => true,
            "missing" => nil
          }
        })

      assert {:ok, %{payload: payload}} = EventBoundary.normalize(event)

      assert payload == %{
               "name" => "read_file",
               "count" => 3,
               "cost" => 1.5,
               "ok?" => true,
               "missing" => nil
             }
    end

    test "nested maps and lists recurse" do
      event =
        base_event(%{
          payload: %{
            args: %{path: "/tmp/x", flags: [:recursive, :force]}
          }
        })

      assert {:ok, %{payload: payload}} = EventBoundary.normalize(event)

      assert payload == %{
               "args" => %{
                 "path" => "/tmp/x",
                 "flags" => ["recursive", "force"]
               }
             }
    end

    test "a struct payload value is converted via Map.from_struct then recursed" do
      event = base_event(%{payload: %{tool: %ToolUsePayloadValue{}}})
      assert {:ok, %{payload: payload}} = EventBoundary.normalize(event)

      assert payload == %{
               "tool" => %{
                 "name" => "read_file",
                 "args" => %{"path" => "/tmp/x"}
               }
             }
    end

    test "an improper list is inspected, never crashes" do
      event = base_event(%{payload: %{weird: [1 | 2]}})

      assert {:ok, %{payload: %{"weird" => weird}}} =
               EventBoundary.normalize(event)

      assert weird == inspect([1 | 2])
    end

    test "a tuple value is inspected" do
      event = base_event(%{payload: %{point: {1, 2}}})

      assert {:ok, %{payload: %{"point" => point}}} =
               EventBoundary.normalize(event)

      assert point == inspect({1, 2})
    end

    test "a pid value is inspected" do
      event = base_event(%{payload: %{pid: self()}})

      assert {:ok, %{payload: %{"pid" => pid_str}}} =
               EventBoundary.normalize(event)

      assert pid_str == inspect(self())
    end

    test "a function value is inspected" do
      fun = fn -> :ok end
      event = base_event(%{payload: %{fun: fun}})

      assert {:ok, %{payload: %{"fun" => fun_str}}} =
               EventBoundary.normalize(event)

      assert fun_str == inspect(fun)
    end

    test "never mints a new atom for a smuggled string payload key or value" do
      unique_key = "unheard_of_key_#{System.unique_integer([:positive])}"
      unique_value = "unheard_of_value_#{System.unique_integer([:positive])}"

      event = base_event(%{payload: %{unique_key => unique_value}})
      assert {:ok, %{payload: payload}} = EventBoundary.normalize(event)
      assert Map.get(payload, unique_key) == unique_value

      assert_raise ArgumentError, fn -> String.to_existing_atom(unique_key) end

      assert_raise ArgumentError, fn ->
        String.to_existing_atom(unique_value)
      end
    end

    test "a non-atom, non-binary payload key is inspected" do
      event = base_event(%{payload: %{{:weird, :key} => "value"}})
      assert {:ok, %{payload: payload}} = EventBoundary.normalize(event)
      assert Map.get(payload, inspect({:weird, :key})) == "value"
    end
  end

  describe "top-level acceptance: any map, including atom-keyed structs, is accepted" do
    test "a fully atom-shaped live contract event normalizes to the fixture wire shape" do
      event =
        base_event(%{
          payload: %{
            item_type: :tool_use,
            name: :read_file,
            args: %{path: "/tmp/x"}
          }
        })

      assert {:ok, result} = EventBoundary.normalize(event)

      assert result == %{
               id: 1,
               turn_id: "turn-1",
               ts: 1000,
               family: :loop,
               type: :item_completed,
               tier: :durable,
               scope: :session,
               provenance: %{source: "primary", trust: :trusted},
               payload: %{
                 "item_type" => "tool_use",
                 "name" => "read_file",
                 "args" => %{"path" => "/tmp/x"}
               }
             }
    end
  end

  describe "non-map input" do
    test "a non-map term is rejected" do
      assert {:error, :invalid_event} = EventBoundary.normalize("not a map")
      assert {:error, :invalid_event} = EventBoundary.normalize(nil)
      assert {:error, :invalid_event} = EventBoundary.normalize(42)
    end
  end
end
