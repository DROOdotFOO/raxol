defmodule Mix.Tasks.Acp.RegisterOffering do
  @moduledoc """
  Generate the offering metadata to paste into the Virtuals ACP
  marketplace UI at https://app.virtuals.io/acp/new (mainnet) or
  https://app.virtuals.gg/acp/new (dev).

  Output is a JSON document combining:

  - `name`, `display_name`, `description`, `sla_minutes`, `tags`,
    `hook_kind` from `Raxol.ACP.Xochi.Offering.offering_metadata/0`.
  - JSON Schema 2020-12 documents for the requirement and deliverable
    payloads.
  - Network-specific contract addresses pulled from
    `Raxol.ACP.Chain.mainnet/0` or `Raxol.ACP.Chain.sepolia/0`.

  ## Usage

      mix acp.register_offering                            # usdc_public, mainnet, stdout
      mix acp.register_offering --network sepolia
      mix acp.register_offering --offering stealth
      mix acp.register_offering --out offering.json
      mix acp.register_offering --pretty                   # indented JSON

  ## Options

  - `--offering` -- which offering to emit: `usdc_public` (default, the launch
    offering `xochi_usdc_public`), `public`, `stealth`, or `legacy` (the
    deprecated token-agnostic `xochi_cross_chain_transfer`).
  - `--network` -- `mainnet` (default) or `sepolia`. Picks the contract
    addresses + ACP server URL embedded in the output.
  - `--out PATH` -- write to a file instead of stdout.
  - `--pretty` -- emit pretty-printed JSON. Default is compact.

  ## Operator workflow

  Paste the output into the Virtuals dashboard (Offerings -> New offering) after
  registering the agent at `app.virtuals.io/acp/new`.
  """
  use Mix.Task

  alias Raxol.ACP.Chain
  alias Raxol.ACP.Xochi.Offering

  @shortdoc "Generate Virtuals marketplace offering metadata"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [network: :string, offering: :string, out: :string, pretty: :boolean]
      )

    network = opts |> Keyword.get(:network, "mainnet") |> String.to_atom()
    offering = opts |> Keyword.get(:offering, "usdc_public") |> String.to_atom()
    pretty? = Keyword.get(opts, :pretty, false)
    out = Keyword.get(opts, :out)

    payload = build_payload(network, offering)
    json = if pretty?, do: Jason.encode!(payload, pretty: true), else: Jason.encode!(payload)

    case out do
      nil ->
        IO.puts(json)

      path ->
        File.write!(path, json)
        Mix.shell().info("Wrote offering metadata to #{path}")
    end
  end

  @doc false
  def build_payload(network, offering \\ :usdc_public) do
    meta = offering_metadata(offering)

    chain_config =
      case network do
        :mainnet ->
          Chain.mainnet()

        :sepolia ->
          Chain.sepolia()

        other ->
          Mix.raise("unknown --network #{inspect(other)}; expected :mainnet or :sepolia")
      end

    %{
      "name" => meta.name,
      "displayName" => meta.display_name,
      "description" => meta.description,
      "requiredFunds" => meta.required_funds,
      "hookKind" => meta.hook_kind,
      "slaMinutes" => meta.sla_minutes,
      "tags" => meta.tags,
      "requirementSchema" => meta.requirement_schema,
      "deliverableSchema" => meta.deliverable_schema,
      "network" => %{
        "name" => chain_config.name,
        "chainId" => chain_config.chain_id,
        "acpCoreAddress" => chain_config.acp_core_address,
        "fundTransferHookAddress" => chain_config.fund_transfer_hook_address,
        "acpServerUrl" => chain_config.acp_server_url
      }
    }
  end

  defp offering_metadata(:legacy), do: Offering.offering_metadata()

  defp offering_metadata(mode) when mode in [:usdc_public, :public, :stealth],
    do: Offering.offering_metadata(mode)

  defp offering_metadata(other),
    do:
      Mix.raise(
        "unknown --offering #{inspect(other)}; expected usdc_public, public, stealth, or legacy"
      )
end
