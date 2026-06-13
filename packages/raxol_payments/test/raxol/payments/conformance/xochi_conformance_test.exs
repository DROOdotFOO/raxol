defmodule Raxol.Payments.Conformance.XochiConformanceTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Test.ConformanceFixture

  @moduletag :conformance

  setup_all do
    case ConformanceFixture.locate() do
      {:ok, _path} -> :ok
      {:error, :not_found} -> {:skip, "conformance fixture not found"}
    end
  end

  # Xochi vectors carry their full EIP-712 typed data inline because the
  # domain has no `verifyingContract` and the `version` is deployment-scoped
  # (read from the quote response at runtime).
  describe "Xochi XochiIntent EIP-712 conformance vs CLI" do
    for vec <- ConformanceFixture.by_protocol("xochi") do
      @vec vec

      test "digest matches CLI for #{vec["name"]}" do
        vec = @vec
        eip712 = vec["eip712"]
        domain = atomize_domain(eip712["domain"])
        types = atomize_types(eip712["types"])
        message = eip712["message"]

        assert {:ok, digest_bytes} = EIP712.hash(domain, types, message)
        digest_hex = "0x" <> Base.encode16(digest_bytes, case: :lower)

        assert digest_hex == vec["expected_digest"],
               "digest mismatch for #{vec["name"]}: got #{digest_hex}, expected #{vec["expected_digest"]}"
      end

      test "domain has no verifyingContract for #{vec["name"]}" do
        vec = @vec
        refute Map.has_key?(vec["eip712"]["domain"], "verifyingContract")
      end
    end
  end

  defp atomize_domain(domain) do
    base = %{name: domain["name"], chainId: domain["chainId"]}
    if domain["version"], do: Map.put(base, :version, domain["version"]), else: base
  end

  # CLI emits types as { TypeName: [{name, type}, ...], ... }; convert to
  # the {name, type} tuple shape Raxol.Payments.EIP712 expects.
  defp atomize_types(types) do
    Enum.into(types, %{}, fn {type_name, fields} ->
      tuples =
        Enum.map(fields, fn %{"name" => name, "type" => type} -> {name, type} end)

      {type_name, tuples}
    end)
  end
end
