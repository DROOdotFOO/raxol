# Reverse stealth conformance vectors: Elixir is the source of truth here.
#
# Emits vectors the Xochi TS reference validates -- proving a stealth payment
# OUR implementation generates is discoverable and spendable by the TS receiver
# (the forward fixture proves the opposite direction). Run with:
#
#   MIX_ENV=test mix run scripts/gen_reverse_stealth_vectors.exs
#
# It writes the fixture consumed by
# xochi/src/lib/reverse-stealth-conformance.test.ts. Regenerate if
# Raxol.Payments.Xochi.Stealth changes.

alias Raxol.Payments.Xochi.Stealth

out = "/Users/droo/CODE/xochi/src/lib/reverse-stealth-vectors.json"

# Deterministic 65-byte (r,s,v) EVM signatures and 32-byte ephemeral scalars.
# Distinct from the forward fixture so the two cover different inputs.
signatures = [
  {"rev-sig-a",
   "0x" <>
     "2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a" <>
     "0b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c" <>
     "1c"},
  {"rev-sig-b",
   "0x" <>
     "d0e2f4a6b8c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4b6c8d0e2" <>
     "f4a6b8c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4b6c8d0e2f4a6" <>
     "1b"},
  {"rev-sig-c",
   "0x" <>
     "5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b" <>
     "3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d" <>
     "1c"}
]

ephemerals = [
  "0x2a2b2c2d2e2f30313233343536373839404142434445464748494a4b4c4d4e4f",
  "0x63bfab5c9d3e2f10a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5",
  "0x1414141414141414141414141414141414141414141414141414141414141414"
]

hex = fn bin -> "0x" <> Base.encode16(bin, case: :lower) end

vectors =
  signatures
  |> Enum.with_index()
  |> Enum.map(fn {{name, signature}, i} ->
    {:ok, keys} = Stealth.derive_keys(signature)
    {sp_priv, sp_pub} = keys.spending
    {vp_priv, vp_pub} = keys.viewing

    ephemeral_priv = Enum.at(ephemerals, rem(i, length(ephemerals)))

    ephemeral_bin =
      ephemeral_priv |> String.replace_prefix("0x", "") |> Base.decode16!(case: :mixed)

    {:ok, s} =
      Stealth.generate(
        %{spending_pub_key: sp_pub, viewing_pub_key: vp_pub, chain_id: 1},
        ephemeral_bin
      )

    %{
      name: name,
      signature: signature,
      spending_priv: hex.(sp_priv),
      spending_pub: hex.(sp_pub),
      viewing_priv: hex.(vp_priv),
      viewing_pub: hex.(vp_pub),
      ephemeral_priv: ephemeral_priv,
      stealth_address: s.stealth_address,
      ephemeral_pub: hex.(s.ephemeral_pub_key),
      view_tag: s.view_tag
    }
  end)

File.write!(out, Jason.encode!(vectors, pretty: true) <> "\n")
IO.puts("wrote #{length(vectors)} reverse vectors to #{out}")
