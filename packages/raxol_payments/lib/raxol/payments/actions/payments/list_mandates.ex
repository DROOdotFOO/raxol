defmodule Raxol.Payments.Actions.Payments.ListMandates do
  @moduledoc """
  Agent Action that lists Xochi delegation envelopes stored locally,
  filtered by whether the calling wallet is the issuer (`member`) or
  the addressee (`agent`).
  """

  @compile {:no_warn_undefined, Raxol.Agent.Action}

  use Raxol.Agent.Action,
    name: "payment_list_mandates",
    description:
      "List Xochi Mandate envelopes stored locally. role=\"member\" lists envelopes the local wallet issued; role=\"agent\" lists envelopes addressed to the local wallet.",
    schema: [
      input: [
        role: [
          type: :string,
          required: true,
          description:
            "\"member\" (this wallet is the issuer) or \"agent\" (this wallet presents)"
        ]
      ],
      output: [
        mandates: [
          type: {:list, :map},
          description:
            "Summary list. Each entry has envelope_hash, human_wallet, agent_wallet, scopes, max_amount_usd, max_calls, expires_at, expired."
        ]
      ]
    ]

  alias Raxol.Payments.Mandate
  alias Raxol.Payments.Mandate.Store

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  @impl true
  def run(%{role: role}, context) when role in ["member", "agent"] do
    case Map.fetch(context, :wallet) do
      {:ok, wallet} ->
        addr = wallet.address()
        now = System.system_time(:second)

        mandates =
          case role do
            "member" -> Store.list_for_member(addr)
            "agent" -> Store.list_for_agent(addr)
          end

        {:ok, %{mandates: Enum.map(mandates, &summarize(&1, now))}}

      :error ->
        {:error, :missing_wallet}
    end
  end

  def run(_params, _context), do: {:error, :invalid_role}

  defp summarize(%Mandate{} = m, now) do
    %{
      envelope_hash: "0x" <> Base.encode16(m.envelope_hash, case: :lower),
      human_wallet: m.human_wallet,
      agent_wallet: m.agent_wallet,
      scopes: m.scopes,
      max_amount_usd: m.max_amount_usd,
      max_calls: m.max_calls,
      expires_at: m.expires_at,
      expired: Mandate.expired?(m, now)
    }
  end
end
