defmodule Raxol.BoundaryVectorParityTest do
  @moduledoc """
  The two copies of the shared path-confinement conformance corpus must be
  byte-identical.

  `Raxol.Core.Boundary.Path` and `Raxol.AgentClientProtocol.Client.FsSandbox`
  are deliberate duplicates: the Agent Client Protocol package must stay
  zero-raxol-dep, so it cannot consume raxol_core. Three places in the tree say
  the duplication is safe BECAUSE both bind to one corpus:

    * `packages/raxol_core/lib/raxol/core/boundary/path.ex` -- "both bind to the
      same shared conformance vectors ... so drift is a red test, not a silent
      fork"
    * `packages/raxol_agent_client_protocol/lib/raxol/agent_client_protocol/client.ex`
      -- "The two are bound to the SAME shared conformance vectors"
    * `packages/raxol_core/test/support/boundary_vectors/README.md` -- "Change a
      path vector and you must update both copies ... or neither"

  All three stated a rule that nothing ran. The corpora are two directories of
  JSON copied by hand, so adding a vector to one and forgetting the other turned
  that package red against a corpus the sibling had never seen, while the
  sibling stayed green against its stale copy -- which reads as "the sibling is
  fine" and is the exact silent fork the duplication was allowed on condition of
  avoiding.

  This lives in the ROOT suite because it is the only one that structurally owns
  both packages: neither package can see the other's test tree from its own
  `mix test`, and raxol_core must not grow a path dependency on the Agent Client
  Protocol package just to check a file.
  """

  use ExUnit.Case, async: true

  @core "packages/raxol_core/test/support/boundary_vectors"
  @acp "packages/raxol_agent_client_protocol/test/support/boundary_vectors"

  # Only the `path_*` files are shared. `term_text_vectors.json` drives
  # `Boundary.TermText`, a different boundary with no ACP counterpart, and
  # `README.md` documents the corpus rather than being part of it -- so a rule
  # of "every file in one exists in the other" would be wrong in the direction
  # that produces false failures.
  @shared "path_*_vectors.json"

  defp shared_names(dir) do
    dir
    |> Path.join(@shared)
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
    |> Enum.sort()
  end

  test "both packages carry the same set of shared path vector files" do
    core = shared_names(@core)
    acp = shared_names(@acp)

    assert core != [],
           "no #{@shared} under #{@core}; this test is checking nothing"

    assert core == acp,
           """
           The shared path-vector file sets have diverged.

             #{@core}: #{inspect(core)}
             #{@acp}: #{inspect(acp)}

           A new vector FILE has to be copied into both trees, the same as a new
           vector inside one. Only #{@shared} is shared; term_text_vectors.json
           is raxol_core's alone.
           """
  end

  test "every shared path vector file is byte-identical across the two copies" do
    for name <- shared_names(@core) do
      core_path = Path.join(@core, name)
      acp_path = Path.join(@acp, name)

      # Compared as BYTES, not as decoded JSON. The README's rule is "copy
      # verbatim", and a decoded comparison would pass on two files that differ
      # in key order or whitespace -- which is a copy nobody actually made, and
      # the next hand-merge between them is where a vector goes missing.
      assert File.read!(core_path) == File.read!(acp_path),
             """
             #{name} differs between the two boundary vector trees.

               #{core_path}
               #{acp_path}

             `Raxol.Core.Boundary.Path` and
             `Raxol.AgentClientProtocol.Client.FsSandbox` are duplicate
             implementations kept honest ONLY by both running this corpus. A
             vector added to one tree and not the other leaves the sibling
             green against a case it has never been asked about.

             Copy the file across verbatim:

                 cp #{core_path} #{acp_path}

             Then make sure the sibling implementation actually passes it. If it
             cannot -- because the vector exercises a `Path.confine/3`-only
             feature such as the `ref_format` ref-shape gate -- the vector still
             belongs in both files; it is the ACP-side test that skips it, per
             #{@core}/README.md.
             """
    end
  end
end
