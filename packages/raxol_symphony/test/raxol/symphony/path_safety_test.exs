defmodule Raxol.Symphony.PathSafetyTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.PathSafety

  describe "sanitize_key/1" do
    test "passes through allowed characters" do
      assert PathSafety.sanitize_key("MT-123") == "MT-123"
      assert PathSafety.sanitize_key("abc.def_ghi") == "abc.def_ghi"
      assert PathSafety.sanitize_key("123-ABC.xyz_999") == "123-ABC.xyz_999"
    end

    test "replaces forbidden characters with underscore" do
      assert PathSafety.sanitize_key("MT 123") == "MT_123"
      assert PathSafety.sanitize_key("foo/bar") == "foo_bar"
      assert PathSafety.sanitize_key("..") == ".."
      assert PathSafety.sanitize_key("foo$bar") == "foo_bar"
    end

    test "neutralizes path traversal attempts" do
      # Forward slashes get sanitized; the resulting key contains no separators.
      sanitized = PathSafety.sanitize_key("../../etc/passwd")
      refute String.contains?(sanitized, "/")
      assert sanitized == ".._.._etc_passwd"
    end

    test "handles unicode by replacing each byte/char outside the allowed set" do
      sanitized = PathSafety.sanitize_key("résumé")
      refute sanitized =~ ~r/[éü]/
      # Length stays positive; non-ASCII chars all turn into underscores.
      assert sanitized == "r_sum_"
    end
  end

  describe "workspace_path/2" do
    test "produces an absolute path under root" do
      root = "/tmp/symphony_workspaces_test"
      assert {:ok, path} = PathSafety.workspace_path(root, "MT-42")
      assert path == "/tmp/symphony_workspaces_test/MT-42"
      assert Path.type(path) == :absolute
    end

    test "applies sanitization to the identifier component" do
      root = "/tmp/symphony_workspaces_test"
      assert {:ok, path} = PathSafety.workspace_path(root, "abc/../etc")
      assert Path.basename(path) == "abc_.._etc"
      # Result must still be inside root.
      assert String.starts_with?(path, root <> "/")
    end

    test "rejects empty workspace root" do
      assert {:error, :invalid_workspace_root} = PathSafety.workspace_path("", "MT-42")
    end
  end

  describe "validate_inside_root/2" do
    test "accepts a path under root" do
      assert {:ok, "/tmp/sym/A"} = PathSafety.validate_inside_root("/tmp/sym/A", "/tmp/sym")
    end

    test "accepts the root itself" do
      assert {:ok, "/tmp/sym"} = PathSafety.validate_inside_root("/tmp/sym", "/tmp/sym")
    end

    test "rejects a sibling-prefix path" do
      assert {:error, :workspace_outside_root} =
               PathSafety.validate_inside_root("/tmp/symbiote", "/tmp/sym")
    end

    test "rejects a path outside root" do
      assert {:error, :workspace_outside_root} =
               PathSafety.validate_inside_root("/etc/passwd", "/tmp/sym")
    end

    test "normalizes both paths before comparing" do
      assert {:ok, "/tmp/sym/A"} =
               PathSafety.validate_inside_root("/tmp/sym/./B/../A", "/tmp/sym/")
    end

    test "rejects path that traverses out via ../" do
      assert {:error, :workspace_outside_root} =
               PathSafety.validate_inside_root("/tmp/sym/../escape", "/tmp/sym")
    end
  end

  describe "assert_cwd!/1" do
    @tag :tmp_dir
    test "passes when cwd matches", %{tmp_dir: tmp_dir} do
      original = File.cwd!()

      try do
        File.cd!(tmp_dir)
        assert :ok = PathSafety.assert_cwd!(tmp_dir)
      after
        File.cd!(original)
      end
    end

    test "raises when cwd mismatches" do
      assert_raise RuntimeError, ~r/cwd .* != expected workspace/, fn ->
        PathSafety.assert_cwd!("/definitely/not/cwd")
      end
    end
  end

  describe "remote_workspace_path/2 (issue #744)" do
    test "joins the key onto an absolute remote root" do
      assert {:ok, "/var/lib/symphony/MT-1"} =
               PathSafety.remote_workspace_path("/var/lib/symphony", "MT-1")
    end

    test "sanitizes the identifier the same way the local path does" do
      assert {:ok, "/srv/ws/abc_.._etc"} =
               PathSafety.remote_workspace_path("/srv/ws", "abc/../etc")
    end

    test "leaves `~` for the remote login shell instead of expanding it here" do
      assert {:ok, "~/symphony/MT-1"} =
               PathSafety.remote_workspace_path("~/symphony", "MT-1")

      # The local home must not appear: this path names a directory on another
      # machine, and `Path.expand/1` would substitute the orchestrator's own.
      refute PathSafety.remote_workspace_path("~/symphony", "MT-1")
             |> elem(1)
             |> String.contains?(System.user_home!())
    end

    test "folds `.` and `..` inside the root without touching the local disk" do
      assert {:ok, "/srv/ws/MT-1"} =
               PathSafety.remote_workspace_path("/srv/./nested/../ws", "MT-1")
    end

    # Refused as a KEY, not as a containment miss. Containment cannot be the
    # guard here: `fold_remote/2` clamps `..` at the prefix rather than letting
    # it escape, so `/srv/ws/..` folds to `/srv` for a deep root (outside, and
    # caught) but `~/..` folds to `~` (inside its own root, and not).
    test "refuses an identifier that would climb out of the root" do
      assert {:error, :invalid_workspace_key} =
               PathSafety.remote_workspace_path("/srv/ws", "..")
    end

    test "refuses a relative root, which a login shell would resolve arbitrarily" do
      assert {:error, :invalid_workspace_root} =
               PathSafety.remote_workspace_path("relative/ws", "MT-1")
    end

    test "refuses an empty root" do
      assert {:error, :invalid_workspace_root} = PathSafety.remote_workspace_path("", "MT-1")
    end

    test "a `..` chain cannot climb above the root" do
      assert {:ok, "/"} = PathSafety.validate_inside_remote_root("/../../..", "/")
    end

    # `.`, `-` and `_` are all in the allowed class, so `""`, `"."` and `".."`
    # survive `sanitize_key/1` intact -- and containment does NOT catch them,
    # because each folds back onto the root and the root is inside itself. The
    # workspace then IS the root, and `Workspace.remove/3` deletes every other
    # issue's workspace with it. Against a `~` root that is `rm -rf ~` on the
    # host.
    test "an identifier that names the root itself is refused, not resolved to it" do
      for root <- ["~", "~ci", "/", "/srv/ws"], id <- ["", ".", ".."] do
        assert {:error, :invalid_workspace_key} =
                 PathSafety.remote_workspace_path(root, id),
               "#{inspect(root)} + #{inspect(id)} resolved onto its own root"
      end
    end

    test "an identifier that merely contains dots is still fine" do
      assert {:ok, "/srv/ws/MT-1.2"} = PathSafety.remote_workspace_path("/srv/ws", "MT-1.2")
      assert {:ok, "/srv/ws/..MT"} = PathSafety.remote_workspace_path("/srv/ws", "..MT")
    end
  end

  describe "workspace_path/2 (local)" do
    # The local builder collapses the same way: `Path.join(root, "")` is `root`,
    # and `File.rm_rf/1` on it takes out every sibling workspace.
    test "an identifier that names the root itself is refused" do
      for id <- ["", ".", ".."] do
        assert {:error, :invalid_workspace_key} = PathSafety.workspace_path("/srv/ws", id)
      end
    end

    test "an ordinary identifier still resolves under the root" do
      assert {:ok, "/srv/ws/MT-1"} = PathSafety.workspace_path("/srv/ws", "MT-1")
    end
  end

  describe "validate_inside_remote_root/2" do
    test "accepts a nested remote path" do
      assert {:ok, "/srv/ws/MT-1"} =
               PathSafety.validate_inside_remote_root("/srv/ws/MT-1", "/srv/ws")
    end

    test "rejects a sibling that merely shares a prefix" do
      assert {:error, :workspace_outside_root} =
               PathSafety.validate_inside_remote_root("/srv/wsother", "/srv/ws")
    end

    test "rejects a traversal out of the root" do
      assert {:error, :workspace_outside_root} =
               PathSafety.validate_inside_remote_root("/srv/ws/../escape", "/srv/ws")
    end
  end
end
