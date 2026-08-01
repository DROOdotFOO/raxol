defmodule Raxol.Harness.Surface.Golden do
  @moduledoc """
  Byte-golden snapshot matrix for the harness degradation ladder: renders
  each fixed fixture session, end-to-end, through `Raxol.Harness.Surface`
  in each of the three render modes (`:inline_log`, `:tmux_conservative`,
  `:flat`) at fixed geometry, and blesses/checks the raw emitted byte
  stream against a checked-in golden file per fixture x mode pair.

  Mirrors the RATE `--gen` / `Raxol.Harness.Fixture.Bless` precedent one
  layer further down the stack: RATE hashes rendered frames, `Fixture.Bless`
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

  5. **Map iteration order.** This class is closed by the runtime's own
     determinism, not by any tripwire in this module: identical Erlang/
     Elixir maps iterate in identical order within a VM -- map iteration
     order is a deterministic, platform-stable function of the keys alone
     (sorted order for small maps, a fixed-hash HAMT layout above 32
     entries) -- so two renders of the same fixture in the same process
     can never diverge on map-iteration order by itself. What the
     DETERMINISM test in `test/harness/golden_snapshot_test.exs`
     (rendering the same fixture x mode pair TWICE in one test and
     asserting byte equality) actually catches is unseeded randomness,
     process-dictionary or `persistent_term` state leaking between calls,
     and clock leakage -- anything whose value can differ between two
     calls in the SAME VM run. The cross-machine golden comparison (the
     checked-in golden file, compared byte-for-byte across CI runs on
     different machines/VM instances) is the backstop for anything
     environment-shaped that a single-VM determinism test cannot see at
     all.

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

  ## Bless status conventions

  `run/1`'s bless path (`check: false`) deliberately extends
  `Raxol.Harness.Fixture.Bless`'s `:written`/`:current`/`:drift`/`:skipped`
  status convention rather than reusing it verbatim: `:written` is split
  into `:created` (no golden existed on disk yet) and `:overwritten` (a
  golden existed and its bytes changed). A byte-golden clobber overwrites
  the ONLY reviewable record of what a real terminal would receive for
  that fixture x mode pair, so it must be loud at bless time, not just
  visible later in a PR diff of an opaque binary file -- `:overwritten`
  results carry a `GoldenDiff` report of old-vs-new bytes in `:diff` and
  the old size in `:old_bytes`, and the mix task prints both immediately.

  Next to every `<fixture>.<mode>.golden`, bless also (re)writes
  `<fixture>.<mode>.golden.txt`: a line-oriented, `inspect/1`-escaped
  textual rendering of the same bytes (see `escape_lines/1`) that IS
  reviewable in a PR diff, even though the `.golden` file itself is
  marked `binary` in `.gitattributes` (deliberately -- its `\\r\\n` bytes
  are sealed-line protocol bytes, not line endings, and eol-normalizing
  them would corrupt the golden). A missing or stale sidecar is `:drift`
  in `--check` mode, exactly like a missing or stale golden.
  """

  alias Raxol.Harness.Fixture
  alias Raxol.Harness.Surface
  alias Raxol.Harness.Surface.GoldenDiff

  @fixtures ["simple-chat", "multi-tool-turn", "evidence-done"]
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
  `test/fixtures/harness/goldens/simple-chat.inline_log.golden`. Always
  resolved against `goldens_dir/0` -- `run/1`'s internal `:dir` option
  (mirroring `Fixture.Bless.run/1`'s own `:dir` convention) does not
  affect this public helper, which existing tests use to read the
  checked-in goldens directly.
  """
  @spec golden_path(String.t(), Surface.mode()) :: Path.t()
  def golden_path(fixture_name, mode) when is_binary(fixture_name) do
    golden_path(fixture_name, mode, @goldens_dir)
  end

  defp golden_path(fixture_name, mode, dir) do
    Path.join(dir, "#{fixture_name}.#{mode}.golden")
  end

  defp sidecar_path(golden_path), do: golden_path <> ".txt"

  @doc """
  Renders `session_or_name` through the assembled `Raxol.Harness.Surface`
  in `mode`, at this matrix's fixed geometry, and returns the raw emitted
  byte stream. `session_or_name` is either an already-loaded
  `%Raxol.Harness.Fixture.Session{}` or a fixture base name (loaded from
  `test/fixtures/harness/sessions/<name>.jsonl`).

  See the moduledoc's "Determinism audit" for why this is safe to compare
  byte-for-byte across runs/machines: no wall clock, no live environment,
  no capability probe, fixed geometry. The replay loop is bounded (see
  `drive_to_completion/3` / `max_steps/1`) rather than an unbounded
  recursion, so a non-converging `Surface.advance/2` raises loudly instead
  of hanging.
  """
  @spec render(Fixture.Session.t() | String.t(), Surface.mode()) :: binary()
  def render(name, mode) when is_binary(name) do
    render(load_fixture!(name), mode)
  end

  def render(%Fixture.Session{envelopes: envelopes} = session, mode) do
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

    budget = max_steps(length(envelopes))
    _final = drive_to_completion(model, &Surface.advance/1, budget)
    {_in, out} = StringIO.contents(device)
    StringIO.close(device)
    out
  end

  @doc """
  Step budget for `drive_to_completion/3`, given the number of fixture
  events a render will replay.

  Derivation: `Surface.advance/2` reveals at most one additional event per
  call (`revealed = min(revealed + 1, length(events))`), so at most
  `event_count` advances are ever needed to reveal every event. A render
  only reaches `:done` once revealed events AND painted blocks both catch
  up (`painted_count` trails `revealed` by at most one flushed block per
  advance), so the budget doubles `event_count` to also cover those
  painting-catchup advances, plus a flat `32`-step buffer for advances
  that do not correspond to a revealed event at all (the startup footer
  paint, the mode-notice paint, and any other one-shot bookkeeping step).
  """
  @spec max_steps(non_neg_integer()) :: pos_integer()
  def max_steps(event_count)
      when is_integer(event_count) and event_count >= 0 do
    2 * event_count + 32
  end

  # Step-budgeted replacement for what used to be an unbounded recursion:
  # repeatedly calls `advance_fun.(model)` until it returns `{model,
  # :done}`, raising if that never happens within `max_steps` calls. A
  # non-converging `Surface.advance/2` (a malformed fixture, a `Surface`
  # regression that forgets to ever signal `:done`) used to hang every
  # render forever in CI/bless; now it raises immediately, with a message
  # naming the exact step budget so the failure points straight at the
  # non-convergence instead of a silently wedged test run.
  #
  # `@doc false` (public, not `defp`) so the raise path is directly
  # unit-testable with a synthetic `advance_fun` that never converges --
  # see `test/harness/golden_snapshot_test.exs`'s "bounded
  # drive_to_completion" describe. `advance_fun` defaults to
  # `Surface.advance/1` (the arity-1 form of `Surface.advance/2`, `now`
  # defaulting to `nil`) for the production call site in `render/2` above.
  @doc false
  @spec drive_to_completion(
          model,
          (model -> {model, :ok | :done}),
          pos_integer()
        ) :: model
        when model: term()
  def drive_to_completion(model, advance_fun \\ &Surface.advance/1, max_steps)
      when is_function(advance_fun, 1) and is_integer(max_steps) and
             max_steps > 0 do
    drive_step(model, advance_fun, max_steps, 0)
  end

  defp drive_step(_model, _advance_fun, max_steps, steps_taken)
       when steps_taken >= max_steps do
    raise RuntimeError,
      message:
        "Surface.advance/2 never returned :done within #{max_steps} steps -- " <>
          "the surface did not converge; see Golden moduledoc"
  end

  defp drive_step(model, advance_fun, max_steps, steps_taken) do
    case advance_fun.(model) do
      {model, :done} -> model
      {model, :ok} -> drive_step(model, advance_fun, max_steps, steps_taken + 1)
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

  @type status :: :created | :overwritten | :current | :drift

  @type result :: %{
          name: String.t(),
          path: Path.t(),
          bytes: non_neg_integer(),
          status: status(),
          diff: String.t() | nil,
          old_bytes: non_neg_integer() | nil
        }

  @doc """
  Runs the full fixtures x modes matrix.

  Options:

    * `:check` (default `false`) -- when `true`, writes nothing: compares
      each fresh render against its on-disk golden AND its on-disk
      escaped textual sidecar (`<path>.txt`, see `escape_lines/1`),
      reporting `:drift` for either one missing or stale.
    * `:dir` (default `goldens_dir/0`) -- directory holding the golden (+
      sidecar) files, mirroring `Fixture.Bless.run/1`'s own `:dir`
      convention. Exists mainly so error-handling behavior (Fix 4: a
      directory occupying a golden's path) is unit-testable against a
      scratch directory rather than the checked-in one.

  When `:check` is `false` (the bless path): writes a golden that doesn't
  exist yet (status `:created`), overwrites one whose bytes changed
  (status `:overwritten` -- see the moduledoc's "Bless status
  conventions"), or reports `:current` when the freshly rendered bytes
  already match what's on disk (a stale/missing sidecar is silently
  repaired in that case; the pair's status stays `:current` since the
  GOLDEN itself did not change). Sidecar (re)writes always accompany a
  golden create/overwrite.

  Returns `{:ok, [result()]}` when nothing drifted (or, in bless mode,
  always -- writing resolves drift by construction), or `{:error, {:drift,
  names}}` in check mode when one or more fixture x mode pairs drifted,
  where `names` are `"<fixture>.<mode>"` strings.
  """
  @spec run(keyword()) :: {:ok, [result()]} | {:error, {:drift, [String.t()]}}
  def run(opts \\ []) do
    check? = Keyword.get(opts, :check, false)
    dir = Keyword.get(opts, :dir, @goldens_dir)
    File.mkdir_p!(dir)

    results =
      for fixture <- @fixtures, mode <- @modes do
        bless_or_check(fixture, mode, check?, dir)
      end

    drifted = for %{status: :drift, name: name} <- results, do: name

    if drifted == [] do
      {:ok, results}
    else
      {:error, {:drift, drifted}}
    end
  end

  defp bless_or_check(fixture, mode, check?, dir) do
    name = "#{fixture}.#{mode}"
    path = golden_path(fixture, mode, dir)
    rendered = render(fixture, mode)

    {status, diff, old_bytes} =
      if check? do
        check_pair(path, rendered)
      else
        bless_pair(path, rendered)
      end

    %{
      name: name,
      path: path,
      bytes: byte_size(rendered),
      status: status,
      diff: diff,
      old_bytes: old_bytes
    }
  end

  # -- bless (check: false) --------------------------------------------------

  defp bless_pair(path, rendered) do
    case File.read(path) do
      {:ok, ^rendered} ->
        ensure_sidecar_current!(path, rendered)
        {:current, nil, nil}

      {:ok, stale} ->
        diff = diverged_report(stale, rendered)
        File.write!(path, rendered)
        write_sidecar!(path, rendered)
        {:overwritten, diff, byte_size(stale)}

      {:error, :enoent} ->
        File.write!(path, rendered)
        write_sidecar!(path, rendered)
        {:created, nil, nil}

      {:error, reason} ->
        raise "failed to read golden at #{path}: #{reason} " <>
                "(#{:file.format_error(reason)})"
    end
  end

  defp diverged_report(old, new) do
    case GoldenDiff.compare(old, new) do
      :ok -> nil
      {:diverged, _offset, report} -> report
    end
  end

  # -- check (check: true) ----------------------------------------------------

  defp check_pair(path, rendered) do
    case File.read(path) do
      {:ok, golden} ->
        case GoldenDiff.compare(golden, rendered) do
          :ok ->
            check_sidecar(path, rendered)

          {:diverged, _offset, report} ->
            {:drift, report, nil}
        end

      {:error, _reason} ->
        {:drift,
         "golden missing at #{path} -- run `mix raxol.harness.goldens.bless`",
         nil}
    end
  end

  defp check_sidecar(path, rendered) do
    sc_path = sidecar_path(path)

    case File.read(sc_path) do
      {:ok, contents} ->
        if contents == sidecar_contents(path, rendered) do
          {:current, nil, nil}
        else
          {:drift,
           "sidecar at #{sc_path} is stale -- run `mix raxol.harness.goldens.bless`",
           nil}
        end

      {:error, _reason} ->
        {:drift,
         "sidecar missing at #{sc_path} -- run `mix raxol.harness.goldens.bless`",
         nil}
    end
  end

  @doc false
  @spec diff_report(String.t(), Surface.mode(), Path.t()) :: String.t() | nil
  def diff_report(fixture, mode, dir \\ @goldens_dir) do
    path = golden_path(fixture, mode, dir)
    rendered = render(fixture, mode)

    case check_pair(path, rendered) do
      {:current, _diff, _old_bytes} -> nil
      {:drift, diff, _old_bytes} -> diff
    end
  end

  # -- escaped textual sidecar -------------------------------------------------

  defp sidecar_current?(path, rendered) do
    case File.read(sidecar_path(path)) do
      {:ok, contents} -> contents == sidecar_contents(path, rendered)
      {:error, _reason} -> false
    end
  end

  defp ensure_sidecar_current!(path, rendered) do
    unless sidecar_current?(path, rendered) do
      write_sidecar!(path, rendered)
    end

    :ok
  end

  defp write_sidecar!(path, rendered) do
    File.write!(sidecar_path(path), sidecar_contents(path, rendered))
  end

  defp sidecar_contents(path, rendered) do
    sidecar_header(path) <> escape_lines(rendered)
  end

  defp sidecar_header(path) do
    "# escaped sidecar of #{Path.basename(path)} -- regenerated by " <>
      "mix raxol.harness.goldens.bless; do not edit\n"
  end

  @doc """
  Pure, line-oriented, `inspect/1`-escaped textual rendering of a raw
  golden byte stream -- the PR-reviewable form bless writes to
  `<golden path>.txt` next to every byte-opaque `.golden` file.

  `raw` is split into chunks at each `\\n` byte (the newline stays
  attached to the chunk it ends -- a chunk NEVER starts with a leftover
  fragment of the previous line), each chunk is rendered via
  `inspect(chunk, limit: :infinity, printable_limit: :infinity)` (a
  literal Elixir term -- a quoted string or a `<<...>>` binary literal --
  that reproduces the chunk exactly, unabridged), one per line, joined by
  a real `\\n`, with one trailing `\\n`.

  Concatenating the *unescaped* form of every emitted line (each parsed
  back, e.g. via `Code.eval_string/1`) reproduces `raw` byte-for-byte --
  see the round-trip property test in
  `test/harness/golden_snapshot_test.exs`. An empty `raw` produces zero
  escaped lines: just the single trailing `\\n`.
  """
  @spec escape_lines(binary()) :: String.t()
  def escape_lines(raw) when is_binary(raw) do
    raw
    |> chunk_lines()
    |> Enum.map_join(
      "\n",
      &inspect(&1, limit: :infinity, printable_limit: :infinity)
    )
    |> Kernel.<>("\n")
  end

  defp chunk_lines(raw), do: chunk_lines(raw, [])

  defp chunk_lines(<<>>, acc), do: Enum.reverse(acc)

  defp chunk_lines(raw, acc) do
    case :binary.match(raw, "\n") do
      :nomatch ->
        Enum.reverse([raw | acc])

      {pos, _len} ->
        chunk_size = pos + 1
        <<chunk::binary-size(^chunk_size), rest::binary>> = raw
        chunk_lines(rest, [chunk | acc])
    end
  end
end
