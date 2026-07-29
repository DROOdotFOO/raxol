defmodule Raxol.ACP.Console.AgentOffering do
  @moduledoc """
  `custom_console_agent` — a validated, deployment-ready Virtuals Console agent
  package, sold as a **plain job** (`requiredFunds: false`, `hook =
  address(0)`): zero liquidity, no principal at risk on either side.

  The buyer sends a spec (purpose, runtime, persona, scheduled tasks, skills);
  the deliverable is a `soul.md` + `tasks.json` (+ `AGENTS.md`, `skills/`)
  package targeting **Hermes** or **OpenClaw**, statically validated and — by
  default — bench-validated on the actual open-source runtime, with the
  transcript shipped as evidence. The buyer's side of delivery is the
  three-click *Deploy Instance* redeploy on their own Console dashboard
  (instructions bundled in the package).

  ## Lifecycle mapping

  - `handle_request/2` — fail-closed pre-escrow gate: `Spec.validate/1`
    (schema + content policy) then, for `bench_validated` jobs, a
    `BenchSlots.reserve/1` so we never accept more concurrent bench work than
    the SLA can absorb. Typed rejects: `{:invalid_requirement, field, detail}`,
    `{:denied_purpose, term}`, `:at_bench_capacity`,
    `{:error, :bench_unavailable}` (slots process not running — configuration
    error, fail closed).
  - `handle_deliver/2` — delegates to `Raxol.ACP.Console.Delivery.run/2`
    (generate → validate → bench → package → store), releasing the slot in
    `after` on every path.

  Flat `price_usdc` for v1; dynamic sizing moves into `resolve_accept/2` once
  the fixed-price E2E is proven (DESIGN.md §7).

  ## Enabling

      config :raxol_acp,
        seller_enabled: true,
        offerings: [Raxol.ACP.Console.AgentOffering],
        console_artifact_store: [module: ..., dir: ..., base_url: ...],
        console_inference: [api_key: {:system, "VIRTUALS_API_KEY"}],
        console_bench: [hermes: [cmd: {"/opt/raxol/bench/hermes.sh", []}]]

  `Seller.Supervisor` starts `BenchSlots` automatically when this module is in
  `:offerings`. Emit the marketplace document with
  `mix acp.register_offering --offering console`.
  """

  use Raxol.ACP.Offering,
    name: "custom_console_agent",
    price_usdc: 10,
    sla_minutes: 60,
    cluster: "software"

  alias Raxol.ACP.Console.{BenchSlots, Delivery, Spec}

  @impl true
  def requirements_schema, do: Spec.requirement_schema()

  @impl true
  def deliverables_schema do
    %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "type" => "object",
      "required" => ["package_tarball_url", "sha256", "manifest"],
      "properties" => %{
        "package_tarball_url" => %{"type" => "string"},
        "sha256" => %{"type" => "string", "pattern" => "^[0-9a-f]{64}$"},
        "manifest" => %{
          "type" => "object",
          "properties" => %{
            "runtime" => %{"type" => "string", "enum" => ["hermes", "openclaw", "raxol"]},
            "files" => %{"type" => "array", "items" => %{"type" => "string"}}
          }
        },
        "deploy_instructions_url" => %{"type" => "string"},
        "validation_report_url" => %{"type" => "string"},
        "evidence" => %{
          "type" => ["object", "null"],
          "properties" => %{
            "bench_transcript_url" => %{"type" => "string"},
            "checks" => %{"type" => "array", "items" => %{"type" => "string"}}
          }
        }
      }
    }
  end

  @impl true
  def handle_request(request, ctx) do
    with {:ok, spec} <- Spec.validate(request),
         :ok <- reserve_bench(spec, ctx.job_id) do
      {:accept, request}
    else
      {:error, reason} -> {:reject, reason}
    end
  end

  @impl true
  def handle_deliver(request, ctx), do: Delivery.run(request, ctx)

  # An accepted job that never delivers (rejected after accept, or expired) must
  # give its bench slot back here -- otherwise the pre-escrow reservation leaks
  # until the TTL sweep. Idempotent, and a no-op for package_only jobs.
  @impl true
  def handle_release(_request, ctx), do: BenchSlots.release(ctx.job_id)

  defp reserve_bench(%Spec{validation: :package_only}, _job_id), do: :ok
  defp reserve_bench(%Spec{validation: :bench_validated}, job_id), do: bench_result(job_id)

  defp bench_result(job_id) do
    case BenchSlots.reserve(job_id) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
