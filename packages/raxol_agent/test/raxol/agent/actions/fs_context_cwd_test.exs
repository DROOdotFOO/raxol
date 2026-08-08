defmodule Raxol.Agent.Actions.FsContextCwdTest do
  # async: false — asserts against the process-global fallback root too.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Actions.Fs
  alias Raxol.Agent.Actions.Workspace

  # Two tenant roots in one BEAM: the context cwd must fully decide
  # scoping, or a multi-tenant host leaks one tenant's tree to another.
  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "raxol-ctx-cwd-#{System.os_time(:millisecond)}-" <>
          "#{System.unique_integer([:positive])}"
      )

    tenant_a = Path.join(base, "a")
    tenant_b = Path.join(base, "b")
    File.mkdir_p!(tenant_a)
    File.mkdir_p!(tenant_b)
    File.write!(Path.join(tenant_a, "secret-a.txt"), "alpha")
    File.write!(Path.join(tenant_b, "secret-b.txt"), "beta")

    on_exit(fn -> File.rm_rf!(base) end)

    %{a: tenant_a, b: tenant_b}
  end

  test "working_dir/1 honors the context cwd over the global root", %{a: a} do
    assert Fs.working_dir(%{cwd: a}) == Path.expand(a)
    refute Fs.working_dir() == Path.expand(a)
  end

  test "resolve/2 confines to the context cwd", %{a: a, b: b} do
    assert {:ok, abs} = Fs.resolve("secret-a.txt", %{cwd: a})
    assert abs == Path.join(Path.expand(a), "secret-a.txt")

    # The other tenant's tree is out of bounds, absolutely or relatively.
    assert {:error, :outside_cwd} =
             Fs.resolve(Path.join(b, "secret-b.txt"), %{cwd: a})

    assert {:error, :outside_cwd} = Fs.resolve("../b/secret-b.txt", %{cwd: a})
  end

  test "outside_cwd?/2 agrees with resolve/2 per context", %{a: a, b: b} do
    refute Fs.outside_cwd?("secret-a.txt", %{cwd: a})
    assert Fs.outside_cwd?(Path.join(b, "secret-b.txt"), %{cwd: a})
  end

  test "read_file scopes to the context cwd", %{a: a, b: b} do
    assert {:ok, %{content: "alpha"}} =
             Fs.ReadFile.run(%{path: "secret-a.txt"}, %{cwd: a})

    # Relative names resolve INSIDE the context root: under tenant B the
    # same name is B's (missing) file, never A's.
    assert {:error, :enoent} =
             Fs.ReadFile.run(%{path: "secret-a.txt"}, %{cwd: b})

    assert {:error, :outside_cwd} =
             Fs.ReadFile.run(
               %{path: Path.join(a, "secret-a.txt")},
               %{cwd: b}
             )
  end

  test "list_dir and file_stat scope to the context cwd", %{a: a, b: b} do
    assert {:ok, %{entries: ["secret-a.txt"]}} =
             Fs.ListDir.run(%{}, %{cwd: a})

    assert {:ok, %{entries: ["secret-b.txt"]}} = Fs.ListDir.run(%{}, %{cwd: b})

    assert {:ok, %{type: "regular"}} =
             Fs.FileStat.run(%{path: "secret-b.txt"}, %{cwd: b})

    assert {:error, :enoent} =
             Fs.FileStat.run(%{path: "secret-a.txt"}, %{cwd: b})
  end

  test "writes and edits scope to the context cwd", %{a: a, b: b} do
    assert {:ok, _result} =
             Workspace.do_write("notes.txt", "from a", %{cwd: a})

    assert File.read!(Path.join(a, "notes.txt")) == "from a"
    refute File.exists?(Path.join(b, "notes.txt"))

    assert {:error, :outside_cwd} =
             Workspace.do_write(Path.join(b, "escape.txt"), "x", %{cwd: a})

    assert {:ok, _result} =
             Workspace.do_edit("notes.txt", "from a", "edited a", %{cwd: a})

    assert File.read!(Path.join(a, "notes.txt")) == "edited a"
  end

  test "a jail marker without a cwd fails closed, never the global root", %{a: a} do
    # A jailed session whose context somehow lost its :cwd must NOT fall back
    # to the process-global cwd (that silently un-jails the tool). Refuse.
    assert {:error, :outside_cwd} = Fs.resolve("anything.txt", %{jail: true})
    assert {:error, :outside_cwd} = Fs.resolve("/etc/passwd", %{jail: true})
    assert Fs.outside_cwd?("anything.txt", %{jail: true})

    # Reads through the actions fail closed on the same predicate.
    assert {:error, :outside_cwd} =
             Fs.ReadFile.run(%{path: "anything.txt"}, %{jail: true})

    # A jailed session WITH a cwd is unaffected (still confined, still works).
    assert {:ok, %{content: "alpha"}} =
             Fs.ReadFile.run(%{path: "secret-a.txt"}, %{cwd: a, jail: true})

    assert {:error, :outside_cwd} =
             Fs.resolve("../escape", %{cwd: a, jail: true})
  end

  test "previews and staleness checks use the same context root", %{
    a: a,
    b: b
  } do
    assert {:ok, %{old: "alpha"}} =
             Workspace.preview_write("secret-a.txt", "new", %{cwd: a})

    # Against tenant B the same relative path is a NEW file, not A's.
    assert {:ok, %{old: ""}} =
             Workspace.preview_write("secret-a.txt", "new", %{cwd: b})

    hash = Workspace.content_hash("alpha")
    assert :ok = Workspace.verify_unchanged("secret-a.txt", hash, %{cwd: a})

    assert {:error, :stale} =
             Workspace.verify_unchanged("secret-a.txt", hash, %{cwd: b})
  end
end
