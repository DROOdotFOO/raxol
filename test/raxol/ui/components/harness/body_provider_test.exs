defmodule Raxol.UI.Components.Harness.BodyProviderTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.{
    ApprovalPrompt,
    Block,
    BodyProvider,
    DiffViewer,
    MessageBlock,
    ReasoningBlock,
    ToolCallBlock
  }

  defp default_context,
    do: %{theme: Raxol.UI.Theming.Theme.default_theme(), width: 80}

  defp flat_texts(%{type: :text, content: content}), do: [content]

  defp flat_texts(%{children: children}) when is_list(children),
    do: Enum.flat_map(children, &flat_texts/1)

  defp flat_texts(_node), do: []

  # -- realistic per-kind fixtures, built through the REAL Block.from_events
  # (methodology R9: cross-boundary tests drive real producers, never
  # synthetic hand-built maps) --

  defp fixture_block(:message) do
    Block.from_events(
      :message,
      [
        %{
          id: 1,
          type: :item_completed,
          payload: %{item_type: :message, content: "Deploy is done."}
        }
      ],
      fold: :expanded
    )
  end

  defp fixture_block(:reasoning) do
    Block.from_events(
      :reasoning,
      [
        %{
          id: 1,
          type: :item_completed,
          payload: %{
            item_type: :reasoning,
            content: "Considering the rollback plan."
          }
        }
      ],
      fold: :expanded
    )
  end

  defp fixture_block(:tool_call) do
    Block.from_events(
      :tool_call,
      [
        %{
          id: 1,
          type: :item_completed,
          payload: %{
            item_type: :tool_use,
            content: %{name: "Bash", args: %{command: "ls -la"}}
          }
        },
        %{
          id: 2,
          type: :item_completed,
          payload: %{item_type: :tool_result, content: "total 0\ndrwxr-xr-x"},
          provenance: %{trust: :tainted}
        }
      ],
      fold: :expanded
    )
  end

  defp fixture_block(:diff) do
    Block.from_events(
      :diff,
      [
        %{
          id: 1,
          type: :item_completed,
          payload: %{
            path: "lib/orders/total.ex",
            old: "def total(x), do: x\n",
            new: "def total(x), do: x * 2\n"
          }
        }
      ],
      fold: :expanded
    )
  end

  defp fixture_block(:approval) do
    Block.from_events(
      :approval,
      [
        %{
          id: 1,
          type: :approval_requested,
          payload: %{
            action: "rm -rf build/",
            blast_radius: %{
              writes: [],
              deletes: ["build/"],
              commands: [],
              network: [],
              reversible: false
            },
            options: [
              %{
                key: :allow_once,
                label: "Allow once",
                decision: :allow,
                scope: :once
              },
              %{key: :deny, label: "Deny", decision: :deny, scope: :once}
            ]
          }
        }
      ],
      fold: :expanded
    )
  end

  defp valid_body(kind), do: fixture_block(kind).content

  describe "known_kinds/0 + required_keys/1 -- the schema surface" do
    test "matches Block's five known kinds exactly (excludes :opaque)" do
      assert Enum.sort(BodyProvider.known_kinds()) ==
               Enum.sort(Block.known_kinds())
    end

    test "every known kind has at least one required key" do
      for kind <- BodyProvider.known_kinds() do
        assert BodyProvider.required_keys(kind) != [],
               "#{kind} has no required keys -- schema is vacuous"
      end
    end

    test ":opaque and other unknown kinds have no schema" do
      assert BodyProvider.required_keys(:opaque) == []
      assert BodyProvider.required_keys(:something_undreamed_of) == []
    end
  end

  describe "validate/2 -- per-kind schema contract (property over kinds)" do
    test "a real, fully-populated body for every kind passes validation" do
      for kind <- BodyProvider.known_kinds() do
        assert BodyProvider.validate(kind, valid_body(kind)) == :ok,
               "#{kind}'s own real content failed its own schema"
      end
    end

    test "deleting any single required key is rejected, naming exactly that key" do
      for kind <- BodyProvider.known_kinds(),
          key <- BodyProvider.required_keys(kind) do
        broken = Map.delete(valid_body(kind), key)

        assert {:error, message} = BodyProvider.validate(kind, broken),
               "#{kind} body missing #{inspect(key)} was NOT rejected"

        assert message =~ inspect(key),
               "error for #{kind}/#{inspect(key)} didn't name the missing key: #{message}"

        assert message =~ inspect(kind)
      end
    end

    test "a non-map body is rejected instead of raising on Map.keys/1" do
      assert {:error, message} = BodyProvider.validate(:message, "not a map")
      assert message =~ "must be a map"
    end

    test ":opaque has nothing to validate -- always :ok" do
      assert BodyProvider.validate(:opaque, %{}) == :ok
      assert BodyProvider.validate(:opaque, %{anything: "goes"}) == :ok
    end
  end

  describe "component_for/1 -- kind to merged-component mapping" do
    test "each known kind names its real merged component" do
      assert BodyProvider.component_for(:message) == {:ok, MessageBlock}
      assert BodyProvider.component_for(:reasoning) == {:ok, ReasoningBlock}
      assert BodyProvider.component_for(:tool_call) == {:ok, ToolCallBlock}
      assert BodyProvider.component_for(:diff) == {:ok, DiffViewer}
      assert BodyProvider.component_for(:approval) == {:ok, ApprovalPrompt}
    end

    test ":opaque and unknown kinds have no component" do
      assert {:error, _reason} = BodyProvider.component_for(:opaque)
      assert {:error, _reason} = BodyProvider.component_for(:not_a_real_kind)
    end
  end

  describe "mount/3 -- fail-first guards (RED-proving misuse)" do
    test "a schema-violating body refuses to mount, naming the missing key" do
      broken = Map.delete(valid_body(:diff), :new)

      assert {:error, message} =
               BodyProvider.mount(:diff, broken, context: default_context())

      assert message =~ ":new"
    end

    test "mounting through an explicitly wrong component refuses instead of silently rendering" do
      assert {:error, message} =
               BodyProvider.mount(:diff, valid_body(:diff),
                 component: ApprovalPrompt,
                 context: default_context()
               )

      assert message =~ "ApprovalPrompt"
      assert message =~ "DiffViewer"
    end

    test "an unknown/:opaque kind refuses to mount (no component to refuse INTO, just refuses)" do
      assert {:error, _reason} =
               BodyProvider.mount(:opaque, %{text: "x"},
                 context: default_context()
               )
    end
  end

  describe "mount/3 -- real end-to-end per kind (drives the REAL merged component)" do
    test ":message mounts MessageBlock and shows the role prefix + content" do
      block = fixture_block(:message)

      assert {:ok, view} =
               BodyProvider.mount(block.kind, block.content,
                 context: default_context()
               )

      texts = flat_texts(view)
      assert Enum.any?(texts, &(&1 == "[assistant]"))
      assert Enum.any?(texts, &(&1 =~ "Deploy is done."))
    end

    test ":reasoning mounts ReasoningBlock expanded, showing the full content" do
      block = fixture_block(:reasoning)

      assert {:ok, view} =
               BodyProvider.mount(block.kind, block.content,
                 context: default_context()
               )

      texts = flat_texts(view)
      assert Enum.any?(texts, &(&1 == "Considering the rollback plan."))
    end

    test ":tool_call composes ToolCallBlock + ToolResultBlock (with taint badge) when a result is present" do
      block = fixture_block(:tool_call)

      assert {:ok, view} =
               BodyProvider.mount(block.kind, block.content,
                 context: default_context(),
                 outcome: block.outcome
               )

      texts = flat_texts(view)
      assert Enum.any?(texts, &(&1 == "Bash"))
      assert Enum.any?(texts, &(&1 =~ "command: \"ls -la\""))
      assert Enum.any?(texts, &(&1 =~ "total 0"))
      assert Enum.any?(texts, &(&1 == "⚠ untrusted"))
    end

    test ":tool_call mounts ToolCallBlock ALONE when no result has landed yet (still pending)" do
      pending_block =
        Block.from_events(
          :tool_call,
          [
            %{
              id: 1,
              type: :item_started,
              payload: %{item_type: :tool_use}
            },
            %{
              id: 2,
              type: :item_completed,
              payload: %{
                item_type: :tool_use,
                content: %{name: "Grep", args: %{}}
              }
            }
          ],
          fold: :expanded
        )

      assert {:ok, view} =
               BodyProvider.mount(pending_block.kind, pending_block.content,
                 context: default_context(),
                 outcome: pending_block.outcome
               )

      texts = flat_texts(view)
      assert Enum.any?(texts, &(&1 == "Grep"))
      refute Enum.any?(texts, &(&1 == "⚠ untrusted"))
    end

    test ":diff mounts DiffViewer, showing the path chrome and the proposed-change framing" do
      block = fixture_block(:diff)

      assert {:ok, view} =
               BodyProvider.mount(block.kind, block.content,
                 context: default_context()
               )

      texts = flat_texts(view)
      assert Enum.any?(texts, &(&1 == "lib/orders/total.ex"))
      assert Enum.any?(texts, &(&1 == "Proposed change"))
      assert Enum.any?(texts, &(&1 =~ "Not yet applied"))
      assert Enum.any?(texts, &(&1 =~ "total"))
    end

    test ":approval mounts ApprovalPrompt (embedding BlastRadiusPreview), showing action + blast radius + options" do
      block = fixture_block(:approval)

      assert {:ok, view} =
               BodyProvider.mount(block.kind, block.content,
                 context: default_context()
               )

      texts = flat_texts(view)
      assert Enum.any?(texts, &(&1 =~ "rm -rf build/"))
      assert Enum.any?(texts, &(&1 =~ "IRREVERSIBLE"))
      assert Enum.any?(texts, &(&1 =~ "build/"))
      assert Enum.any?(texts, &(&1 =~ "Allow once"))
      assert Enum.any?(texts, &(&1 =~ "Deny"))
    end
  end
end
