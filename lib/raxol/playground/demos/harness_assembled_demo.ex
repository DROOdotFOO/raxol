defmodule Raxol.Playground.Demos.HarnessAssembledDemo do
  @moduledoc """
  Playground demo: the FULLY ASSEMBLED TEA harness (unit U4, spec §7
  `HarnessAssembledDemo`). Boots the real `Raxol.Harness.HarnessApp` model
  over a replayed golden fixture session — the "today's fixture demo,
  playgrounded" of the migration plan — and renders it end-to-end through
  `Raxol.Harness.HarnessApp.View`: windowed transcript blocks sealing into
  history, the fit-law footer with the live composer, and a parked cursor.

  It is the assembled autotest fixture: driven headlessly
  (`Raxol.Headless.start/screenshot/get_buffer/send_key`) it exercises the
  cross-part laws in one place (spec §7 assert placement) —

    * **law 1** sealed-block logical immutability — the whole fixture is
      revealed at boot, each block frozen into a `seal_record`;
    * **law 3** the honest-notice fit law — the footer composes through
      `FooterStack`;
    * **law 6** cursor park — the composer edit point is declared on the
      view root;
    * **law 7** scroll anchor — `TranscriptView` windows the visible slice.

  This is the DETERMINISTIC, fixture-mode half of U4 (the model reveals the
  whole session at `init`, so a headless screenshot is stable without a
  timer). `model.pump` is `nil`: keys drive folds / jumps / the overlay
  picker, while lane-crossing keys (submit / steer / interrupt) fold their
  honest fixture stubs. The live-pump swap (a `SessionPump`-fed run) is the
  U6 follow-up (see `Raxol.Harness.HarnessApp`).
  """

  use Raxol.Core.Runtime.Application
  require Logger

  alias Raxol.Harness.Fixture
  alias Raxol.Harness.HarnessApp.{Model, View}

  @default_fixture "long-folds"
  @sessions_dir "test/fixtures/harness/sessions"

  @impl true
  # `context` may be nil (the totality property drives `init(nil)`); default
  # to an empty map so geometry/fixture lookups stay total.
  def init(context) do
    context = context || %{}
    session = load_fixture(fixture_name(context))

    Model.build(
      events: session,
      width: Map.get(context, :width, 80),
      rows: Map.get(context, :height, 24),
      pump: nil
    )
    |> Model.reveal_all()
  end

  # Keys route through the real harness fold (folds / jumps / scroll / the
  # overlay picker; composer editing while composing). Directives never
  # leave (pump is nil), so `handle_key`'s tuple is threaded straight
  # through — a lane-crossing key simply folds its stub notice.
  @impl true
  def update(%Event{type: :key} = event, model),
    do: Model.handle_key(model, event)

  def update(%Event{type: :resize, data: %{width: w, height: h}}, model),
    do: {Model.resize(model, w, h), []}

  def update(_message, model), do: {model, []}

  @impl true
  def view(model), do: View.render(model)

  @impl true
  def subscribe(_model), do: []

  # ── fixture loading ───────────────────────────────────────────────────

  defp fixture_name(context) do
    context
    |> Map.get(:options, [])
    |> as_keyword()
    |> Keyword.get(:fixture, @default_fixture)
  end

  defp as_keyword(kw) when is_list(kw), do: kw
  defp as_keyword(%{} = m), do: Map.to_list(m)
  defp as_keyword(_), do: []

  # NEVER raises: a demo whose `init/1` raises makes the playground's
  # `select_current` crash, which the Lifecycle swallows -- the model stays
  # unchanged and the entry reads as "Enter does nothing" (it never opens).
  # On any load failure the demo degrades to an empty session so it still
  # opens (an honest empty transcript) rather than becoming un-pickable.
  defp load_fixture(name) do
    case fixture_file(name) do
      nil ->
        Logger.warning(
          "HarnessAssembledDemo: fixture #{name}.jsonl not found; empty session"
        )

        []

      path ->
        case Fixture.load(path) do
          {:ok, session} ->
            session

          {:error, reason} ->
            Logger.warning(
              "HarnessAssembledDemo: fixture #{path} failed (#{inspect(reason)}); empty session"
            )

            []
        end
    end
  end

  # Resolve the golden fixture cwd-INDEPENDENTLY. The fixtures live under the
  # repo's `test/` tree, so a cwd-relative path only resolves when the
  # playground was launched from the repo root -- launch it from anywhere
  # else and the load fails (the "Enter does nothing" report). Try the
  # SOURCE-relative location first (`__DIR__` is the compiled absolute path,
  # so it resolves from any cwd in dev), then the cwd-relative path, then
  # `nil` (a release ships no `test/` -- the empty-session fallback keeps the
  # demo pickable there too).
  defp fixture_file(name) do
    file = name <> ".jsonl"

    [
      Path.expand(Path.join([__DIR__, "..", "..", "..", "..", @sessions_dir, file])),
      Path.join(@sessions_dir, file)
    ]
    |> Enum.find(&File.exists?/1)
  end
end
