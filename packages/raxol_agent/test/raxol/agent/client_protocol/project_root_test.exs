defmodule Raxol.Agent.ClientProtocol.ProjectRootTest do
  use ExUnit.Case, async: true

  @moduletag :unix_only

  alias Raxol.Agent.ClientProtocol.ProjectRoot

  # The directory's real path: the system's temporary directory may itself
  # be reached through a symlink.
  setup do
    tmp = Path.join(System.tmp_dir!(), "project_root_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "project/sub"))
    on_exit(fn -> File.rm_rf(tmp) end)
    {physical, 0} = System.cmd("pwd", ["-P"], cd: tmp)
    %{tmp: String.trim_trailing(physical, "\n")}
  end

  defp link(tmp, name, target) do
    path = Path.join(tmp, name)
    File.ln_s!(target, path)
    path
  end

  test "a directory named by its real path is itself", %{tmp: tmp} do
    project = Path.join(tmp, "project")

    assert ProjectRoot.resolve(project) == {:ok, project}
    assert ProjectRoot.resolve(project <> "/") == {:ok, project}
    assert ProjectRoot.resolve(Path.join(project, "sub/..")) == {:ok, project}
  end

  test "every spelling through symlinks is the one real path", %{tmp: tmp} do
    project = Path.join(tmp, "project")
    absolute = link(tmp, "absolute", project)
    relative = link(tmp, "relative", "project")
    chained = link(tmp, "chained", "relative")
    climbing = link(tmp, "climbing", "project/sub/..")
    parent = link(tmp, "parent", tmp)

    for spelling <- [absolute, relative, chained, climbing, Path.join(parent, "project")] do
      assert ProjectRoot.resolve(spelling) == {:ok, project}
    end

    assert ProjectRoot.resolve(Path.join(relative, "sub")) == {:ok, Path.join(project, "sub")}
  end

  test "what is not an existing directory is refused", %{tmp: tmp} do
    file = Path.join(tmp, "file")
    File.write!(file, "")
    loop = link(tmp, "loop", "loop")
    dangling = link(tmp, "dangling", "nowhere")

    for cwd <- [Path.join(tmp, "missing"), file, loop, dangling] do
      assert {:error, message} = ProjectRoot.resolve(cwd)
      assert message =~ "cwd must name an existing directory"
    end
  end

  test "a path that is not absolute, or not a path, is refused" do
    for cwd <- ["", "relative/dir", "./here", nil, 7] do
      assert {:error, message} = ProjectRoot.resolve(cwd)
      assert message =~ "cwd must be an absolute path"
    end
  end

  test "a path past 4,096 bytes is refused before it is looked at" do
    assert {:error, message} = ProjectRoot.resolve("/" <> String.duplicate("a", 4_096))
    assert message =~ "cwd is longer than 4096 bytes"
  end
end
