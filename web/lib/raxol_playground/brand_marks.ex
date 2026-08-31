defmodule RaxolPlayground.BrandMarks do
  @moduledoc """
  Brand marks for the integrations row, inlined at compile time.

  The SVGs in `priv/brand_marks/` are read here once, reduced to the single
  path each carries, and baked into the module, so a render costs a map lookup
  and the page makes no external request for a logo. `priv/brand_marks/README.md`
  records where they came from, their licence, and why five entries have none.

  The map is keyed by the DISPLAY NAME the row derives, not by file name, so
  the marks answer to the provider registry rather than the other way round.
  An entry with no mark is not an error: `path/1` returns `nil` and the row
  shows its name, which is what a newly added backend does until someone adds
  one. `known/0` exists so a test can hold every key against the derived
  entries and catch a mark that outlives the thing it names.
  """

  @dir Path.expand("../../priv/brand_marks", __DIR__)

  # Display name => file. The mark for "Proton Lumo" is Proton's own: Lumo has
  # no separate mark, and the vendor's is the honest stand-in. OpenAI, VS Code,
  # Grok, LongCat and LLM7 are absent from the source set on purpose and are
  # deliberately not mapped to a near-miss.
  @sources %{
    "Claude" => "claude.svg",
    "Anthropic" => "anthropic.svg",
    "Kimi" => "kimi.svg",
    "OpenRouter" => "openrouter.svg",
    "Proton Lumo" => "proton.svg",
    "Ollama" => "ollama.svg",
    "LM Studio" => "lmstudio.svg",
    "Zed" => "zedindustries.svg",
    "JetBrains" => "jetbrains.svg",
    "neovim" => "neovim.svg",
    "Emacs" => "gnuemacs.svg"
  }

  for file <- Map.values(@sources) do
    @external_resource Path.join(@dir, file)
  end

  # Each source is one 24x24 path. Anything else is a build error rather than a
  # silently half-drawn logo: the renderer inlines this one path and nothing
  # else, so a two-path icon would lose half of itself on the page.
  @marks Map.new(@sources, fn {name, file} ->
           svg = File.read!(Path.join(@dir, file))

           unless String.contains?(svg, ~s(viewBox="0 0 24 24")) do
             raise "#{file} is not a 24x24 mark; the row's sizing assumes that viewBox"
           end

           case Regex.scan(~r/<path[^>]*\sd="([^"]+)"/, svg,
                  capture: :all_but_first
                ) do
             [[d]] ->
               {name, d}

             found ->
               raise "#{file} has #{length(found)} paths; expected exactly 1"
           end
         end)

  @doc """
  The inlined path data for `name`, or `nil` when that entry has no mark.

  `nil` is the ordinary case for an entry whose brand is absent from the source
  set, so callers render the name instead.
  """
  @spec path(String.t()) :: String.t() | nil
  def path(name) when is_binary(name), do: Map.get(@marks, name)

  @doc "Every display name that has a mark. Exposed so a test can check drift."
  @spec known() :: [String.t()]
  def known, do: @marks |> Map.keys() |> Enum.sort()
end
