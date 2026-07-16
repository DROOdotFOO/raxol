defmodule Mix.Tasks.Raxol.Harness.Goldens.Bless do
  @shortdoc "Regenerate harness degradation-tier golden byte snapshots"

  @moduledoc """
  Runs `Raxol.Harness.Surface.Golden.run/1` over the fixtures x
  degradation-tier matrix, writing one checked-in golden byte file per
  fixture x tier pair (`test/fixtures/harness/goldens/<fixture>.<mode>.golden`).

      mix raxol.harness.goldens.bless
      mix raxol.harness.goldens.bless --check

  `--check` writes nothing: it renders each fixture x mode pair fresh and
  compares the bytes against the on-disk golden AND the on-disk escaped
  textual sidecar (`<golden path>.txt`, see
  `Raxol.Harness.Surface.Golden.escape_lines/1`), printing each drifted
  name plus its formatted byte-diff (offset, sizes, escaped context
  windows on both sides -- see `Raxol.Harness.Surface.GoldenDiff`) and
  failing (non-zero exit) when anything drifted or is missing -- the CI
  half of the drift tripwire.

  A fresh golden is reported as `bless (new)`; an existing golden whose
  bytes changed is reported as `bless (overwrote)` followed immediately
  by the byte-diff against what was previously on disk -- a byte-golden
  clobber must be loud at bless time (see
  `Raxol.Harness.Surface.Golden`'s moduledoc, "Bless status
  conventions").

  Mirrors the FATE `--gen` precedent (`mix raxol.fate --gen`) and the
  `mix raxol.harness.fixtures.bless` precedent one layer further down the
  stack: fixture/session-level snapshots there, raw degradation-ladder
  bytes here. One golden per fixture x degradation tier
  (`:inline_log`/`:tmux_conservative`/`:flat`).
  """

  use Mix.Task

  alias Raxol.Harness.Surface.Golden

  @switches [check: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} = OptionParser.parse(args, switches: @switches)
    check? = opts[:check] || false

    case Golden.run(check: check?) do
      {:ok, results} ->
        Enum.each(results, &report/1)

      {:error, {:drift, drifted}} ->
        Enum.each(drifted, &print_drift/1)

        Mix.raise(
          "harness golden snapshot drift: #{Enum.join(drifted, ", ")} -- " <>
            "run `mix raxol.harness.goldens.bless` and review the diff"
        )
    end
  end

  # `Golden.run/1` reports `{:error, {:drift, names}}` (mirroring
  # `Raxol.Harness.Fixture.Bless.run/1`'s own shape) with just the drifted
  # names, not the per-pair diff text -- recomputed here, directly, via
  # `Golden.diff_report/3`, the same golden-AND-sidecar compare seam
  # `Golden.run/1` itself uses internally (so a sidecar-only drift is
  # reported exactly as loudly as a byte-golden one, with no duplicated
  # comparison logic in this task). `Golden.render/2` is a pure,
  # deterministic re-render (see that module's moduledoc's determinism
  # audit), so recomputing costs one extra render pass per drifted pair,
  # never a behavior difference from what `Golden.run/1` already found.
  defp print_drift(name) do
    Mix.shell().info("drift   #{name}")

    case diff_for(name) do
      nil -> :ok
      diff -> Mix.shell().info(diff)
    end
  end

  defp diff_for(name) do
    {fixture, mode} = split_name(name)
    Golden.diff_report(fixture, mode)
  end

  # `name` is always `"<fixture>.<mode>"`, produced by `Golden.run/1` from
  # this task's own fixed `Golden.fixtures()` x `Golden.modes()` matrix --
  # matched against the known mode list rather than
  # `String.to_atom/1`'d from arbitrary input.
  defp split_name(name) do
    [fixture, mode_str] = String.split(name, ".", parts: 2)
    mode = Enum.find(Golden.modes(), &(to_string(&1) == mode_str))
    {fixture, mode}
  end

  defp report(%{status: :current, name: name}) do
    Mix.shell().info("current #{name}")
  end

  defp report(%{status: :created, name: name, path: path, bytes: bytes}) do
    Mix.shell().info("bless (new)       #{name} -> #{path} (#{bytes} bytes)")
  end

  defp report(%{
         status: :overwritten,
         name: name,
         path: path,
         bytes: bytes,
         old_bytes: old_bytes,
         diff: diff
       }) do
    Mix.shell().info(
      "bless (overwrote) #{name} -> #{path} " <>
        "(was #{old_bytes} bytes, now #{bytes} bytes)"
    )

    if diff, do: Mix.shell().info(diff)
  end
end
