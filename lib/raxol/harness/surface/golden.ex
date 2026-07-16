defmodule Raxol.Harness.Surface.Golden do
  @moduledoc """
  Byte-golden snapshot matrix for the harness degradation ladder: renders
  each fixed fixture session, end-to-end, through `Raxol.Harness.Surface`
  in each of the three render modes (`:inline_log`, `:tmux_conservative`,
  `:flat`) at fixed geometry, and blesses/checks the raw emitted byte
  stream against a checked-in golden file per fixture x mode pair.

  Mirrors the FATE `--gen` / `Raxol.Harness.Fixture.Bless` precedent one
  layer further down the stack: FATE hashes rendered frames, `Fixture.Bless`
  snapshots the journal-fold projection, and this module snapshots the raw
  *bytes* a real terminal would receive -- the level below both, where a
  degradation-tier regression (a stray `\\e[2J`, a footer bleed, a changed
  cursor dance) shows up as a literal byte diff rather than a semantic one.

  ## Determinism audit

  Every render in this matrix must be byte-identical run over run, VM over
  VM, machine over machine -- otherwise "golden" is a lie. Five potential
  sources of nondeterminism, and why each is closed:

  1. **Time.** `render/2` drives `Surface.advance/2` in a loop and NEVER
     passes a `now` (see `render/2` below -- the loop always calls
     `Surface.advance(model)`, arity 1, defaulting `now` to `nil`). The
     status strip's elapsed-ticker values derive solely from fixture event
     `ts` fields, never a live clock: `Raxol.Harness.StatusStrip`'s own
     moduledoc ("The elapsed ticker and R11 (no wall-clock in the default
     suite)") documents that `render/2` never calls
     `System.monotonic_time/1` or any wall-clock function -- elapsed is a
     pure subtraction of two caller-supplied integers. `StallDetector`'s
     notion of time is likewise caller-owned and is never fed into this
     render path at all (this module never touches `StallDetector`).

  2. **Environment.** An explicit `:mode` option to `Surface.new/2` bypasses
     `ModeSelect.select_with_reason/3` entirely (see that function's own
     "test seam" doc) -- no `System.get_env/0` snapshot, no tty/CI
     detection, and no startup mode notice varies run to run. `render/2`
     always passes an explicit `:mode` and `env: %{}` anyway, as hygiene:
     even though the explicit mode makes `env` dead for mode-pick purposes,
     passing a fixed empty map rather than `System.get_env/0` means no
     accidental future code path in `Surface.new/2` could reach into a
     live, machine-dependent environment map.

  3. **Capabilities.** `render/2` always passes `capabilities: nil`
     explicitly. `nil` means neither `Raxol.Terminal.Capabilities.cached/0`
     (a `persistent_term`-backed, machine-dependent probe) nor any `$TERM`
     sniffing ever reaches the byte stream -- every render in this matrix
     is built from the same, fully-specified capability record (none).
     `nil` is also exactly the conservative clamp `:tmux_conservative`
     itself assumes (see `ModeSelect`'s moduledoc: the capability ladder
     clamps for a detected multiplexer before the record ever reaches
     `InlineAuthority.new/5`), so `:tmux_conservative`'s golden renders
     with precisely the capabilities the real ladder would hand it for an
     un-probed/conservative terminal.

  4. **Geometry.** Fixed at `#{inspect(width: 60, rows: 20, footer_rows: 6)}`
     for every fixture x mode pair -- the exact geometry
     `test/harness/t13a_surface_test.exs` already uses for its own
     end-to-end assertions, so this matrix's byte streams are directly
     comparable to that suite's documented behavior.

  5. **Map iteration order.** No code on this render path is known to let
     Erlang/Elixir map iteration order leak into the byte stream (JSON
     payloads are decoded into maps but never re-serialized on this path;
     `Enum.map`/`Enum.reduce` calls throughout `Surface` and its
     collaborators walk lists, not maps, wherever ordering matters for
     output). This is not provable in the abstract, so it is pinned
     mechanically two ways instead: the DETERMINISM test in
     `test/harness/golden_snapshot_test.exs` renders the same fixture x
     mode pair TWICE in one test and asserts byte equality (catches
     iteration-order or other hidden-state nondeterminism within a single
     VM run), and the golden file itself, checked in and compared byte-for-
     byte across CI runs on different machines/VM instances, is the
     cross-run half of the same tripwire.

  ## `:tmux_conservative` vs `:inline_log`

  Per `ModeSelect`'s own moduledoc, there is no separate
  `TmuxConservativeAuthority` -- `:tmux_conservative` routes through the
  exact same `InlineAuthority` as `:inline_log` (the reflow seam is
  detection-only today). So the `:tmux_conservative` golden for a given
  fixture MAY be byte-identical to that fixture's `:inline_log` golden,
  today. Each tier still gets its own pinned golden file rather than being
  aliased or skipped, so that the day a real rendering difference gates on
  tier (a transient-region algorithm, a capability clamp that changes
  emitted bytes), the two tiers can diverge independently without this
  matrix needing to be restructured.
  """

  alias Raxol.Harness.Fixture
  alias Raxol.Harness.Surface
  alias Raxol.Harness.Surface.GoldenDiff

  @fixtures ["simple-chat", "multi-tool-turn"]
  @modes [:inline_log, :tmux_conservative, :flat]

  @width 60
  @rows 20
  @footer_rows 6

  @fixtures_dir Path.join(["test", "fixtures", "harness", "sessions"])
  @goldens_dir Path.join(["test", "fixtures", "harness", "goldens"])

  @doc "The fixture base names this matrix covers (see the moduledoc)."
  @spec fixtures() :: [String.t()]
  def fixtures, do: @fixtures

  @doc "The degradation-ladder tiers this matrix covers (see the moduledoc)."
  @spec modes() :: [Surface.mode()]
  def modes, do: @modes

  @doc "Directory holding the checked-in golden byte files."
  @spec goldens_dir() :: Path.t()
  def goldens_dir, do: @goldens_dir

  @doc """
  The on-disk path for a fixture x mode pair's golden file, e.g.
  `test/fixtures/harness/goldens/simple-chat.inline_log.golden`.
  """
  @spec golden_path(String.t(), Surface.mode()) :: Path.t()
  def golden_path(fixture_name, mode) when is_binary(fixture_name) do
    Path.join(@goldens_dir, "#{fixture_name}.#{mode}.golden")
  end

  @doc """
  Renders `session_or_name` through the assembled `Raxol.Harness.Surface`
  in `mode`, at this matrix's fixed geometry, and returns the raw emitted
  byte stream. `session_or_name` is either an already-loaded
  `%Raxol.Harness.Fixture.Session{}` or a fixture base name (loaded from
  `test/fixtures/harness/sessions/<name>.jsonl`).

  See the moduledoc's "Determinism audit" for why this is safe to compare
  byte-for-byte across runs/machines: no wall clock, no live environment,
  no capability probe, fixed geometry.
  """
  @spec render(Fixture.Session.t() | String.t(), Surface.mode()) :: binary()
  def render(name, mode) when is_binary(name) do
    render(load_fixture!(name), mode)
  end

  def render(%Fixture.Session{} = session, mode) do
    {:ok, device} = StringIO.open("")

    model =
      Surface.new(session,
        device: device,
        width: @width,
        rows: @rows,
        footer_rows: @footer_rows,
        mode: mode,
        env: %{},
        capabilities: nil
      )

    _final = drive_to_completion(model)
    {_in, out} = StringIO.contents(device)
    out
  end

  defp drive_to_completion(model) do
    case Surface.advance(model) do
      {model, :done} -> model
      {model, :ok} -> drive_to_completion(model)
    end
  end

  defp load_fixture!(name) do
    path = Path.join(@fixtures_dir, "#{name}.jsonl")

    case Fixture.load(path) do
      {:ok, session} ->
        session

      {:error, reason} ->
        raise "failed to load fixture #{name}: #{inspect(reason)}"
    end
  end

  @type status :: :written | :current | :drift

  @type result :: %{
          name: String.t(),
          path: Path.t(),
          bytes: non_neg_integer(),
          status: status(),
          diff: String.t() | nil
        }

  @doc """
  Runs the full fixtures x modes matrix.

  Options:

    * `:check` (default `false`) -- when `true`, writes nothing: compares
      each fresh render against its on-disk golden and reports `:drift`
      for anything missing or byte-mismatched. When `false` (the bless
      path), writes each golden (status `:written`), or reports `:current`
      when the freshly rendered bytes are already byte-identical to what's
      on disk (so re-running bless with no rendering changes is a no-op
      write-wise).

  Returns `{:ok, [result()]}` when nothing drifted (or, in bless mode,
  always -- writing resolves drift by construction), or `{:error, {:drift,
  names}}` in check mode when one or more fixture x mode pairs drifted,
  where `names` are `"<fixture>.<mode>"` strings.
  """
  @spec run(keyword()) :: {:ok, [result()]} | {:error, {:drift, [String.t()]}}
  def run(opts \\ []) do
    check? = Keyword.get(opts, :check, false)
    File.mkdir_p!(@goldens_dir)

    results =
      for fixture <- @fixtures, mode <- @modes do
        bless_or_check(fixture, mode, check?)
      end

    drifted = for %{status: :drift, name: name} <- results, do: name

    if drifted == [] do
      {:ok, results}
    else
      {:error, {:drift, drifted}}
    end
  end

  defp bless_or_check(fixture, mode, check?) do
    name = "#{fixture}.#{mode}"
    path = golden_path(fixture, mode)
    rendered = render(fixture, mode)

    {status, diff} = compare_or_write(path, rendered, check?)

    %{
      name: name,
      path: path,
      bytes: byte_size(rendered),
      status: status,
      diff: diff
    }
  end

  defp compare_or_write(path, rendered, false) do
    case File.read(path) do
      {:ok, ^rendered} ->
        {:current, nil}

      _missing_or_stale ->
        File.write!(path, rendered)
        {:written, nil}
    end
  end

  defp compare_or_write(path, rendered, true) do
    case File.read(path) do
      {:ok, golden} ->
        case GoldenDiff.compare(golden, rendered) do
          :ok -> {:current, nil}
          {:diverged, _offset, report} -> {:drift, report}
        end

      {:error, _reason} ->
        {:drift,
         "golden missing at #{path} -- run `mix raxol.harness.goldens.bless`"}
    end
  end
end
