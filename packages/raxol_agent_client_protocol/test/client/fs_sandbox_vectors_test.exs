# Drift guard (migration P5, confinement-seam-proposal option b): binds
# `Raxol.AgentClientProtocol.Client.FsSandbox.resolve/2` to the SAME
# raxol_core-authored shared boundary vectors that gate
# `Raxol.Core.Boundary.Path.confine/3` (`test/support/boundary_vectors/
# path_{reject,accept}_vectors.json`, copied here verbatim -- see their own
# `description` field). `FsSandbox` is an intentionally independent
# reimplementation of the same lexical + symlink confinement rules (this
# package cannot depend on raxol_core); this test is what keeps the two from
# silently diverging. Vectors carrying `ref_format` are a `Path.confine`-only
# gate (regex-constrained ref names under a `blobs/`/`snapshots/` root) that
# `FsSandbox` does not implement at all -- skipped, not asserted either way,
# but accounted for by a dedicated "was skipped" test so a vendored-file edit
# that adds/removes one is still noticed.
defmodule Raxol.AgentClientProtocol.Client.FsSandboxVectorsTest do
  use ExUnit.Case, async: false

  alias Raxol.AgentClientProtocol.Client.FsSandbox

  @vectors_dir Path.join([__DIR__, "..", "support", "boundary_vectors"])

  # -- fixture materialization (runtime helpers, called from inside `test`
  # -- bodies) -- mirrors `Raxol.Core.Boundary.Vectors` (raxol_core's own
  # -- loader/materializer for the same JSON files) closely enough to prove
  # -- agreement, without a cross-package test dependency this package
  # -- cannot take.

  defp materialize(base, setup) when is_list(setup) do
    {symlinks, rest} = Enum.split_with(setup, &Map.has_key?(&1, "symlink"))

    Enum.each(rest, fn
      %{"dir" => rel} ->
        File.mkdir_p!(Path.join(base, rel))

      %{"file" => rel} = entry ->
        abs = Path.join(base, rel)
        File.mkdir_p!(Path.dirname(abs))
        File.write!(abs, Map.get(entry, "content", ""))
    end)

    Enum.each(symlinks, fn %{"symlink" => rel, "target" => target} ->
      abs = Path.join(base, rel)
      File.mkdir_p!(Path.dirname(abs))
      :ok = File.ln_s!(target, abs)
    end)

    :ok
  end

  defp root_path(base, %{"root" => "."}), do: base
  defp root_path(base, %{"root" => root}), do: Path.join(base, root)

  # Fresh tmp base per vector, torn down after the assertion (real filesystem
  # effects, not mocked).
  defp with_tmp_base(fun) do
    base =
      Path.join(
        System.tmp_dir!(),
        "acp_fs_sandbox_vectors_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(base)

    try do
      fun.(base)
    after
      File.rm_rf!(base)
    end
  end

  # -- MUST-REJECT vectors -----------------------------------------------------
  #
  # Vector generation itself (the `for`/`Jason.decode!` below) runs at
  # compile time, directly in the module body -- it cannot call this
  # module's own `defp`s (not yet compiled at that point), only already
  # -compiled modules (`Jason`, `File`, `Path`, `Enum`, `Map`).

  describe "MUST-REJECT vectors (path_reject_vectors.json)" do
    all_reject_vectors =
      @vectors_dir
      |> Path.join("path_reject_vectors.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("vectors")

    reject_vectors_to_run = Enum.reject(all_reject_vectors, &Map.has_key?(&1, "ref_format"))

    for vector <- reject_vectors_to_run do
      @vector vector

      test vector["name"] do
        vector = @vector

        with_tmp_base(fn base ->
          materialize(base, vector["setup"])
          root = root_path(base, vector)

          assert {:error, error} = FsSandbox.resolve(root, vector["requested"]),
                 "expected #{vector["name"]} (#{vector["requested"]}) to be rejected"

          assert error.data["reason"] == vector["expect"],
                 "expected #{vector["name"]} to reject with reason " <>
                   "#{inspect(vector["expect"])}, got #{inspect(error.data["reason"])}"
        end)
      end
    end

    @reject_exercised_count length(reject_vectors_to_run)
    @reject_skipped_count length(all_reject_vectors) - length(reject_vectors_to_run)

    test "every non-ref_format reject vector was exercised" do
      assert @reject_exercised_count > 0
    end

    test "at least one ref_format reject vector was skipped (accounted for, not silently dropped)" do
      assert @reject_skipped_count > 0
    end
  end

  # -- MUST-ACCEPT vectors ------------------------------------------------------

  describe "MUST-ACCEPT vectors (path_accept_vectors.json)" do
    all_accept_vectors =
      @vectors_dir
      |> Path.join("path_accept_vectors.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("vectors")

    accept_vectors_to_run = Enum.reject(all_accept_vectors, &Map.has_key?(&1, "ref_format"))

    for vector <- accept_vectors_to_run do
      @vector vector

      test vector["name"] do
        vector = @vector

        with_tmp_base(fn base ->
          materialize(base, vector["setup"])
          root = root_path(base, vector)

          assert {:ok, _real_path} = FsSandbox.resolve(root, vector["requested"]),
                 "expected #{vector["name"]} (#{vector["requested"]}) to be accepted"
        end)
      end
    end

    @accept_exercised_count length(accept_vectors_to_run)
    @accept_skipped_count length(all_accept_vectors) - length(accept_vectors_to_run)

    test "every non-ref_format accept vector was exercised" do
      assert @accept_exercised_count > 0
    end

    test "at least one ref_format accept vector was skipped (accounted for, not silently dropped)" do
      assert @accept_skipped_count > 0
    end
  end
end
