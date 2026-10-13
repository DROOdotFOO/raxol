defmodule Raxol.Terminal.Theme.Manager do
  @moduledoc """
  Manages terminal themes with advanced features:
  - Theme loading from files and presets
  - Theme customization and modification
  - Dynamic theme switching
  - Theme persistence and state management

  ## Unified Theme System

  Themes are sourced from `Raxol.Core.Theming.ThemeRegistry`, which
  provides a single source of truth for all Raxol themes. Use
  `load_from_registry/2` to load any registered theme.

  ## Usage

      manager = Raxol.Terminal.Theme.Manager.new()

      # Load a theme from the unified registry
      {:ok, manager} = Raxol.Terminal.Theme.Manager.load_from_registry(manager, :dracula)

      # Get a style
      {:ok, style, manager} = Raxol.Terminal.Theme.Manager.get_style(manager, :normal)
  """

  @type color :: %{
          r: integer(),
          g: integer(),
          b: integer(),
          a: float()
        }

  @type style :: %{
          foreground: color(),
          background: color(),
          bold: boolean(),
          italic: boolean(),
          underline: boolean()
        }

  @type theme :: %{
          name: String.t(),
          description: String.t(),
          author: String.t(),
          version: String.t(),
          colors: %{
            background: color(),
            foreground: color(),
            cursor: color(),
            selection: color(),
            black: color(),
            red: color(),
            green: color(),
            yellow: color(),
            blue: color(),
            magenta: color(),
            cyan: color(),
            white: color(),
            bright_black: color(),
            bright_red: color(),
            bright_green: color(),
            bright_yellow: color(),
            bright_blue: color(),
            bright_magenta: color(),
            bright_cyan: color(),
            bright_white: color()
          },
          styles: %{
            normal: style(),
            bold: style(),
            italic: style(),
            underline: style(),
            cursor: style(),
            selection: style()
          }
        }

  @type t :: %__MODULE__{
          current_theme: theme(),
          themes: %{String.t() => theme()},
          custom_styles: %{String.t() => style()},
          metrics: %{
            theme_switches: integer(),
            style_applications: integer(),
            customizations: integer(),
            load_operations: integer()
          }
        }

  defstruct [
    :current_theme,
    :themes,
    :custom_styles,
    :metrics
  ]

  @doc """
  Creates a new theme manager with the given options.
  """
  @spec new(keyword()) :: t()
  def new(_opts \\ []) do
    default_theme = %{
      name: "default",
      description: "Default terminal theme",
      author: "Raxol",
      version: "1.0.1",
      colors: %{
        background: %{r: 0, g: 0, b: 0, a: 1.0},
        foreground: %{r: 255, g: 255, b: 255, a: 1.0},
        cursor: %{r: 255, g: 255, b: 255, a: 1.0},
        selection: %{r: 51, g: 51, b: 51, a: 1.0},
        black: %{r: 0, g: 0, b: 0, a: 1.0},
        red: %{r: 255, g: 0, b: 0, a: 1.0},
        green: %{r: 0, g: 255, b: 0, a: 1.0},
        yellow: %{r: 255, g: 255, b: 0, a: 1.0},
        blue: %{r: 0, g: 0, b: 255, a: 1.0},
        magenta: %{r: 255, g: 0, b: 255, a: 1.0},
        cyan: %{r: 0, g: 255, b: 255, a: 1.0},
        white: %{r: 255, g: 255, b: 255, a: 1.0},
        bright_black: %{r: 128, g: 128, b: 128, a: 1.0},
        bright_red: %{r: 255, g: 128, b: 128, a: 1.0},
        bright_green: %{r: 128, g: 255, b: 128, a: 1.0},
        bright_yellow: %{r: 255, g: 255, b: 128, a: 1.0},
        bright_blue: %{r: 128, g: 128, b: 255, a: 1.0},
        bright_magenta: %{r: 255, g: 128, b: 255, a: 1.0},
        bright_cyan: %{r: 128, g: 255, b: 255, a: 1.0},
        bright_white: %{r: 255, g: 255, b: 255, a: 1.0}
      },
      styles: %{
        normal: %{
          foreground: %{r: 255, g: 255, b: 255, a: 1.0},
          background: %{r: 0, g: 0, b: 0, a: 1.0},
          bold: false,
          italic: false,
          underline: false
        },
        bold: %{
          foreground: %{r: 255, g: 255, b: 255, a: 1.0},
          background: %{r: 0, g: 0, b: 0, a: 1.0},
          bold: true,
          italic: false,
          underline: false
        },
        italic: %{
          foreground: %{r: 255, g: 255, b: 255, a: 1.0},
          background: %{r: 0, g: 0, b: 0, a: 1.0},
          bold: false,
          italic: true,
          underline: false
        },
        underline: %{
          foreground: %{r: 255, g: 255, b: 255, a: 1.0},
          background: %{r: 0, g: 0, b: 0, a: 1.0},
          bold: false,
          italic: false,
          underline: true
        },
        cursor: %{
          foreground: %{r: 0, g: 0, b: 0, a: 1.0},
          background: %{r: 255, g: 255, b: 255, a: 1.0},
          bold: false,
          italic: false,
          underline: false
        },
        selection: %{
          foreground: %{r: 255, g: 255, b: 255, a: 1.0},
          background: %{r: 51, g: 51, b: 51, a: 1.0},
          bold: false,
          italic: false,
          underline: false
        }
      }
    }

    %__MODULE__{
      current_theme: default_theme,
      themes: %{"default" => default_theme},
      custom_styles: %{},
      metrics: %{
        theme_switches: 0,
        style_applications: 0,
        customizations: 0,
        load_operations: 0
      }
    }
  end

  @doc """
  Loads a theme from a file or preset.
  """
  @spec load_theme(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def load_theme(manager, theme_name) do
    case Map.get(manager.themes, theme_name) do
      nil ->
        {:error, :theme_not_found}

      theme ->
        updated_manager = %{
          manager
          | current_theme: theme,
            metrics: update_metrics(manager.metrics, :theme_switches)
        }

        {:ok, updated_manager}
    end
  end

  @doc """
  Loads a theme from the unified theme registry.

  This is the preferred way to load themes as it uses the single
  source of truth for all Raxol theme definitions.

  ## Examples

      {:ok, manager} = Manager.load_from_registry(manager, :dracula)
      {:ok, manager} = Manager.load_from_registry(manager, :synthwave84)
  """
  @spec load_from_registry(t(), atom()) ::
          {:ok, t()} | {:error, :theme_not_found}
  def load_from_registry(manager, theme_name) when is_atom(theme_name) do
    case Raxol.Core.Theming.ThemeRegistry.to_terminal_format(theme_name) do
      nil ->
        {:error, :theme_not_found}

      theme when is_map(theme) ->
        # Add to available themes and set as current
        updated_themes = Map.put(manager.themes, theme.name, theme)

        updated_manager = %{
          manager
          | current_theme: theme,
            themes: updated_themes,
            metrics: update_metrics(manager.metrics, :theme_switches)
        }

        {:ok, updated_manager}
    end
  end

  @doc """
  Lists all themes available in the unified registry.
  """
  @spec list_registry_themes() :: [atom()]
  def list_registry_themes do
    Raxol.Core.Theming.ThemeRegistry.list()
  end

  @doc """
  Adds a custom style to the current theme.
  """
  @spec add_custom_style(t(), String.t(), style()) ::
          {:ok, t()} | {:error, term()}
  def add_custom_style(manager, name, style) do
    case validate_style(style) do
      :ok ->
        new_styles = Map.put(manager.custom_styles, name, style)

        updated_manager = %{
          manager
          | custom_styles: new_styles,
            metrics: update_metrics(manager.metrics, :customizations)
        }

        {:ok, updated_manager}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets a style from the current theme or custom styles.
  """
  @spec get_style(t(), String.t() | atom()) ::
          {:ok, style(), t()} | {:error, term()}
  def get_style(manager, style_name) do
    # Try atom and string keys for theme styles
    style =
      Map.get(manager.current_theme.styles, style_name) ||
        Map.get(manager.current_theme.styles, String.to_atom(style_name))

    case style do
      nil ->
        case Map.get(manager.custom_styles, style_name) do
          nil ->
            {:error, :style_not_found}

          style ->
            updated_manager = %{
              manager
              | metrics: update_metrics(manager.metrics, :style_applications)
            }

            {:ok, style, updated_manager}
        end

      style ->
        updated_manager = %{
          manager
          | metrics: update_metrics(manager.metrics, :style_applications)
        }

        {:ok, style, updated_manager}
    end
  end

  @doc """
  Gets the current theme metrics.
  """
  @spec get_metrics(t()) :: map()
  def get_metrics(manager) do
    manager.metrics
  end

  @doc """
  Saves the current theme state for persistence.
  """
  @spec save_theme_state(t()) :: {:ok, map()}
  def save_theme_state(manager) do
    state = %{
      current_theme: manager.current_theme.name,
      custom_styles: manager.custom_styles
    }

    {:ok, state}
  end

  @doc """
  Restores a theme state from saved data.
  """
  @spec restore_theme_state(t(), map()) :: {:ok, t()} | {:error, term()}
  def restore_theme_state(manager, state) do
    with {:ok, manager} <- load_theme(manager, state.current_theme) do
      updated_manager = %{
        manager
        | custom_styles: state.custom_styles,
          metrics: update_metrics(manager.metrics, :load_operations)
      }

      {:ok, updated_manager}
    end
  end

  # Private helper functions

  defp validate_style(style) do
    required_fields = [:foreground, :background, :bold, :italic, :underline]

    case Enum.all?(required_fields, &Map.has_key?(style, &1)) do
      true -> :ok
      false -> {:error, :invalid_style}
    end
  end

  defp update_metrics(metrics, :theme_switches) do
    %{metrics | theme_switches: metrics.theme_switches + 1}
  end

  defp update_metrics(metrics, :style_applications) do
    %{metrics | style_applications: metrics.style_applications + 1}
  end

  defp update_metrics(metrics, :customizations) do
    %{metrics | customizations: metrics.customizations + 1}
  end

  defp update_metrics(metrics, :load_operations) do
    %{metrics | load_operations: metrics.load_operations + 1}
  end
end
