defmodule RaxolPlaygroundWeb.Playground.Helpers do
  @moduledoc """
  Helper functions for the Raxol playground web UI.
  Single source of truth for themes, SSH callout, and shared constants.
  """

  alias RaxolPlayground.Capabilities

  @default_theme :synthwave84

  @doc "Returns the default terminal theme atom."
  def default_theme, do: @default_theme

  @doc """
  The hosted SSH command, or `nil` when that surface is not serving.

  Delegates to `RaxolPlayground.Capabilities`, which owns the string and the
  availability gate, so the page and the capability manifest cannot disagree
  about whether SSH is offered.
  """
  def ssh_command, do: Capabilities.ssh_command()

  @doc "Whether the hosted SSH playground is configured to serve."
  def ssh_available?, do: Capabilities.ssh_available?()

  @doc "Returns the background color for the default theme."
  def default_theme_bg do
    Enum.find_value(themes(), "#241b2f", fn {key, _name, bg} ->
      if key == @default_theme, do: bg
    end)
  end

  @doc "Looks up a theme background color by key, falling back to the default."
  def theme_bg(theme_key) do
    Enum.find_value(themes(), default_theme_bg(), fn {key, _name, bg} ->
      if key == theme_key, do: bg
    end)
  end

  @doc "Returns the total widget count from the Catalog."
  def widget_count, do: length(Raxol.Playground.Catalog.list_components())

  @doc "Returns the category count from the Catalog."
  def category_count, do: length(Raxol.Playground.Catalog.list_categories())

  @doc "Returns Tailwind CSS classes for complexity badges."
  def complexity_class(:basic), do: "bg-green-100 text-green-800"
  def complexity_class(:intermediate), do: "bg-yellow-100 text-yellow-800"
  def complexity_class(:advanced), do: "bg-red-100 text-red-800"
  def complexity_class(_), do: "bg-gray-100 text-gray-800"

  @doc "Returns a human-readable label for a complexity atom."
  def complexity_label(:basic), do: "Basic"
  def complexity_label(:intermediate), do: "Intermediate"
  def complexity_label(:advanced), do: "Advanced"
  def complexity_label(other), do: to_string(other)

  @doc "Returns a human-readable label for a category atom."
  def category_label(cat), do: cat |> to_string() |> String.capitalize()

  @doc "Canonical theme list as `[{key, label, bg_color}]` tuples."
  def themes do
    [
      {:dracula, "Dracula", "#282a36"},
      {:nord, "Nord", "#2e3440"},
      {:monokai, "Monokai", "#272822"},
      {:solarized_dark, "Solarized Dark", "#002b36"},
      {:synthwave84, "Synthwave '84", "#241b2f"},
      {:gruvbox_dark, "Gruvbox Dark", "#282828"},
      {:one_dark, "One Dark", "#282c34"},
      {:tokyo_night, "Tokyo Night", "#1a1b26"},
      {:catppuccin, "Catppuccin", "#1e1e2e"}
    ]
  end

  @doc "Returns the foreground color for a theme."
  def theme_fg(:dracula), do: "#f8f8f2"
  def theme_fg(:nord), do: "#d8dee9"
  def theme_fg(:monokai), do: "#f8f8f2"
  def theme_fg(:solarized_dark), do: "#839496"
  def theme_fg(:synthwave84), do: "#e0def4"
  def theme_fg(:gruvbox_dark), do: "#ebdbb2"
  def theme_fg(:one_dark), do: "#abb2bf"
  def theme_fg(:tokyo_night), do: "#a9b1d6"
  def theme_fg(:catppuccin), do: "#cdd6f4"
  def theme_fg(_), do: "#e0e0e0"
end
