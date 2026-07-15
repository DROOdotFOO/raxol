# T0 — resolver discrimination fixture suite.
#
# Locks the soundness rules in lib/verdict_resolver_core.exs (see its
# header: measured-inflation, C1∧C2 join, provenance, coherence, transport
# aggregation, two-terminal floor, null-observable, tail-window conjunct,
# idempotence). Every fixture in test/resolver_fixtures/*.json is a
# synthetic t0-verdict.json exercising exactly one rule; the expectations
# table below is the contract.
#
# Usage (plain elixir, no host project needed):
#   elixir scripts/harness/t0/test/resolver_test.exs
# Exit 0 = all pass; exit 1 = at least one assertion failed.

Code.require_file("../lib/verdict_resolver_core.exs", __DIR__)

unless Code.ensure_loaded?(Jason) do
  Mix.install([{:jason, "~> 1.4"}])
end

defmodule T0.ResolverTest do
  @fixtures_dir Path.expand("resolver_fixtures", __DIR__)

  # Each entry: {fixture file, %{output key => expected}}.
  # Keys checked: :dpa, :go, :provisional_dpa (nil = provisional must be nil),
  # :measured, :missing_includes, :malformed_count, :proxy_rows_excluded.
  @expectations [
    {"pending_empty.json",
     %{dpa: "pending", go: "partial", provisional_dpa: nil, measured: []}},
    {"single_terminal_refusal.json",
     %{dpa: "pending", go: "partial", provisional_dpa: nil, measured: ["kitty"]}},
    {"inflation_repro.json",
     %{
       dpa: "pending",
       go: "partial",
       provisional_dpa: nil,
       measured: ["kitty"],
       missing_includes: ["wezterm", "iterm2", "ghostty"]
     }},
    {"provenance_repro.json",
     %{
       dpa: "pending",
       go: "partial",
       provisional_dpa: "B",
       measured: ["ghostty", "iterm2", "wezterm"],
       missing_includes: ["kitty"],
       proxy_rows_excluded: 4
     }},
    {"dpa_b.json",
     %{dpa: "B", go: "go", provisional_dpa: nil, malformed_count: 0}},
    {"dpa_a_no_tail.json", %{dpa: "A", go: "go", provisional_dpa: nil}},
    {"dpa_a_resize.json", %{dpa: "A", go: "go", provisional_dpa: nil}},
    {"dpa_c.json", %{dpa: "C", go: "no_go", provisional_dpa: nil}},
    {"join_repro.json", %{dpa: "C", go: "no_go", provisional_dpa: nil}},
    {"mismatch_repro.json",
     %{
       dpa: "pending",
       go: "partial",
       provisional_dpa: "B",
       missing_includes: ["kitty"],
       malformed_count: 1
     }},
    {"transport_fed_fed.json", %{dpa: "B", go: "go", provisional_dpa: nil}},
    {"transport_fed_lost.json", %{dpa: "C", go: "no_go", provisional_dpa: nil}},
    {"null_observable.json",
     %{
       dpa: "pending",
       go: "partial",
       provisional_dpa: "B",
       missing_includes: ["kitty"],
       malformed_count: 0
     }}
  ]

  def run do
    fixture_failures = Enum.flat_map(@expectations, &check_fixture/1)
    idempotence_failures = check_idempotence("dpa_b.json")
    failures = fixture_failures ++ idempotence_failures

    n_fixture_checks =
      Enum.reduce(@expectations, 0, fn {_f, expect}, acc ->
        acc + map_size(expect)
      end)

    if failures == [] do
      IO.puts(
        "ALL PASS: #{length(@expectations)} fixtures, #{n_fixture_checks} assertions, " <>
          "3 idempotence checks"
      )
    else
      Enum.each(failures, &IO.puts(:stderr, "FAIL: " <> &1))
      IO.puts(:stderr, "#{length(failures)} assertion(s) failed")
      System.halt(1)
    end
  end

  defp check_fixture({file, expect}) do
    result = file |> load_matrix() |> T0.VerdictResolver.resolve()

    Enum.flat_map(expect, fn
      {:dpa, want} ->
        assert_eq(file, "dpa", result.dpa, want)

      {:go, want} ->
        assert_eq(file, "go", result.go, want)

      {:provisional_dpa, nil} ->
        assert_eq(file, "provisional", result.provisional, nil)

      {:provisional_dpa, want} ->
        got = result.provisional && result.provisional.dpa
        assert_eq(file, "provisional.dpa", got, want)

      {:measured, want} ->
        assert_eq(
          file,
          "measured",
          result.tier1_terminals_measured,
          Enum.sort(want)
        )

      {:missing_includes, want} ->
        missing = result.tier1_terminals_missing

        Enum.flat_map(want, fn t ->
          if t in missing,
            do: [],
            else: [
              "#{file}: missing should include #{t}, got #{inspect(missing)}"
            ]
        end)

      {:malformed_count, want} ->
        assert_eq(file, "length(malformed)", length(result.malformed), want)

      {:proxy_rows_excluded, want} ->
        assert_eq(file, "proxy_rows_excluded", result.proxy_rows_excluded, want)
    end)
  end

  # Idempotence / permutation / duplication invariance (addendum #5).
  defp check_idempotence(file) do
    matrix = load_matrix(file)
    baseline = T0.VerdictResolver.resolve(matrix)

    checks = [
      {"resolve twice", T0.VerdictResolver.resolve(matrix)},
      {"row-order permutation",
       T0.VerdictResolver.resolve(Enum.shuffle(matrix))},
      {"duplicated row", T0.VerdictResolver.resolve(matrix ++ [hd(matrix)])}
    ]

    Enum.flat_map(checks, fn {label, got} ->
      if got == baseline,
        do: [],
        else: ["#{file} idempotence (#{label}): output differs from baseline"]
    end)
  end

  defp assert_eq(file, what, got, want) do
    if got == want,
      do: [],
      else: ["#{file}: #{what} = #{inspect(got)}, expected #{inspect(want)}"]
  end

  defp load_matrix(file) do
    @fixtures_dir
    |> Path.join(file)
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("matrix")
  end
end

T0.ResolverTest.run()
