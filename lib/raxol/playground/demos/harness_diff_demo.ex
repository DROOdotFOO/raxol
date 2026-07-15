defmodule Raxol.Playground.Demos.HarnessDiffDemo do
  @moduledoc """
  Playground demo: pre-apply diff viewer for a proposed file edit.

  Exercises `Raxol.UI.Components.Harness.DiffViewer`'s Pierre-style
  rendering with a realistic before/after edit -- syntax-highlighted
  Elixir, a long unchanged run (so hunk folding visibly kicks in with the
  default `context: 3`), a couple of lines removed, a couple added.

  `[m]` cycles auto -> unified -> split. `[w]` toggles the simulated
  available width so `:auto` visibly flips between side-by-side (wide)
  and unified (narrow). `[f]` toggles folding: `context: 3` <-> `:all`.
  """
  use Raxol.Core.Runtime.Application

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

  # diffs.com-style intra-line showcase samples: each one exercises a
  # specific word-diff behavior (replace / add / remove within a line,
  # and the word-alt cluster merge where adjacent changed words separated
  # by a single space fuse into one emphasis span).
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
    }
  ]

  @impl true
  def init(_context) do
    %{mode: :auto, width: @wide_width, context: 3, sample: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("m") -> {%{model | mode: cycle_mode(model.mode)}, []}
      key_match("w") -> {%{model | width: toggle_width(model.width)}, []}
      key_match("f") -> {%{model | context: toggle_context(model.context)}, []}
      key_match("s") -> {%{model | sample: next_sample(model.sample)}, []}
      _ -> {model, []}
    end
  end

  defp cycle_mode(:auto), do: :unified
  defp cycle_mode(:unified), do: :split
  defp cycle_mode(:split), do: :auto

  defp toggle_width(@wide_width), do: @narrow_width
  defp toggle_width(@narrow_width), do: @wide_width

  defp toggle_context(:all), do: 3
  defp toggle_context(_context), do: :all

  defp next_sample(index), do: rem(index + 1, length(@samples))

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

    {:ok, diff_state} =
      DiffViewer.init(
        path: sample.path,
        old: sample.old,
        new: sample.new,
        mode: model.mode,
        width: model.width,
        language: sample.language,
        context: model.context
      )

    effective = DiffViewer.effective_mode(diff_state, %{})

    column style: %{gap: 1} do
      [
        text("Harness Diff Viewer Demo (Pierre-style)", style: [:bold]),
        divider(),
        DiffViewer.render(diff_state, %{}),
        divider(),
        text(
          "Sample: #{sample.name} (#{model.sample + 1}/#{length(@samples)})  |  " <>
            "Mode: #{model.mode} (rendering: #{effective})  |  " <>
            "Width: #{model.width}  |  Fold: #{model.context}",
          style: [:dim]
        ),
        text(
          "[s] next sample  [m] cycle mode  [w] toggle width  [f] toggle fold",
          style: [:dim]
        )
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end
