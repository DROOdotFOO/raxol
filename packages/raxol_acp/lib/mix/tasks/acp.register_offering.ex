defmodule Mix.Tasks.Acp.RegisterOffering do
  @moduledoc """
  Generate the `offering.json` to register on the Virtuals ACP marketplace
  (dashboard "Add Job", or the file uploader).

  The uploader expects a top-level `jobs` array; each element is one offering
  with these fields:

  - `name` -- the offering id (`[a-z][a-z0-9_]*`).
  - `description` -- human-readable summary shown to buyer agents.
  - `price` -- the fee amount for the job, a number in USDC. This is the single
    charge the buyer escrows (the job budget); raxol's runtime reads it as the
    budget it proposes.
  - `priceType` -- `"fixed"` (a flat USDC fee) or `"percentage"` (a commission on
    funds moved through ACP, which requires `requiredFunds: true`).
  - `slaMinutes` -- max minutes from `job.funded` to `job.submitted`.
  - `requiredFunds` -- whether the buyer transfers capital through ACP. `false`
    here: the buyer's funds move via their signed Xochi intent (off-ACP), so the
    fee is a flat `"fixed"` price, not a percentage.
  - `requirement` -- JSON Schema of the buyer's inputs.

  Network/contract addresses and the deliverable schema are NOT part of the
  Virtuals offering document -- they are configured on the agent / in raxol's own
  runtime -- so they are deliberately omitted.

  ## Usage

      mix acp.register_offering                     # usdc_public, stdout
      mix acp.register_offering --offering stealth
      mix acp.register_offering --pretty --out offering.json

  ## Options

  - `--offering` -- which offering to emit: `usdc_public` (default, the launch
    offering `xochi_usdc_public`), `public`, `stealth`, or `legacy` (the
    deprecated token-agnostic `xochi_cross_chain_transfer`).
  - `--out PATH` -- write to a file instead of stdout.
  - `--pretty` -- emit pretty-printed JSON. Default is compact.

  ## Operator workflow

  Paste the output into the Virtuals dashboard (Add Job), or upload the file,
  after registering the agent. NOTE the `jobFee` unit: the dashboard's percentage
  field is in PERCENT (0.08 = 0.08%); if a file-upload path ever reads it as a
  0-1 fraction, `0.08` would mean 8% -- verify the fee reads as 0.08% after import.
  """
  use Mix.Task

  alias Raxol.ACP.Xochi.Offering

  @shortdoc "Generate a Virtuals ACP offering.json"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [offering: :string, out: :string, pretty: :boolean]
      )

    offering = opts |> Keyword.get(:offering, "usdc_public") |> String.to_atom()
    pretty? = Keyword.get(opts, :pretty, false)
    out = Keyword.get(opts, :out)

    payload = build_payload(offering)
    json = if pretty?, do: Jason.encode!(payload, pretty: true), else: Jason.encode!(payload)

    case out do
      nil ->
        IO.puts(json)

      path ->
        File.write!(path, json)
        Mix.shell().info("Wrote offering to #{path}")
    end
  end

  @doc false
  def build_payload(offering \\ :usdc_public) do
    # The Virtuals uploader validates a top-level `jobs` array; the six offering
    # fields are unexpected at the document root and belong to a `jobs` element.
    %{"jobs" => [build_offering(offering)]}
  end

  @doc false
  def build_offering(offering) do
    meta = offering_metadata(offering)

    %{
      "name" => meta.name,
      "description" => meta.description,
      "price" => meta.price_usdc,
      "priceType" => meta.price_type,
      "slaMinutes" => meta.sla_minutes,
      "requiredFunds" => meta.required_funds,
      # Virtuals wants a bare JSON Schema for `requirement`; drop the meta-schema
      # URL so it is not flagged as an unexpected field on import.
      "requirement" => Map.delete(meta.requirement_schema, "$schema")
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
