defmodule Raxol.Playground.Demos.HarnessDiffDemo do
  @moduledoc """
  Playground demo: pre-apply diff viewer for a proposed file edit (the
  harness diff block Component, re-hosted per TEA migration section 7).

  Exercises `Raxol.UI.Components.Harness.DiffViewer`'s Pierre-style
  rendering AND its fold vocabulary. The model owns the DiffViewer state
  (controlled, transcript-demo wiring): `[Enter]`/`[Space]` forward into
  the component's real `handle_event/3`, toggling the full Pierre body
  against the compact path-first `± path · +N -M` line.

  `[s]` cycles the fixture corpus (word-diff showcases plus multi-hunk,
  new-file all-adds, no-newline-at-EOF, and unicode content). `[m]`
  cycles auto -> unified -> split. `[w]` toggles the simulated available
  width so `:auto` visibly flips between side-by-side and unified. `[f]`
  toggles hunk folding (`context: 3` <-> `:all`).

  The fold/hunks/sample controls are also real Buttons with stable ids
  (`fold_btn`/`hunks_btn`/`sample_btn`), so the demo derives live MCP
  tools (F0-mcp seam) -- an MCP click and the matching key drive the
  same code path.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.DiffViewer

  @path "lib/orders/total.ex"

  @old_code """
  defmodule Orders.Total do
    @moduledoc "Order total calculation and formatting."

    @vat_rate 0.20

    def format(amount) do
      :erlang.float_to_binary(amount / 1, decimals: 2)
    end

    def currency_symbol(:usd), do: "$"
    def currency_symbol(:eur), do: "€"
    def currency_symbol(:gbp), do: "£"

    def calculate(items) do
      IO.inspect(items, label: "items")

      items
      |> Enum.map(& &1.price)
      |> Enum.sum()
    end

    def with_vat(total) do
      total * (1 + @vat_rate)
    end
  end
  """

  @new_code """
  defmodule Orders.Total do
    @moduledoc "Order total calculation and formatting."

    @vat_rate 0.20

    def format(amount) do
      :erlang.float_to_binary(amount / 1, decimals: 2)
    end

    def currency_symbol(:usd), do: "$"
    def currency_symbol(:eur), do: "€"
    def currency_symbol(:gbp), do: "£"

    def calculate(items) do
      items
      |> Enum.reject(&is_nil(&1.price))
      |> Enum.map(& &1.price)
      |> Enum.filter(&(&1 >= 0))
      |> Enum.sum()
    end

    def with_vat(total) do
      total * (1 + @vat_rate)
    end
  end
  """

  @wide_width 140
  @narrow_width 60

  # Fixture corpus. The first block are diffs.com-style intra-line
  # showcases: each exercises a specific word-diff behavior (replace /
  # add / remove within a line, and the word-alt cluster merge where
  # adjacent changed words separated by a single space fuse into one
  # emphasis span). The tail block is the U1-b contract corpus:
  # multi-hunk, new-file all-adds, and the pathological pair
  # (no-newline-at-EOF, unicode content).
  @samples [
    %{
      name: "refactor + folding",
      path: "lib/orders/total.ex",
      language: "elixir",
      old: nil,
      new: nil
    },
    %{
      name: "within-line replace",
      path: "config/runtime.exs",
      language: "elixir",
      old: """
      config :app, Repo,
        pool_size: 10,
        timeout: 15_000,
        queue_target: 50
      """,
      new: """
      config :app, Repo,
        pool_size: 25,
        timeout: 30_000,
        queue_target: 50
      """
    },
    %{
      name: "within-line add",
      path: "lib/mailer.ex",
      language: "elixir",
      old: """
      def deliver(message) do
        Mailer.send(message)
      end
      """,
      new: """
      def deliver(message, opts \\\\ []) do
        Mailer.send(message, retry: Keyword.get(opts, :retry, 3))
      end
      """
    },
    %{
      name: "within-line remove",
      path: "lib/report.ex",
      language: "elixir",
      old: """
      def build(data, format, verbose, legacy_mode) do
        render(data, format, verbose, legacy_mode)
      end
      """,
      new: """
      def build(data, format) do
        render(data, format)
      end
      """
    },
    %{
      name: "long-line outlier",
      path: "lib/telemetry.ex",
      language: "elixir",
      old: """
      def emit(event) do
        :telemetry.execute([:app, :request], %{count: 1}, %{event: event})
        Logger.debug("emitted " <> inspect(event) <> " with metadata " <> inspect(%{source: :router, retries: 0, budget_ms: 5000, tags: [:hot, :inline]}))
        :ok
      end
      """,
      new: """
      def emit(event) do
        :telemetry.execute([:app, :request], %{count: 1}, %{event: event})
        Logger.debug("emitted " <> inspect(event) <> " with metadata " <> inspect(%{source: :router, retries: 3, budget_ms: 9000, tags: [:hot, :inline]}))
        :done
      end
      """
    },
    %{
      name: "long delete (mid-ellipsis)",
      path: "config/legacy.exs",
      language: "elixir",
      old: """
      config :app, :features,
        legacy_flags: [:a_very_long_flag_name_one, :a_very_long_flag_name_two, :a_very_long_flag_name_three, :a_very_long_flag_name_four, :a_very_long_flag_name_five, :final]
      """,
      new: """
      config :app, :features,
        legacy_flags: []
      """
    },
    %{
      name: "long insert (soft-wrap)",
      path: "lib/router.ex",
      language: "elixir",
      old: """
      def routes do
        []
      end
      """,
      new: """
      def routes do
        [get("/health"), get("/metrics"), post("/api/v1/orders"), post("/api/v1/orders/:id/cancel"), get("/api/v1/orders/:id"), put("/api/v1/orders/:id/address"), delete("/api/v1/orders/:id")]
      end
      """
    },
    %{
      name: "word-alt clusters",
      path: "README.md",
      language: "markdown",
      old: """
      The quick brown fox jumps over the lazy dog.
      Deploys run every night at midnight UTC.
      """,
      new: """
      The slow gray fox walks around the lazy dog.
      Deploys run each morning at dawn UTC.
      """
    },
    %{
      name: "multi-hunk",
      path: "lib/pipeline.ex",
      language: "elixir",
      old: """
      defmodule Pipeline do
        def stage_one(x) do
          x + 1
        end

        # spacer 1
        # spacer 2
        # spacer 3
        # spacer 4
        # spacer 5
        # spacer 6
        # spacer 7
        # spacer 8

        def stage_two(x) do
          x * 2
        end
      end
      """,
      new: """
      defmodule Pipeline do
        def stage_one(x) do
          x + 10
        end

        # spacer 1
        # spacer 2
        # spacer 3
        # spacer 4
        # spacer 5
        # spacer 6
        # spacer 7
        # spacer 8

        def stage_two(x) do
          x * 20
        end
      end
      """
    },
    %{
      name: "new file (all adds)",
      path: "lib/brand_new.ex",
      language: "elixir",
      old: "",
      new: """
      defmodule BrandNew do
        def hello, do: :world
      end
      """
    },
    %{
      name: "no newline at EOF",
      path: "NOTES",
      language: nil,
      old: "alpha\nomega",
      new: "alpha\nomega!\n"
    },
    %{
      name: "unicode content",
      path: "docs/i18n.md",
      language: nil,
      old: """
      greeting: hello
      width: single
      """,
      new: """
      greeting: こんにちは世界
      width: 双幅文字テスト
      """
    }
  ]

  @impl true
  def init(_context) do
    %{diff: init_diff(sample_at(0), mode: :auto, width: @wide_width), sample: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      :toggle_fold -> {toggle_fold(model), []}
      :toggle_hunks -> {toggle_hunks(model), []}
      :next_sample -> {next_sample(model), []}
      key_match("m") -> {cycle_mode(model), []}
      key_match("w") -> {toggle_width(model), []}
      key_match("f") -> {toggle_hunks(model), []}
      key_match("s") -> {next_sample(model), []}
      %Event{type: :key} = event -> {forward_to_diff(model, event), []}
      _ -> {model, []}
    end
  end

  # The MCP button and the physical Enter key drive the SAME component
  # code: the button forwards a synthetic Enter through the DiffViewer's
  # real handle_event/3, so there is exactly one fold-toggle authority.
  defp toggle_fold(model),
    do: forward_to_diff(model, Event.new(:key, %{key: :enter}))

  defp forward_to_diff(model, event) do
    {diff, _commands} = DiffViewer.handle_event(event, model.diff, %{})
    %{model | diff: diff}
  end

  defp toggle_hunks(model),
    do: %{
      model
      | diff: %{model.diff | context: toggle_context(model.diff.context)}
    }

  defp cycle_mode(model),
    do: %{model | diff: %{model.diff | mode: next_mode(model.diff.mode)}}

  defp toggle_width(model),
    do: %{model | diff: %{model.diff | width: next_width(model.diff.width)}}

  # A new sample is a new artifact: carry the viewing knobs
  # (mode/width/context) over, reset the fold to expanded.
  defp next_sample(model) do
    index = rem(model.sample + 1, length(@samples))

    diff =
      init_diff(sample_at(index),
        mode: model.diff.mode,
        width: model.diff.width,
        context: model.diff.context
      )

    %{model | diff: diff, sample: index}
  end

  defp init_diff(sample, opts) do
    {:ok, diff} =
      DiffViewer.init(
        id: "harness_diff",
        path: sample.path,
        old: sample.old,
        new: sample.new,
        language: sample.language,
        mode: Keyword.get(opts, :mode, :auto),
        width: Keyword.get(opts, :width, @wide_width),
        context: Keyword.get(opts, :context, 3)
      )

    diff
  end

  defp next_mode(:auto), do: :unified
  defp next_mode(:unified), do: :split
  defp next_mode(:split), do: :auto

  defp next_width(@wide_width), do: @narrow_width
  defp next_width(@narrow_width), do: @wide_width

  defp toggle_context(:all), do: 3
  defp toggle_context(_context), do: :all

  # The first sample keeps the big module-level refactor (module attrs so
  # the heredocs read naturally at the top of the file).
  defp sample_at(0) do
    %{
      name: "refactor + folding",
      path: @path,
      language: "elixir",
      old: @old_code,
      new: @new_code
    }
  end

  defp sample_at(index), do: Enum.at(@samples, index)

  @impl true
  def view(model) do
    sample = sample_at(model.sample)
    effective = DiffViewer.effective_mode(model.diff, %{})
    fold_word = if model.diff.folded, do: "folded", else: "expanded"

    column style: %{gap: 1} do
      [
        text("Harness Diff Viewer Demo (Pierre-style)", style: [:bold]),
        row style: %{gap: 2} do
          [
            button("Fold [Enter]", id: "fold_btn", on_click: :toggle_fold),
            button("Hunks [f]", id: "hunks_btn", on_click: :toggle_hunks),
            button("Sample [s]", id: "sample_btn", on_click: :next_sample)
          ]
        end,
        divider(),
        DiffViewer.render(model.diff, %{}),
        divider(),
        text(
          "Sample: #{sample.name} (#{model.sample + 1}/#{length(@samples)})  |  " <>
            "Mode: #{model.diff.mode} (rendering: #{effective})  |  " <>
            "Width: #{model.diff.width}  |  Fold: #{fold_word}  |  " <>
            "Hunks: #{model.diff.context}",
          id: "diff_status",
          style: [:dim]
        ),
        text(
          "[Enter/Space] fold  [s] next sample  [m] cycle mode  " <>
            "[w] toggle width  [f] toggle hunk folding",
          style: [:dim]
        )
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end
