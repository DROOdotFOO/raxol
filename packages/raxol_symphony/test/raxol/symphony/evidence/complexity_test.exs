defmodule Raxol.Symphony.Evidence.ComplexityTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.{Config, Evidence}
  alias Raxol.Symphony.Evidence.Complexity

  defp config do
    Config.from_workflow(%{
      config: %{tracker: %{kind: "memory"}},
      prompt_template: ""
    })
  end

  defp tmp_workspace do
    path =
      Path.join(System.tmp_dir!(), "evidence_complexity_#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    path
  end

  setup do
    workspace = tmp_workspace()
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  describe "fallback SLOC counter" do
    test "counts code lines per recognized language", %{workspace: workspace} do
      File.write!(Path.join(workspace, "a.ex"), """
      defmodule A do
        # comment
        def hello, do: :world
      end
      """)

      File.write!(Path.join(workspace, "b.exs"), """
      IO.puts("hi")
      """)

      File.write!(Path.join(workspace, "c.unknown"), "noise\n")

      result =
        Complexity.collect(%Evidence{workspace: workspace}, config(), cloc_path: false)

      assert result.complexity.source == :fallback
      assert result.complexity.total_files == 2
      assert result.complexity.total_code >= 4
      assert Map.has_key?(result.complexity.languages, "elixir")
    end

    test "ignores _build, deps, .git, node_modules", %{workspace: workspace} do
      ignored = ["_build", "deps", ".git", "node_modules"]

      Enum.each(ignored, fn dir ->
        full = Path.join(workspace, dir)
        File.mkdir_p!(full)
        File.write!(Path.join(full, "junk.ex"), "defmodule Junk do\nend\n")
      end)

      File.write!(Path.join(workspace, "real.ex"), "defmodule Real do\nend\n")

      result =
        Complexity.collect(%Evidence{workspace: workspace}, config(), cloc_path: false)

      assert result.complexity.total_files == 1
    end
  end

  describe "cloc path" do
    test "tags errors[:complexity] with :cloc_failed when binary returns nonzero", %{
      workspace: workspace
    } do
      result =
        Complexity.collect(%Evidence{workspace: workspace}, config(), cloc_path: "/usr/bin/false")

      assert {:cloc_failed, _, _} = result.errors[:complexity]
      # Falls back to the walker, so complexity is still populated.
      assert result.complexity.source == :fallback
    end

    test "tags errors[:complexity] with :cloc_not_found when binary missing", %{
      workspace: workspace
    } do
      result =
        Complexity.collect(%Evidence{workspace: workspace}, config(),
          cloc_path: "/definitely/not/here/cloc"
        )

      assert result.errors[:complexity] == :cloc_not_found
      assert result.complexity.source == :fallback
    end
  end

  describe "missing workspace" do
    test "records :no_workspace error" do
      result = Complexity.collect(%Evidence{workspace: nil}, config(), [])
      assert result.errors[:complexity] == :no_workspace
      assert is_nil(result.complexity)
    end
  end
end
