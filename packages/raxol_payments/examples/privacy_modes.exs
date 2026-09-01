# Privacy Modes: stealth on Ethereum vs shielded on Aztec
#
# The site calls these two settlement modes and moves on. They are not two
# strengths of the same thing -- they hide different facts from different
# people, and an agent picking one is choosing what it is willing to leak.
#
#   stealth (ERC-5564, on Ethereum)
#     The payment IS on the public chain. The amount, the token and the fact
#     that someone was paid are all visible. What is hidden is WHO: the funds
#     land on a one-time address nobody can link to the recipient's published
#     identity without their viewing key. The recipient has to go looking --
#     there is no notification, so they scan announcements.
#
#   shielded (Aztec)
#     The payment is a note in an L2's private state. The amount and the
#     recipient are hidden, not just unlinkable. What leaks is that a
#     transaction happened at all, and the nullifier that will eventually
#     spend it.
#
# So: stealth breaks the link on a public ledger, shielded moves the transfer
# off the public ledger. Section 3 puts that side by side.
#
# Runs fully offline. Section 1 is real secp256k1 -- the same code that derives
# a live stealth address, doing it here with throwaway keys. Section 2 drives
# `Pxe.Client` against an in-process bridge sim, because a real one embeds an
# Aztec PXE and this example is not worth a node.
#
# Usage (from packages/raxol_payments/):
#
#   MIX_ENV=test mix run examples/privacy_modes.exs

Logger.configure(level: :warning)

defmodule PrivacyModes do
  alias Raxol.Payments.Pxe.Client, as: Pxe
  alias Raxol.Payments.Pxe.Schemas.CreateNoteParams
  alias Raxol.Payments.Xochi.Stealth

  def run do
    recipient = keypair()
    stealth(recipient)
    shielded()
    contrast()
    :ok
  end

  # -- 1. stealth: unlinkable, but still on Ethereum --

  defp stealth(recipient) do
    header("1. stealth  (ERC-5564, on Ethereum)")

    meta = Stealth.encode_meta_address(pub(recipient))

    IO.puts("  the recipient publishes ONE meta-address, once:")
    IO.puts("    #{String.slice(meta, 0, 62)}...")
    IO.puts("    registry #{Stealth.registry_address()}  (ERC-6538)\n")

    # Each payment derives its own address. The sender needs nothing from the
    # recipient beyond the meta-address they already published.
    {:ok, a} = Stealth.generate(pub(recipient))
    {:ok, b} = Stealth.generate(pub(recipient))

    IO.puts("  a sender derives a fresh address per payment, offline:")
    IO.puts("    payment 1 -> #{a.stealth_address}  view tag #{a.view_tag}")
    IO.puts("    payment 2 -> #{b.stealth_address}  view tag #{b.view_tag}")

    IO.puts("""

      Two payments to one recipient, and nothing on chain relates them. The
      sender did not ask the recipient for anything and the recipient was not
      told: that is the trade, and it is why the next step exists.
    """)

    scan(recipient, [a, b])
  end

  # The recipient has no notification, so they read the announcer's log. Every
  # announcement is a candidate; the view tag is what stops that being 256 full
  # ECDH operations per payment received.
  defp scan(recipient, ours) do
    noise = Enum.map(1..18, fn _ -> elem(Stealth.generate(pub(keypair())), 1) end)
    feed = Enum.shuffle(Enum.map(ours ++ noise, &announcement/1))

    IO.puts("  the recipient scans the announcer (ERC-5564), #{length(feed)} entries:")

    {spend_priv, _} = recipient.spending
    {view_priv, _} = recipient.viewing
    {:ok, found} = Stealth.scan(spend_priv, view_priv, feed)

    for p <- found do
      IO.puts("    mine: #{p.announcement.stealth_address}")
    end

    IO.puts("    #{length(found)} of #{length(feed)} are ours, each with a spend key\n")

    # The same feed, read by somebody else's keys.
    stranger = keypair()
    {s_priv, _} = stranger.spending
    {v_priv, _} = stranger.viewing
    {:ok, none} = Stealth.scan(s_priv, v_priv, feed)

    IO.puts("  a stranger scanning the SAME feed finds #{length(none)}.")

    IO.puts("""
      Not because the entries are encrypted -- they are public -- but because
      linking one to a recipient needs that recipient's viewing key.
    """)
  end

  # -- 2. shielded: off the public ledger entirely --

  defp shielded do
    header("2. shielded  (a note on Aztec)")

    config = %{url: "https://pxe.sim", req_options: [plug: &bridge/1]}

    {:ok, health} = Pxe.health(config)
    {:ok, version} = Pxe.get_version(config)
    IO.puts("  bridge #{health.status}, aztec #{version}\n")

    {:ok, note} =
      Pxe.create_note(config, %CreateNoteParams{
        recipient: "0x" <> String.duplicate("ab", 32),
        token: "0x" <> String.duplicate("cd", 32),
        amount: "25000000",
        chain_id: 1
      })

    IO.puts("  the transfer becomes a note in Aztec's private state:")
    IO.puts("    commitment  #{note.note_commitment}")
    IO.puts("    nullifier   #{note.nullifier_hash}")
    IO.puts("    l2 tx       #{note.l2_tx_hash}")

    IO.puts("""

      No address received anything a public explorer can total up. The amount
      is inside the note; the commitment is a hash of it. The nullifier is what
      will be published when the note is spent, and it is what stops it being
      spent twice without revealing which note it was.
    """)
  end

  # -- 3. the choice --

  defp contrast do
    header("3. what each one actually hides")

    rows = [
      {"who was paid", "hidden", "hidden"},
      {"how much", "PUBLIC", "hidden"},
      {"that a payment happened", "PUBLIC", "PUBLIC"},
      {"settles on", "Ethereum", "Aztec L2"},
      {"recipient must scan", "yes", "no"},
      {"funds spendable with", "one-time key", "note + nullifier"}
    ]

    IO.puts("  #{pad("", 26)}#{pad("stealth", 18)}shielded")

    for {label, s, z} <- rows do
      IO.puts("  #{pad(label, 26)}#{pad(s, 18)}#{z}")
    end

    IO.puts("""

      `Router.select(privacy: :stealth)` and `:shielded` both route to Xochi,
      so the rail is the same and the settlement target is the difference. An
      agent that must not reveal an amount cannot take stealth, however
      unlinkable the address is -- which is the row people read past.
    """)
  end

  # -- helpers --

  defp keypair do
    seed = "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    {:ok, keys} = Stealth.derive_keys(seed)
    keys
  end

  defp pub(keys) do
    {_, spending} = keys.spending
    {_, viewing} = keys.viewing
    %{spending_pub_key: spending, viewing_pub_key: viewing, chain_id: 1}
  end

  # An announcement as the ERC-5564 announcer emits it. Only the view tag byte
  # in `metadata`, the ephemeral key and the address matter to a scanner; the
  # rest is log position.
  defp announcement(settlement) do
    %{
      scheme_id: Stealth.scheme_id(),
      stealth_address: settlement.stealth_address,
      caller: "0x" <> String.duplicate("11", 20),
      ephemeral_pub_key: settlement.ephemeral_pub_key,
      metadata: Stealth.create_metadata(settlement.view_tag),
      block_number: 21_000_000,
      tx_hash: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      log_index: 0
    }
  end

  # In-process pxe-bridge: JSON-RPC on "/", health on "/status".
  defp bridge(conn) do
    case conn.request_path do
      "/status" ->
        Req.Test.json(conn, %{"status" => "ok", "version" => "0.1.0"})

      "/" ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => rpc_result(conn)
        })
    end
  end

  defp rpc_result(conn) do
    case conn.body_params["method"] do
      "aztec_getVersion" ->
        "0.87.4"

      "aztec_createNote" ->
        %{
          "noteCommitment" => "0x" <> String.duplicate("7c", 32),
          "nullifierHash" => "0x" <> String.duplicate("3e", 32),
          "l2TxHash" => "0x" <> String.duplicate("9a", 32)
        }
    end
  end

  defp header(title), do: IO.puts("\n== #{title} ==\n")
  defp pad(text, width), do: String.pad_trailing(text, width)
end

PrivacyModes.run()
