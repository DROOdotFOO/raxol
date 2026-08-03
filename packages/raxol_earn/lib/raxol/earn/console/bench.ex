defmodule Raxol.Earn.Console.Bench do
  @moduledoc """
  Bench seam: run a generated package against a real agent runtime and return
  evidence, or a typed failure that blocks delivery.

  Both Console runtimes (Hermes, OpenClaw) are open source, so the SLA-path
  bench does **not** touch the hosted Console at all: `Bench.Local` boots the
  actual runtime on this machine against the materialized package — the same
  artifacts the Console's Deploy Instance flow consumes — which keeps
  `bench_validated` delivery fully autonomous (no dashboard auth, no per-job
  hosting). Redeploying a hosted bench Console agent remains an
  operator-assisted extra, outside the SLA path (DESIGN.md §7 R1).

  Evidence shape: `%{checks: [{:boot | :prompt | :task_dry_run, :ok}],
  transcript: binary()}` — the transcript is uploaded next to the tarball and
  linked from the deliverable.

  `Bench.Mock` (tests) returns `config :raxol_earn, :console_bench_mock`
  verbatim, defaulting to a passing three-check result.
  """

  @type evidence :: %{checks: [{atom(), :ok}], transcript: binary()}

  @callback run(pkg_dir :: Path.t(), spec :: Raxol.Earn.Console.Spec.t()) ::
              {:ok, evidence()} | {:error, term()}

  @doc "Run the configured bench module (`config :raxol_earn, :console_bench_module`)."
  @spec run(Path.t(), Raxol.Earn.Console.Spec.t()) :: {:ok, evidence()} | {:error, term()}
  def run(pkg_dir, spec) do
    module = Application.get_env(:raxol_earn, :console_bench_module, __MODULE__.Local)
    module.run(pkg_dir, spec)
  end

  defmodule Mock do
    @moduledoc false
    @behaviour Raxol.Earn.Console.Bench

    @impl true
    def run(_pkg_dir, _spec) do
      Application.get_env(
        :raxol_earn,
        :console_bench_mock,
        {:ok,
         %{
           checks: [boot: :ok, prompt: :ok, task_dry_run: :ok],
           transcript: "mock bench: boot ok / prompt ok / task dry-run ok\n"
         }}
      )
    end
  end
end
