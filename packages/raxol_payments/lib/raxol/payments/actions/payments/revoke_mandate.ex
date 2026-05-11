defmodule Raxol.Payments.Actions.Payments.RevokeMandate do
  @moduledoc """
  Agent Action that locally deletes a stored Xochi Mandate envelope.

  v1 has no server revoke endpoint -- Xochi's KV budget counter for
  this envelope remains until `expires_at` per the agent-auth design
  doc (2026-04-27).
  """

  @compile {:no_warn_undefined, Raxol.Agent.Action}

  use Raxol.Agent.Action,
    name: "payment_revoke_mandate",
    description:
      "Locally delete a stored Xochi Mandate envelope so it can no longer be selected for outbound requests. Note: Xochi's server-side budget counter for this envelope remains until expires_at -- per agent-auth.md (2026-04-27), no server revoke endpoint exists in v1.",
    schema: [
      input: [
        envelope_hash: [
          type: :string,
          required: true,
          description: "0x-prefixed 32-byte hex envelope hash to revoke"
        ]
      ],
      output: [
        status: [type: :string],
        note: [type: :string]
      ]
    ]

  alias Raxol.Payments.Mandate.Store

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  @impl true
  def run(%{envelope_hash: hex}, _context) do
    with {:ok, hash} <- decode_hash(hex),
         {:ok, _mandate} <- Store.get(hash) do
      :ok = Store.delete(hash)

      {:ok,
       %{
         status: "local_revoked",
         note:
           "Xochi server still honors the envelope nonce until expires_at; no server revoke endpoint in v1"
       }}
    else
      :error -> {:error, :not_found}
      err -> err
    end
  end

  defp decode_hash("0x" <> hex) when byte_size(hex) == 64 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_hex}
    end
  end

  defp decode_hash(_), do: {:error, :invalid_envelope_hash_format}
end
