defmodule Raxol.Earn.Console.Delivery do
  @moduledoc """
  The `handle_deliver/2` pipeline for `custom_console_agent`:

      re-validate request → generate → static validate → materialize →
      bench (when :bench_validated) → tar.gz → store artifacts → deliverable

  Stateless by design: the accepted request map is the only input, so a resync
  after a crash replays the same pipeline; the artifact path is
  `job_id`-deterministic, and the JobSession checkpoint (DESIGN.md §5) stores
  the computed deliverable + hash before the on-chain submit, so generation
  nondeterminism can never yield two different submits for one job. The bench
  slot reserved at accept time is released — and the scratch dir removed — in
  an `after` clause on every path.

  Every failure is a typed `{:error, reason}`, surfaced by the Queue as
  `{:handler_error, reason}` telemetry.
  """

  alias Raxol.Earn.Console.{ArtifactStore, Bench, BenchSlots, Generator, Spec, Validator}

  @doc "Run the full delivery pipeline. Returns `{:deliver, map}` or `{:error, term}`."
  @spec run(map(), %{:job_id => binary(), optional(atom()) => any()}) ::
          {:deliver, map()} | {:error, term()}
  def run(request, %{job_id: job_id}) do
    with {:ok, spec} <- Spec.validate(request),
         {:ok, pkg} <- Generator.generate(spec, job_id),
         {:ok, report} <- Validator.validate(pkg),
         {:ok, dir} <- materialize(pkg, job_id) do
      try do
        with {:ok, evidence} <- maybe_bench(dir, spec),
             {:ok, tarball} <- tar(dir, pkg),
             sha = sha256(tarball),
             {:ok, tar_url} <- ArtifactStore.put(job_id, "package.tar.gz", tarball),
             {:ok, report_url} <-
               ArtifactStore.put(job_id, "validation_report.json", report_json(report)),
             {:ok, evidence_url} <- put_evidence(job_id, evidence),
             {:ok, instructions_url} <-
               ArtifactStore.put(
                 job_id,
                 "deploy_instructions.md",
                 Map.fetch!(pkg.files, "deploy_instructions.md")
               ) do
          {:deliver,
           %{
             "package_tarball_url" => tar_url,
             "sha256" => sha,
             "manifest" => %{
               "runtime" => Atom.to_string(pkg.runtime),
               "files" => pkg.files |> Map.keys() |> Enum.sort()
             },
             "deploy_instructions_url" => instructions_url,
             "validation_report_url" => report_url,
             "evidence" => evidence_field(evidence, evidence_url)
           }}
        end
      after
        BenchSlots.release(job_id)
        File.rm_rf(dir)
      end
    end
  end

  # -- pipeline steps --------------------------------------------------------

  defp materialize(%{files: files}, job_id) do
    dir = Path.join(System.tmp_dir!(), "raxol_console_" <> sanitize(job_id))
    _ = File.rm_rf(dir)

    Enum.reduce_while(files, {:ok, dir}, fn {rel, bytes}, {:ok, dir} ->
      path = Path.join(dir, rel)

      # Enforce that every key stays inside `dir`. The Generator already
      # constrains its own keys, but materialize is the actual filesystem write,
      # so it fails closed on any `..`/absolute path from any source rather than
      # trusting the caller (defense in depth against a package-slip escape).
      cond do
        not safe_rel?(rel) ->
          {:halt, {:error, {:unsafe_path, rel}}}

        true ->
          with :ok <- File.mkdir_p(Path.dirname(path)),
               :ok <- File.write(path, bytes) do
            {:cont, {:ok, dir}}
          else
            {:error, reason} -> {:halt, {:error, {:materialize, rel, reason}}}
          end
      end
    end)
  end

  # A package-relative path is safe only when it is a non-empty, relative path
  # with no `..` segment -- so `Path.join(dir, rel)` can never escape `dir`.
  defp safe_rel?(rel) do
    rel = to_string(rel)
    rel != "" and not String.starts_with?(rel, "/") and ".." not in Path.split(rel)
  end

  defp maybe_bench(_dir, %Spec{validation: :package_only}), do: {:ok, nil}
  defp maybe_bench(dir, %Spec{validation: :bench_validated} = spec), do: Bench.run(dir, spec)

  defp tar(dir, %{files: files}) do
    out = dir <> ".tar.gz"

    entries =
      files
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn rel -> {to_charlist(rel), to_charlist(Path.join(dir, rel))} end)

    case :erl_tar.create(to_charlist(out), entries, [:compressed]) do
      :ok ->
        bytes = File.read!(out)
        File.rm(out)
        {:ok, bytes}

      {:error, reason} ->
        {:error, {:tar, reason}}
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp put_evidence(_job_id, nil), do: {:ok, nil}

  defp put_evidence(job_id, %{transcript: transcript}),
    do: ArtifactStore.put(job_id, "bench_transcript.txt", transcript)

  defp evidence_field(nil, _url), do: nil

  defp evidence_field(%{checks: checks}, url),
    do: %{
      "bench_transcript_url" => url,
      "checks" => Enum.map(checks, fn {c, :ok} -> Atom.to_string(c) end)
    }

  defp report_json(report),
    do:
      Jason.encode!(%{"static_checks" => Enum.map(report, fn {c, :ok} -> Atom.to_string(c) end)})

  defp sanitize(job_id), do: String.replace(to_string(job_id), ~r/[^A-Za-z0-9_.-]/, "_")
end
