# Regression: DROOdotFOO #624 review HIGH -- the pre-#613 `real_path` bug that
# `FsSandbox` had inherited byte-for-byte. Two failure modes, both reproduced
# here against the real filesystem (no mocks):
#
#   1. A RELATIVE symlink target resolved against the *lexical* parent of the
#      requested path instead of the resolved-real directory the link lives in,
#      letting `root/loop -> "."` + `root/esc -> "../secret.txt"` requested as
#      `loop/loop/esc` fold an out-of-root target back inside the sandbox
#      (returned `{:ok, root/secret.txt}` instead of `:symlink_escape`).
#   2. The depth guard advanced on every DIRECTORY recursion, so a deeply
#      nested but symlink-free path (>40 components) wrongly tripped
#      `:too_many_symlinks`.
#
# The shared-vector drift guard (`fs_sandbox_vectors_test.exs`) never fired on
# (1) because no vector covered the relative-symlink-under-symlinked-ancestor
# class; a matching reject vector was added alongside this fix. This file is the
# belt-and-suspenders explicit witness for both classes.
defmodule Raxol.AgentClientProtocol.Client.FsSandboxSymlinkEscapeTest do
  use ExUnit.Case, async: false

  alias Raxol.AgentClientProtocol.Client.FsSandbox

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "acp_fs_sandbox_escape_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  test "relative symlink target under a symlinked ancestor cannot escape the sandbox", %{
    base: base
  } do
    root = Path.join(base, "root")
    File.mkdir_p!(root)
    # The escape target sits OUTSIDE the sandbox (sibling of `root`).
    File.write!(Path.join(base, "secret.txt"), "TOP SECRET")
    # `loop` points at its own directory; walking `loop/loop/...` keeps the
    # real cwd at `root` while the lexical path grows -- the exact divergence
    # the buggy resolver collapsed incorrectly.
    File.ln_s!(".", Path.join(root, "loop"))
    File.ln_s!("../secret.txt", Path.join(root, "esc"))

    assert {:error, error} = FsSandbox.resolve(root, "loop/loop/esc")

    assert error.data["reason"] == "symlink_escape",
           "expected symlink_escape, got #{inspect(error.data["reason"])} " <>
             "(pre-fix resolver folded the target back inside root)"
  end

  test "deeply nested symlink-free path is not misreported as too_many_symlinks", %{base: base} do
    root = Path.join(base, "root")
    # 60 real directory levels, zero symlinks -- must resolve, not trip the
    # symlink-hop guard (@max_symlink_depth = 40).
    deep_rel = Enum.map_join(1..60, "/", &"d#{&1}")
    File.mkdir_p!(Path.join(root, deep_rel))

    assert {:ok, real} = FsSandbox.resolve(root, deep_rel)
    assert String.ends_with?(real, deep_rel)
  end

  test "a genuine symlink cycle still trips too_many_symlinks", %{base: base} do
    root = Path.join(base, "root")
    File.mkdir_p!(root)
    File.ln_s!("b", Path.join(root, "a"))
    File.ln_s!("a", Path.join(root, "b"))

    assert {:error, error} = FsSandbox.resolve(root, "a")
    assert error.data["reason"] == "too_many_symlinks"
  end
end
