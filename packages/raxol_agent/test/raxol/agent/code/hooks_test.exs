defmodule Raxol.Agent.Code.HooksTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Code.Hooks

  setup do
    dir = Path.join(System.tmp_dir!(), "raxol-hooks-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write_config(dir, json) do
    File.mkdir_p!(Path.join(dir, ".raxol"))
    File.write!(Path.join(dir, ".raxol/hooks.json"), Jason.encode!(json))
  end

  describe "load/1" do
    test "parses pre/post/stop rules", %{dir: dir} do
      write_config(dir, %{
        "pre_tool_use" => [%{"match" => "bash", "command" => "exit 0"}],
        "post_tool_use" => [%{"match" => "*", "command" => "true"}],
        "stop" => ["true"]
      })

      assert {:ok, config} = Hooks.load(dir)
      assert config.pre == [%{match: "bash", command: "exit 0"}]
      assert config.post == [%{match: "*", command: "true"}]
      assert config.stop == ["true"]
      assert Hooks.count(config) == 3
    end

    test "returns :none when there is no file", %{dir: dir} do
      assert :none = Hooks.load(dir)
    end

    test "errors on invalid json", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, ".raxol"))
      File.write!(Path.join(dir, ".raxol/hooks.json"), "{not json")
      assert {:error, :invalid_json} = Hooks.load(dir)
    end
  end

  describe "before_call/2 (pre-tool veto)" do
    test "a matching pre-hook that exits non-zero vetoes the call", %{dir: dir} do
      config = %{pre: [%{match: "bash", command: "exit 1"}], post: [], stop: []}
      context = %{code_hooks: config, hook_cwd: dir}
      call = %{action: __MODULE__, name: "bash", params: %{}, call_id: nil}

      assert {:halt, {:hook_blocked, "bash", "exit 1", 1}} =
               Hooks.before_call(call, context)
    end

    test "a matching pre-hook that exits zero allows the call", %{dir: dir} do
      config = %{pre: [%{match: "bash", command: "exit 0"}], post: [], stop: []}
      context = %{code_hooks: config, hook_cwd: dir}
      call = %{action: __MODULE__, name: "bash", params: %{}, call_id: nil}

      assert {:cont, ^call} = Hooks.before_call(call, context)
    end

    test "a non-matching tool runs no pre-hooks", %{dir: dir} do
      config = %{pre: [%{match: "bash", command: "exit 1"}], post: [], stop: []}
      context = %{code_hooks: config, hook_cwd: dir}
      call = %{action: __MODULE__, name: "read_file", params: %{}, call_id: nil}

      assert {:cont, ^call} = Hooks.before_call(call, context)
    end
  end

  describe "after_call/3" do
    test "runs post-hooks and returns the result unchanged", %{dir: dir} do
      config = %{pre: [], post: [%{match: "*", command: "true"}], stop: []}
      context = %{code_hooks: config, hook_cwd: dir}
      call = %{action: __MODULE__, name: "write_file", params: %{}, call_id: nil}

      assert {:ok, %{path: "x"}} = Hooks.after_call(call, {:ok, %{path: "x"}}, context)
    end
  end

  describe "run_stop/2" do
    test "runs each stop command and reports its exit status", %{dir: dir} do
      config = %{pre: [], post: [], stop: ["exit 0", "exit 2"]}
      receipts = Hooks.run_stop(config, dir)

      assert receipts == [
               %{command: "exit 0", exit_status: 0},
               %{command: "exit 2", exit_status: 2}
             ]
    end
  end
end
