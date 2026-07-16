defmodule T0.RingB.Runner do
  @moduledoc """
  Orchestrates the automated Ring B pass: for every installed, drivable
  terminal, run every automatable claim measurement, write the row via
  `append_result.sh` (so it upserts into `t0-verdict.json` exactly like
  a human's manual Ring B pass would), then run the D-PA resolver and
  return its output.

  Every session this runner opens goes through
  `T0.RingB.Guard.safe_teardown/3` in an `after` block — a measurement
  raising, timing out, or returning an unexpected shape never skips
  teardown, and teardown itself never blocks on a GUI modal (see
  `Guard`'s moduledoc for why that matters).
  """

  alias T0.RingB.Guard
  alias T0.RingB.Measurements

  alias T0.RingB.Drivers.{Iterm2, TerminalApp, Wezterm, Kitty, Ghostty}

  @drivers [Iterm2, TerminalApp, Wezterm, Kitty, Ghostty]

  @doc """
  Runs the full matrix. Returns
  `%{results: [row], resolver: resolver_output_map}`. `t0_root` is the
  absolute path to `scripts/harness/t0` (probes/, append_result.sh,
  verdict_resolver.exs all live there).
  """
  @spec run(String.t()) :: %{results: [map()], resolver: map()}
  def run(t0_root) do
    probes_dir = Path.join(t0_root, "probes")
    evidence_dir = Path.join([t0_root, "capture", "evidence"])
    File.mkdir_p!(evidence_dir)
    # t0_root is .../scripts/harness/t0 — repo root is three levels up.
    repo_root = t0_root |> Path.dirname() |> Path.dirname() |> Path.dirname()

    results =
      @drivers
      |> Enum.flat_map(fn driver ->
        if driver.available?() do
          run_driver(driver, probes_dir, evidence_dir, repo_root)
        else
          [
            %{
              driver: driver.name(),
              skip: true,
              reason: "not installed/drivable in this environment"
            }
          ]
        end
      end)

    resolver = run_resolver(t0_root)

    %{results: results, resolver: resolver}
  end

  defp run_driver(Ghostty, _probes_dir, _evidence_dir, _repo_root) do
    [
      %{
        driver: :ghostty,
        skip: true,
        reason:
          "no get-text/contents/history capture primitive in this Ghostty build's AppleScript " <>
            "dictionary or CLI (confirmed via `sdef`) -- capture is fundamentally unavailable, " <>
            "not merely unattempted. Screenshot-residual: Ring C human-eye pass only."
      }
    ]
  end

  defp run_driver(driver, probes_dir, evidence_dir, repo_root) do
    claims = Measurements.available_claims(driver)

    Enum.map(claims, fn claim ->
      run_one(driver, claim, probes_dir, evidence_dir, repo_root)
    end)
  end

  defp run_one(driver, claim, probes_dir, evidence_dir, repo_root) do
    case driver.spawn_session([]) do
      {:ok, session} ->
        # Generated ONCE here and threaded into `measure/5` via opts, so
        # the marker embedded in the probe's own argv (which
        # `T0.RingB.Measurements.held_cmd/3` builds from
        # `opts[:marker]`) is the EXACT SAME value `Guard.safe_teardown/3`
        # uses for `kill_marker/1` below — previously this function
        # rebuilt an unrelated plain `"ringb-<driver>-<claim>"` string
        # for teardown while `Measurements` generated its own unique
        # marker internally, so `kill_marker/1` never matched the real
        # process (RB review FIX-NOW #2).
        marker = Guard.marker(driver.name(), claim)

        try do
          row = measure(driver, claim, session, probes_dir, marker: marker)
          record(driver, row, evidence_dir, repo_root)
        after
          Guard.safe_teardown(driver, session, marker)
        end

      {:error, reason} ->
        %{
          driver: driver.name(),
          claim: claim,
          skip: true,
          reason: "spawn_session failed: #{inspect(reason)}"
        }
    end
  rescue
    e ->
      %{
        driver: driver.name(),
        claim: claim,
        skip: true,
        reason: "raised: #{Exception.message(e)}"
      }
  end

  defp measure(driver, "C1", session, probes_dir, opts),
    do: Measurements.measure_c1(driver, session, probes_dir, opts)

  defp measure(driver, "C2", session, probes_dir, opts),
    do: Measurements.measure_c2(driver, session, probes_dir, opts)

  defp measure(driver, "C3", session, probes_dir, opts),
    do: Measurements.measure_c3(driver, session, probes_dir, opts)

  defp measure(driver, "C4", session, probes_dir, opts),
    do: Measurements.measure_c4(driver, session, probes_dir, opts)

  defp measure(driver, "N06", session, probes_dir, opts),
    do: Measurements.measure_n06(driver, session, probes_dir, opts)

  defp measure(driver, "N07", session, probes_dir, opts),
    do: Measurements.measure_n07(driver, session, probes_dir, opts)

  defp record(driver, %{skip: true} = row, _evidence_dir, _repo_root) do
    Map.put(row, :driver, driver.name())
  end

  defp record(driver, row, evidence_dir, repo_root) do
    evidence_path =
      Path.join(evidence_dir, "ringb-#{driver.name()}-#{row.claim}.txt")

    File.write!(evidence_path, row.evidence || "")
    rel_evidence = Path.relative_to(evidence_path, repo_root)

    observable_json =
      case row.observable do
        s when is_binary(s) -> s
        m when is_map(m) -> Jason.encode!(m)
      end

    args = [
      to_string(driver.name()),
      "plain",
      "local",
      row.claim,
      row.verdict,
      observable_json,
      driver.capture_method(),
      "scripted",
      rel_evidence,
      row.notes || ""
    ]

    append_script = Path.join(repo_root, "scripts/harness/t0/append_result.sh")

    case System.cmd("bash", [append_script | args], stderr_to_stdout: true) do
      {out, 0} ->
        Map.merge(row, %{
          driver: driver.name(),
          append_result: :ok,
          append_output: String.trim(out)
        })

      {out, code} ->
        Map.merge(row, %{
          driver: driver.name(),
          append_result: {:error, code},
          append_output: String.trim(out)
        })
    end
  end

  defp run_resolver(t0_root) do
    verdict_path = Path.join(t0_root, "t0-verdict.json")
    resolver_script = Path.join(t0_root, "verdict_resolver.exs")

    case System.cmd("elixir", [resolver_script, verdict_path],
           stderr_to_stdout: false
         ) do
      {out, 0} ->
        # A bare `elixir` invocation has no app deps loaded, so the
        # resolver's own `Mix.install([{:jason, ...}])` fallback fires
        # and prints ordinary compile-progress noise ("==> jason\n
        # Compiling...") to stdout BEFORE its one JSON object — slice
        # from the first `{` rather than assuming stdout is pure JSON.
        json_start = :binary.match(out, "{")

        case json_start do
          {pos, _} ->
            case Jason.decode(binary_part(out, pos, byte_size(out) - pos)) do
              {:ok, decoded} ->
                decoded

              {:error, _} ->
                %{"error" => "resolver produced non-JSON output", "raw" => out}
            end

          :nomatch ->
            %{"error" => "resolver produced no JSON object", "raw" => out}
        end

      {out, code} ->
        %{"error" => "resolver exited #{code}", "raw" => out}
    end
  end
end
