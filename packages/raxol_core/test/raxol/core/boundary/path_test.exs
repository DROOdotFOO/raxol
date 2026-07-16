defmodule Raxol.Core.Boundary.PathTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Boundary.Path, as: Confine
  alias Raxol.Core.Boundary.Vectors

  @sha_format ~r/^(blobs|snapshots)\/[0-9a-f]{64}(\.json)?$/

  setup do
    base =
      Path.join(System.tmp_dir!(), "raxol_boundary_path_#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  # ---------------------------------------------------------------------------
  # Shared conformance vectors (the drift guard). Same JSON the Agent Client Protocol FsSandbox
  # copies verbatim.
  # ---------------------------------------------------------------------------

  describe "shared reject vectors" do
    for vector <- Vectors.load("path_reject_vectors.json") do
      @vector vector
      test "rejects #{vector["name"]} with :#{vector["expect"]}", %{base: base} do
        vroot = Path.join(base, "vec_#{@vector["name"]}")
        File.mkdir_p!(vroot)
        Vectors.materialize(vroot, @vector["setup"])
        root = Vectors.root_path(vroot, @vector)
        expected = String.to_existing_atom(@vector["expect"])

        assert Confine.confine(root, @vector["requested"], Vectors.opts(@vector)) ==
                 {:error, expected}
      end
    end
  end

  describe "shared accept vectors" do
    for vector <- Vectors.load("path_accept_vectors.json") do
      @vector vector
      test "accepts #{vector["name"]}", %{base: base} do
        vroot = Path.join(base, "vec_#{@vector["name"]}")
        File.mkdir_p!(vroot)
        Vectors.materialize(vroot, @vector["setup"])
        root = Vectors.root_path(vroot, @vector)

        assert {:ok, real} = Confine.confine(root, @vector["requested"], Vectors.opts(@vector))
        real_root = resolve_real(root)
        assert real == real_root or String.starts_with?(real, real_root <> "/")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Filesystem behavior assertions (site-level, richer than the vector runner).
  # ---------------------------------------------------------------------------

  describe "confine/3 real filesystem" do
    test "confined read resolves to a path under root", %{base: base} do
      File.mkdir_p!(Path.join(base, "sub"))
      File.write!(Path.join(base, "sub/a.txt"), "hi")

      assert {:ok, real} = Confine.confine(base, "sub/a.txt")
      assert File.read!(real) == "hi"
      assert String.starts_with?(real, resolve_real(base) <> "/")
    end

    test "not-yet-existing write leaf under root is accepted and writable", %{base: base} do
      assert {:ok, real} = Confine.confine(base, "new/leaf.txt")
      refute File.exists?(real)
      File.mkdir_p!(Path.dirname(real))
      assert File.write!(real, "created") == :ok
      assert File.read!(real) == "created"
      assert String.starts_with?(real, resolve_real(base) <> "/")
    end

    test "../ escape is rejected and the outside target is neither read nor created", %{
      base: base
    } do
      outside = Path.join(base, "outside")
      File.mkdir_p!(outside)
      secret = Path.join(outside, "secret.txt")
      File.write!(secret, "SECRET")

      root = Path.join(base, "root")
      File.mkdir_p!(root)

      assert Confine.confine(root, "../outside/secret.txt") == {:error, :path_traversal}
      # untouched: still exactly what we wrote, and no new file appeared under root
      assert File.read!(secret) == "SECRET"
      assert File.ls!(root) == []
    end

    test "leaf symlink escaping root is rejected (:symlink_escape)", %{base: base} do
      outside = Path.join(base, "outside")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "SECRET")

      root = Path.join(base, "root")
      File.mkdir_p!(root)
      :ok = File.ln_s!("../outside/secret.txt", Path.join(root, "link"))

      assert Confine.confine(root, "link") == {:error, :symlink_escape}
    end

    test "symlinked ancestor directory escaping root is rejected (:symlink_escape)", %{base: base} do
      outside = Path.join(base, "outside")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "SECRET")

      root = Path.join(base, "root")
      File.mkdir_p!(root)
      :ok = File.ln_s!("../outside", Path.join(root, "esc"))

      assert Confine.confine(root, "esc/secret.txt") == {:error, :symlink_escape}
    end

    test "symlink pointing inside root is accepted", %{base: base} do
      root = Path.join(base, "root")
      File.mkdir_p!(Path.join(root, "data"))
      File.write!(Path.join(root, "data/x.txt"), "inside")
      :ok = File.ln_s!("data", Path.join(root, "link"))

      assert {:ok, real} = Confine.confine(root, "link/x.txt")
      assert File.read!(real) == "inside"
    end

    test "symlink cycle is rejected (:too_many_symlinks)", %{base: base} do
      root = Path.join(base, "root")
      File.mkdir_p!(root)
      :ok = File.ln_s!("b", Path.join(root, "a"))
      :ok = File.ln_s!("a", Path.join(root, "b"))

      assert Confine.confine(root, "a") == {:error, :too_many_symlinks}
    end

    test "relative leaf symlink under a depth-inflating ancestor cannot under-apply .. (:symlink_escape)",
         %{base: base} do
      # A symlink's relative target must resolve against its REAL parent, not its
      # lexical parent. `loop -> .` inflates lexical depth (root/loop/loop == root),
      # so resolving `esc -> ../secret.txt` against the LEXICAL parent (root/loop)
      # lands on root/secret.txt (interior) while the OS resolves it to
      # base/secret.txt (outside root). Asserts the escape directly -- no
      # confine-derived oracle -- so it fails if the escape is ever accepted.
      File.write!(Path.join(base, "secret.txt"), "SECRET")

      root = Path.join(base, "root")
      File.mkdir_p!(root)
      :ok = File.ln_s!(".", Path.join(root, "loop"))
      :ok = File.ln_s!("../secret.txt", Path.join(root, "esc"))

      assert Confine.confine(root, "loop/loop/esc") == {:error, :symlink_escape}
    end

    test "deep symlink-free nesting is not mistaken for a symlink cycle", %{base: base} do
      # The depth cap counts symlink hops, not directory nesting: a tree far
      # deeper than @max_symlink_depth (40) with zero symlinks must still resolve.
      deep = Enum.map_join(1..80, "/", &"d#{&1}")
      File.mkdir_p!(Path.join(base, deep))
      File.write!(Path.join([base, deep, "leaf.txt"]), "deep")

      assert {:ok, real} = Confine.confine(base, deep <> "/leaf.txt")
      assert File.read!(real) == "deep"
      assert String.starts_with?(real, resolve_real(base) <> "/")
    end
  end

  describe "confine/3 ref-shape gate" do
    test "accepts a well-formed sha ref", %{base: base} do
      req = "blobs/" <> String.duplicate("a", 64)
      assert {:ok, _} = Confine.confine(base, req, ref_format: @sha_format)
    end

    test "accepts a well-formed snapshot .json ref", %{base: base} do
      req = "snapshots/" <> String.duplicate("0", 64) <> ".json"
      assert {:ok, _} = Confine.confine(base, req, ref_format: @sha_format)
    end

    test "rejects a malformed ref before resolution (:malformed_ref)", %{base: base} do
      assert Confine.confine(base, "blobs/../../etc/passwd", ref_format: @sha_format) ==
               {:error, :malformed_ref}

      assert Confine.confine(base, "blobs/" <> String.duplicate("A", 64), ref_format: @sha_format) ==
               {:error, :malformed_ref}

      assert Confine.confine(base, "blobs/abc123", ref_format: @sha_format) ==
               {:error, :malformed_ref}
    end

    test "ref gate fires before the lexical gate", %{base: base} do
      # a traversal that would also be :path_traversal is reported as
      # :malformed_ref because the ref gate runs first
      assert Confine.confine(base, "../../etc/passwd", ref_format: @sha_format) ==
               {:error, :malformed_ref}
    end
  end

  describe "confine/3 totality" do
    test "non-binary inputs never raise" do
      assert Confine.confine(nil, "x") == {:error, :invalid_input}
      assert Confine.confine("/root", nil) == {:error, :invalid_input}
      assert Confine.confine(123, 456) == {:error, :invalid_input}
    end

    test "a non-Regex ref_format fails closed (:malformed_ref)", %{base: base} do
      assert Confine.confine(base, "blobs/x", ref_format: "not-a-regex") ==
               {:error, :malformed_ref}
    end
  end

  # ---------------------------------------------------------------------------
  # Property: confine/3 never returns {:ok, p} with p outside the resolved root.
  # ---------------------------------------------------------------------------

  describe "property: accepted paths never escape root" do
    test "random requested refs (with .. segments and absolute paths) never escape", %{
      base: base
    } do
      root = Path.join(base, "proot")
      File.mkdir_p!(Path.join(root, "sub"))
      File.write!(Path.join(root, "sub/f.txt"), "x")
      real_root = resolve_real(root)

      segments = ["a", "b", "sub", "..", "...", "f.txt", "etc", "", ".", "x"]

      for _ <- 1..500 do
        n = :rand.uniform(6)
        parts = for _ <- 1..n, do: Enum.random(segments)
        prefix = if :rand.uniform(2) == 1, do: "/", else: ""
        requested = prefix <> Enum.join(parts, "/")

        case Confine.confine(root, requested) do
          {:ok, real} ->
            assert real == real_root or String.starts_with?(real, real_root <> "/"),
                   "escape: #{inspect(requested)} -> #{inspect(real)} not under #{inspect(real_root)}"

          {:error, reason} ->
            assert reason in [:path_traversal, :symlink_escape, :too_many_symlinks]
        end
      end
    end
  end

  # Resolve a path the same way confine/3 does, for assertion comparisons
  # (handles macOS /tmp -> /private/tmp symlink normalization).
  defp resolve_real(path) do
    {:ok, real} = Confine.confine(path, ".")
    real
  end
end
