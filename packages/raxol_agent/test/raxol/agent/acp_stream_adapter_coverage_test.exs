defmodule Raxol.Agent.AcpStreamAdapterCoverageTest do
  @moduledoc """
  Holds `AcpStreamAdapter`'s update-kind coverage against the protocol
  schema's own variant list, so the two cannot drift apart in silence.

  This is the test that was missing. `Schema.UsageUpdate` was fully ported and
  `Schema.SessionUpdate` decoded `usage_update` correctly, while the adapter
  left that kind in its unknown bucket and hard-coded `usage: %{}` on every
  `:turn_completed` -- so every ACP-hosted turn reported no tokens and no cost.
  Nothing failed, because no test compared the set the protocol can decode with
  the set the adapter can render. It degraded honestly (per-kind counts plus a
  first-occurrence marker) which is precisely why nobody noticed.

  The schema's `from_json/1` clauses are the registry, so they are read from
  source rather than restated here: restating them would reintroduce the second
  source of truth this test exists to remove. The dep path is resolved through
  `Mix.Project.deps_paths/0` so it works for a path dep and a Hex dep alike.
  """

  use ExUnit.Case, async: true

  alias Raxol.Agent.AcpStreamAdapter

  @protocol_dep Mix.Project.deps_paths()[:raxol_agent_client_protocol] || ""
  @schema_relative "lib/raxol/agent_client_protocol/schema/session_update.ex"
  @schema_source Path.join(@protocol_dep, @schema_relative)

  @external_resource @schema_source

  # Every discriminator `SessionUpdate.from_json/1` dispatches on.
  @schema_variants (case File.read(@schema_source) do
                      {:ok, source} ->
                        Regex.scan(~r/"sessionUpdate" => "([a-z_]+)"/, source)
                        |> Enum.map(fn [_, name] -> String.to_atom(name) end)
                        |> Enum.uniq()

                      {:error, _} ->
                        []
                    end)

  test "the schema source was found, so the assertions below are not vacuous" do
    assert length(@schema_variants) > 5,
           "could not read session/update variants from #{@schema_source}; " <>
             "if that module moved, point this test at its new home rather " <>
             "than deleting it"
  end

  test "every session/update kind the schema decodes is one the adapter handles" do
    unhandled = @schema_variants -- AcpStreamAdapter.known_kinds()

    assert unhandled == [], """
    These ACP update kinds decode fine in Schema.SessionUpdate but reach
    AcpStreamAdapter's catch-all, so a peer sending them is reported as
    emitting an unknown variant:

        #{inspect(unhandled)}

    Map each one in apply_update/2 and add it to @mapped, or -- if dropping it
    is deliberate -- add it to @counted_unmapped so the choice is on the record.
    """
  end

  test "the adapter claims no kind the schema cannot produce" do
    phantom = AcpStreamAdapter.known_kinds() -- @schema_variants

    assert phantom == [], """
    AcpStreamAdapter handles kinds the protocol schema never decodes:
    #{inspect(phantom)}. Either the schema lost a variant or these names are
    stale, and a stale name reads as coverage this adapter does not have.
    """
  end

  test "no kind is both mapped and declared unmapped" do
    kinds = AcpStreamAdapter.known_kinds()

    assert length(kinds) == length(Enum.uniq(kinds)),
           "a kind appears twice in known_kinds/0, so one of @mapped or " <>
             "@counted_unmapped is lying about it: #{inspect(kinds -- Enum.uniq(kinds))}"
  end
end
