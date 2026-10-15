defmodule Raxol.Core.Theming.ThemeRegistry do
  @moduledoc """
  Unified theme registry - single source of truth for all Raxol themes.

  Provides theme definitions that can be consumed by both terminal and web
  components. Each theme includes the standard 16-color ANSI palette plus
  UI colors (background, foreground, cursor, selection).

  ## Design

  Following Chris McCord's recommendation: one source of truth for themes
  that both LiveView and terminal components can consume.

  ## Color Formats

  Colors are stored as hex strings internally. Use conversion functions
  to get colors in the format needed:

  - `to_hex/1` - Returns hex string (for CSS/web)
  - `to_rgb/1` - Returns `{r, g, b}` tuple (for terminal)
  - `to_rgba_map/1` - Returns `%{r: r, g: g, b: b, a: 1.0}` (for terminal manager)

  ## Usage

      # Get a theme
      {:ok, theme} = ThemeRegistry.get(:dracula)

      # List available themes
      ThemeRegistry.list()

      # Get color in different formats
      ThemeRegistry.get_color(:dracula, :red)           # "#ff5555"
      ThemeRegistry.get_color(:dracula, :red, :rgb)     # {255, 85, 85}
      ThemeRegistry.get_color(:dracula, :red, :rgba)    # %{r: 255, g: 85, b: 85, a: 1.0}

      # Convert entire theme
      ThemeRegistry.to_terminal_format(:dracula)
      ThemeRegistry.to_liveview_format(:dracula)
  """

  @type theme_name :: atom()
  @type hex_color :: String.t()
  @type rgb_color :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type rgba_color :: %{
          r: non_neg_integer(),
          g: non_neg_integer(),
          b: non_neg_integer(),
          a: float()
        }
  @type color_format :: :hex | :rgb | :rgba

  @type theme :: %{
          name: theme_name(),
          display_name: String.t(),
          description: String.t(),
          dark_mode: boolean(),
          ui: %{
            background: hex_color(),
            foreground: hex_color(),
            cursor: hex_color(),
            selection: hex_color()
          },
          colors: %{
            black: hex_color(),
            red: hex_color(),
            green: hex_color(),
            yellow: hex_color(),
            blue: hex_color(),
            magenta: hex_color(),
            cyan: hex_color(),
            white: hex_color(),
            bright_black: hex_color(),
            bright_red: hex_color(),
            bright_green: hex_color(),
            bright_yellow: hex_color(),
            bright_blue: hex_color(),
            bright_magenta: hex_color(),
            bright_cyan: hex_color(),
            bright_white: hex_color()
          }
        }

  # ============================================================================
  # Theme Access
  # ============================================================================

  @doc """
  Gets a theme by name.

  Returns `{:ok, theme}` or `{:error, :not_found}`.
  """
  @spec get(theme_name()) :: {:ok, theme()} | {:error, :not_found}
  def get(name) when is_atom(name) do
    case Map.get(themes(), name) do
      nil -> {:error, :not_found}
      theme -> {:ok, theme}
    end
  end

  @doc """
  Gets a theme by name, returning nil if not found.
  """
  @spec get!(theme_name()) :: theme() | nil
  def get!(name) do
    case get(name) do
      {:ok, theme} -> theme
      {:error, _} -> nil
    end
  end

  @doc """
  Lists all available theme names.
  """
  @spec list() :: [theme_name()]
  def list do
    themes() |> Map.keys() |> Enum.sort()
  end

  @doc """
  Lists all themes with their display names.
  """
  @spec list_with_names() :: [{theme_name(), String.t()}]
  def list_with_names do
    themes()
    |> Enum.map(fn {name, theme} -> {name, theme.display_name} end)
    |> Enum.sort_by(fn {_, display} -> display end)
  end

  @doc """
  Returns the default theme name.
  """
  @spec default() :: :dracula
  def default, do: :dracula

  # ============================================================================
  # Color Access
  # ============================================================================

  @doc """
  Gets a specific color from a theme.

  ## Options

  - `:hex` (default) - Returns hex string
  - `:rgb` - Returns `{r, g, b}` tuple
  - `:rgba` - Returns `%{r: r, g: g, b: b, a: 1.0}` map
  """
  @spec get_color(theme_name(), atom(), color_format()) ::
          hex_color() | rgb_color() | rgba_color() | nil
  def get_color(theme_name, color_name, format \\ :hex) do
    case get(theme_name) do
      {:ok, theme} ->
        hex = get_color_hex(theme, color_name)
        convert_color(hex, format)

      {:error, _} ->
        nil
    end
  end

  defp get_color_hex(theme, color_name)
       when color_name in [:background, :foreground, :cursor, :selection] do
    Map.get(theme.ui, color_name)
  end

  defp get_color_hex(theme, color_name) do
    Map.get(theme.colors, color_name)
  end

  # ============================================================================
  # Format Conversion
  # ============================================================================

  @doc """
  Converts a theme to LiveView format.
  """
  @spec to_liveview_format(theme_name()) ::
          %{
            name: atom(),
            background: hex_color(),
            foreground: hex_color(),
            cursor: hex_color(),
            selection: hex_color(),
            colors: map()
          }
          | nil
  def to_liveview_format(theme_name) do
    case get(theme_name) do
      {:ok, theme} ->
        %{
          name: theme.name,
          background: theme.ui.background,
          foreground: theme.ui.foreground,
          cursor: theme.ui.cursor,
          selection: theme.ui.selection,
          colors: theme.colors
        }

      {:error, _} ->
        nil
    end
  end

  @doc """
  Converts a theme to terminal manager format (RGBA maps).
  """
  @spec to_terminal_format(theme_name()) ::
          %{
            name: String.t(),
            description: String.t(),
            author: String.t(),
            version: String.t(),
            colors: map()
          }
          | nil
  def to_terminal_format(theme_name) do
    case get(theme_name) do
      {:ok, theme} -> build_terminal_format(theme)
      {:error, _} -> nil
    end
  end

  defp build_terminal_format(theme) do
    %{
      name: Atom.to_string(theme.name),
      description: theme.description,
      author: "Raxol",
      version: "1.0.0",
      colors: build_terminal_colors(theme),
      styles: default_styles(theme)
    }
  end

  defp build_terminal_colors(theme) do
    ui_colors = Map.new(theme.ui, fn {k, v} -> {k, hex_to_rgba(v)} end)
    ansi_colors = Map.new(theme.colors, fn {k, v} -> {k, hex_to_rgba(v)} end)
    Map.merge(ui_colors, ansi_colors)
  end

  @doc """
  Converts a hex color to the specified format.
  """
  @spec convert_color(hex_color() | nil, color_format()) ::
          hex_color() | rgb_color() | rgba_color() | nil
  def convert_color(nil, _format), do: nil
  def convert_color(hex, :hex), do: hex
  def convert_color(hex, :rgb), do: hex_to_rgb(hex)
  def convert_color(hex, :rgba), do: hex_to_rgba(hex)

  # Every colour this module stores is a six-digit `#rrggbb` string, so the
  # registry parses exactly that shape and nothing else. The lenient parser in
  # main raxol (`Raxol.Utils.ColorConversion`) is out of reach: raxol_core must
  # stay usable without it.
  defp hex_to_rgb(<<"#", r::binary-size(2), g::binary-size(2), b::binary-size(2)>>) do
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  defp hex_to_rgba(hex) do
    {r, g, b} = hex_to_rgb(hex)
    %{r: r, g: g, b: b, a: 1.0}
  end

  # ============================================================================
  # Theme Definitions
  # ============================================================================

  defp themes do
    %{
      synthwave84: %{
        name: :synthwave84,
        display_name: "Synthwave '84",
        description: "Neon-infused retro theme inspired by 1980s aesthetics",
        dark_mode: true,
        ui: %{
          background: "#2b213a",
          foreground: "#f0eff1",
          cursor: "#f890e7",
          selection: "#495495"
        },
        colors: %{
          black: "#2b213a",
          red: "#fe4450",
          green: "#72f1b8",
          yellow: "#fede5d",
          blue: "#03edf9",
          magenta: "#ff7edb",
          cyan: "#03edf9",
          white: "#f0eff1",
          bright_black: "#534267",
          bright_red: "#fe4450",
          bright_green: "#72f1b8",
          bright_yellow: "#fede5d",
          bright_blue: "#03edf9",
          bright_magenta: "#f890e7",
          bright_cyan: "#03edf9",
          bright_white: "#ffffff"
        }
      },
      nord: %{
        name: :nord,
        display_name: "Nord",
        description: "Arctic, north-bluish color palette",
        dark_mode: true,
        ui: %{
          background: "#2e3440",
          foreground: "#d8dee9",
          cursor: "#88c0d0",
          selection: "#434c5e"
        },
        colors: %{
          black: "#3b4252",
          red: "#bf616a",
          green: "#a3be8c",
          yellow: "#ebcb8b",
          blue: "#81a1c1",
          magenta: "#b48ead",
          cyan: "#88c0d0",
          white: "#e5e9f0",
          bright_black: "#4c566a",
          bright_red: "#bf616a",
          bright_green: "#a3be8c",
          bright_yellow: "#ebcb8b",
          bright_blue: "#81a1c1",
          bright_magenta: "#b48ead",
          bright_cyan: "#8fbcbb",
          bright_white: "#eceff4"
        }
      },
      dracula: %{
        name: :dracula,
        display_name: "Dracula",
        description: "Dark theme with vibrant colors",
        dark_mode: true,
        ui: %{
          background: "#282a36",
          foreground: "#f8f8f2",
          cursor: "#ff79c6",
          selection: "#44475a"
        },
        colors: %{
          black: "#21222c",
          red: "#ff5555",
          green: "#50fa7b",
          yellow: "#f1fa8c",
          blue: "#bd93f9",
          magenta: "#ff79c6",
          cyan: "#8be9fd",
          white: "#f8f8f2",
          bright_black: "#6272a4",
          bright_red: "#ff6e6e",
          bright_green: "#69ff94",
          bright_yellow: "#ffffa5",
          bright_blue: "#d6acff",
          bright_magenta: "#ff92df",
          bright_cyan: "#a4ffff",
          bright_white: "#ffffff"
        }
      },
      monokai: %{
        name: :monokai,
        display_name: "Monokai",
        description: "Classic dark theme with warm colors",
        dark_mode: true,
        ui: %{
          background: "#272822",
          foreground: "#f8f8f2",
          cursor: "#f8f8f0",
          selection: "#49483e"
        },
        colors: %{
          black: "#272822",
          red: "#f92672",
          green: "#a6e22e",
          yellow: "#f4bf75",
          blue: "#66d9ef",
          magenta: "#ae81ff",
          cyan: "#a1efe4",
          white: "#f8f8f2",
          bright_black: "#75715e",
          bright_red: "#f92672",
          bright_green: "#a6e22e",
          bright_yellow: "#f4bf75",
          bright_blue: "#66d9ef",
          bright_magenta: "#ae81ff",
          bright_cyan: "#a1efe4",
          bright_white: "#f9f8f5"
        }
      },
      gruvbox: %{
        name: :gruvbox,
        display_name: "Gruvbox",
        description: "Retro groove color scheme",
        dark_mode: true,
        ui: %{
          background: "#282828",
          foreground: "#ebdbb2",
          cursor: "#fe8019",
          selection: "#504945"
        },
        colors: %{
          black: "#282828",
          red: "#cc241d",
          green: "#98971a",
          yellow: "#d79921",
          blue: "#458588",
          magenta: "#b16286",
          cyan: "#689d6a",
          white: "#a89984",
          bright_black: "#928374",
          bright_red: "#fb4934",
          bright_green: "#b8bb26",
          bright_yellow: "#fabd2f",
          bright_blue: "#83a598",
          bright_magenta: "#d3869b",
          bright_cyan: "#8ec07c",
          bright_white: "#ebdbb2"
        }
      },
      solarized_dark: %{
        name: :solarized_dark,
        display_name: "Solarized Dark",
        description: "Precision colors for machines and people",
        dark_mode: true,
        ui: %{
          background: "#002b36",
          foreground: "#839496",
          cursor: "#93a1a1",
          selection: "#073642"
        },
        colors: %{
          black: "#073642",
          red: "#dc322f",
          green: "#859900",
          yellow: "#b58900",
          blue: "#268bd2",
          magenta: "#d33682",
          cyan: "#2aa198",
          white: "#eee8d5",
          bright_black: "#002b36",
          bright_red: "#cb4b16",
          bright_green: "#586e75",
          bright_yellow: "#657b83",
          bright_blue: "#839496",
          bright_magenta: "#6c71c4",
          bright_cyan: "#93a1a1",
          bright_white: "#fdf6e3"
        }
      },
      solarized_light: %{
        name: :solarized_light,
        display_name: "Solarized Light",
        description: "Precision colors for machines and people (light variant)",
        dark_mode: false,
        ui: %{
          background: "#fdf6e3",
          foreground: "#657b83",
          cursor: "#586e75",
          selection: "#eee8d5"
        },
        colors: %{
          black: "#073642",
          red: "#dc322f",
          green: "#859900",
          yellow: "#b58900",
          blue: "#268bd2",
          magenta: "#d33682",
          cyan: "#2aa198",
          white: "#eee8d5",
          bright_black: "#002b36",
          bright_red: "#cb4b16",
          bright_green: "#586e75",
          bright_yellow: "#657b83",
          bright_blue: "#839496",
          bright_magenta: "#6c71c4",
          bright_cyan: "#93a1a1",
          bright_white: "#fdf6e3"
        }
      },
      tokyo_night: %{
        name: :tokyo_night,
        display_name: "Tokyo Night",
        description: "Clean dark theme inspired by Tokyo city lights",
        dark_mode: true,
        ui: %{
          background: "#1a1b26",
          foreground: "#c0caf5",
          cursor: "#c0caf5",
          selection: "#33467c"
        },
        colors: %{
          black: "#15161e",
          red: "#f7768e",
          green: "#9ece6a",
          yellow: "#e0af68",
          blue: "#7aa2f7",
          magenta: "#bb9af7",
          cyan: "#7dcfff",
          white: "#a9b1d6",
          bright_black: "#414868",
          bright_red: "#f7768e",
          bright_green: "#9ece6a",
          bright_yellow: "#e0af68",
          bright_blue: "#7aa2f7",
          bright_magenta: "#bb9af7",
          bright_cyan: "#7dcfff",
          bright_white: "#c0caf5"
        }
      },
      one_dark: %{
        name: :one_dark,
        display_name: "One Dark",
        description: "Atom's iconic One Dark theme",
        dark_mode: true,
        ui: %{
          background: "#282c34",
          foreground: "#abb2bf",
          cursor: "#528bff",
          selection: "#3e4451"
        },
        colors: %{
          black: "#282c34",
          red: "#e06c75",
          green: "#98c379",
          yellow: "#e5c07b",
          blue: "#61afef",
          magenta: "#c678dd",
          cyan: "#56b6c2",
          white: "#abb2bf",
          bright_black: "#5c6370",
          bright_red: "#e06c75",
          bright_green: "#98c379",
          bright_yellow: "#e5c07b",
          bright_blue: "#61afef",
          bright_magenta: "#c678dd",
          bright_cyan: "#56b6c2",
          bright_white: "#ffffff"
        }
      },
      catppuccin: %{
        name: :catppuccin,
        display_name: "Catppuccin",
        description: "Soothing pastel theme for the high-spirited",
        dark_mode: true,
        ui: %{
          background: "#1e1e2e",
          foreground: "#cdd6f4",
          cursor: "#f5e0dc",
          selection: "#45475a"
        },
        colors: %{
          black: "#45475a",
          red: "#f38ba8",
          green: "#a6e3a1",
          yellow: "#f9e2af",
          blue: "#89b4fa",
          magenta: "#cba6f7",
          cyan: "#89dceb",
          white: "#bac2de",
          bright_black: "#585b70",
          bright_red: "#f38ba8",
          bright_green: "#a6e3a1",
          bright_yellow: "#f9e2af",
          bright_blue: "#89b4fa",
          bright_magenta: "#cba6f7",
          bright_cyan: "#89dceb",
          bright_white: "#a6adc8"
        }
      }
    }
  end

  defp default_styles(theme) do
    fg = hex_to_rgba(theme.ui.foreground)
    bg = hex_to_rgba(theme.ui.background)
    cursor_bg = hex_to_rgba(theme.ui.cursor)
    selection_bg = hex_to_rgba(theme.ui.selection)

    %{
      normal: %{
        foreground: fg,
        background: bg,
        bold: false,
        italic: false,
        underline: false
      },
      bold: %{
        foreground: fg,
        background: bg,
        bold: true,
        italic: false,
        underline: false
      },
      italic: %{
        foreground: fg,
        background: bg,
        bold: false,
        italic: true,
        underline: false
      },
      underline: %{
        foreground: fg,
        background: bg,
        bold: false,
        italic: false,
        underline: true
      },
      cursor: %{
        foreground: bg,
        background: cursor_bg,
        bold: false,
        italic: false,
        underline: false
      },
      selection: %{
        foreground: fg,
        background: selection_bg,
        bold: false,
        italic: false,
        underline: false
      }
    }
  end
end
