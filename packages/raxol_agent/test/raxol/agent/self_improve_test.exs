defmodule Raxol.Agent.SelfImproveTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Backend.Mock
  alias Raxol.Agent.Memory.Store.Ets, as: MemStore
  alias Raxol.Agent.SelfImprove
  alias Raxol.Agent.Skills.Store, as: SkillsStore

  @decision ~s({"memories":[{"content":"user prefers mise","type":"insight","tags":["tools"]}],) <>
              ~s("skills":[{"name":"deploy-fly","description":"Deploy to Fly","body":"# Deploy\\n\\nflyctl deploy"}]})

  @empty ~s({"memories":[],"skills":[]})

  setup do
    base = Path.join(System.tmp_dir!(), "selfimp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "skills"))
    on_exit(fn -> File.rm_rf(base) end)

    mem = :"mem_#{System.unique_integer([:positive])}"
    skills = :"sk_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: mem, start: {MemStore, :start_link, [[name: mem]]}})

    start_supervised!(%{
      id: skills,
      start:
        {SkillsStore, :start_link,
         [[name: skills, skills_root: Path.join(base, "skills"), external_dirs: []]]}
    })

    writers = %{
      memory: {MemStore, [server: mem, agent_id: "a"]},
      skills: {SkillsStore, [server: skills]}
    }

    %{writers: writers, mem: mem, skills: skills}
  end

  defp items(tool_calls) do
    calls =
      for i <- 1..tool_calls, do: %{type: :tool_call, data: %{name: "t#{i}", arguments: %{}}}

    calls ++ [%{type: :message, data: %{role: :assistant, content: "done"}}]
  end

  defp config(response, extra \\ []) do
    Map.merge(
      %{enabled: true, backend: Mock, backend_opts: [response: response], min_tool_calls: 1},
      Map.new(extra)
    )
  end

  describe "review/3" do
    test "writes a memory record and an agent-authored skill", %{
      writers: w,
      mem: mem,
      skills: skills
    } do
      assert {:ok, %{memories: 1, skills: 1}} = SelfImprove.review(items(1), w, config(@decision))

      assert [%{content: "user prefers mise"}] =
               MemStore.search("mise", server: mem, agent_id: "a")

      assert {:ok, %{created_by: :agent, name: "deploy-fly"}} =
               SkillsStore.get("deploy-fly", server: skills)
    end

    test "recovers JSON wrapped in prose or a code fence", %{writers: w, skills: skills} do
      wrapped = "Sure, here is the result:\n```json\n" <> @decision <> "\n```"
      assert {:ok, %{skills: 1}} = SelfImprove.review(items(1), w, config(wrapped))
      assert {:ok, _} = SkillsStore.get("deploy-fly", server: skills)
    end

    test "skips a write target that is absent from writers", %{skills: skills} do
      writers = %{skills: {SkillsStore, [server: skills]}}

      assert {:ok, %{memories: 0, skills: 1}} =
               SelfImprove.review(items(1), writers, config(@decision))
    end

    test "writes nothing for an empty decision", %{writers: w} do
      assert {:ok, %{memories: 0, skills: 0}} = SelfImprove.review(items(1), w, config(@empty))
    end
  end

  describe "qualifies?/2" do
    test "true when the turn succeeded and met the tool-call floor" do
      assert SelfImprove.qualifies?(items(5), %{min_tool_calls: 5})
      refute SelfImprove.qualifies?(items(2), %{min_tool_calls: 5})
    end

    test "false when the turn errored" do
      errored = items(5) ++ [%{type: :error, data: %{reason: "boom"}}]
      refute SelfImprove.qualifies?(errored, %{min_tool_calls: 1})
    end
  end

  describe "after_turn/3" do
    test "skipped when disabled or below the gate", %{writers: w} do
      assert SelfImprove.after_turn(items(5), w, nil) == :skipped
      assert SelfImprove.after_turn(items(1), w, config(@empty, min_tool_calls: 5)) == :skipped
    end

    test "spawned for a qualifying turn", %{writers: w} do
      assert SelfImprove.after_turn(items(1), w, config(@empty)) == :spawned
    end
  end

  describe "auxiliary routing" do
    test "routes curation through the resolved slot when no backend is set", %{
      writers: w,
      mem: mem
    } do
      config = %{
        enabled: true,
        min_tool_calls: 1,
        auxiliary: %{curation: %{harness: :mock, opts: [response: @decision]}}
      }

      assert {:ok, %{memories: 1, skills: 1}} = SelfImprove.review(items(1), w, config)

      assert [%{content: "user prefers mise"}] =
               MemStore.search("mise", server: mem, agent_id: "a")
    end

    test "an explicit backend overrides the slot", %{writers: w} do
      config = %{
        enabled: true,
        min_tool_calls: 1,
        backend: Mock,
        backend_opts: [response: @empty],
        auxiliary: %{curation: %{harness: :mock, opts: [response: @decision]}}
      }

      # The explicit backend returns @empty (0 writes). The slot's @decision would
      # have written 1 memory + 1 skill, so 0/0 proves the slot was not consulted.
      assert {:ok, %{memories: 0, skills: 0}} = SelfImprove.review(items(1), w, config)
    end
  end
end
