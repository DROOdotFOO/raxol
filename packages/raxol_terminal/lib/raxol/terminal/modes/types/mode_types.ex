defmodule Raxol.Terminal.Modes.Types.ModeTypes do
  @moduledoc """
  Defines types and constants for terminal modes.
  Provides a centralized registry of all terminal modes and their properties.
  """

  # Mode categories
  @type mode_category :: :dec_private | :standard | :mouse | :screen_buffer

  # Mode states
  @type mode_state :: :enabled | :disabled | :unknown

  # Mode values
  @type mode_value :: boolean() | atom() | integer()

  # Mode definition
  @type mode :: %{
          category: mode_category(),
          code: integer(),
          name: atom(),
          default_value: mode_value(),
          dependencies: [mode()],
          conflicts: [mode()]
        }

  # DEC Private Mode codes and their corresponding mode atoms
  @dec_private_modes %{
    # Cursor Keys Mode
    1 => %{
      category: :dec_private,
      code: 1,
      name: :decckm,
      default_value: :normal,
      dependencies: [],
      conflicts: []
    },
    # 132 Column Mode (DECCOLM). `:deccolm_80` is only a state name: it is the
    # reset side of this mode and has no CSI number of its own.
    3 => %{
      category: :dec_private,
      code: 3,
      name: :deccolm_132,
      default_value: false,
      dependencies: [],
      conflicts: [:deccolm_80]
    },
    # Screen Mode (reverse)
    5 => %{
      category: :dec_private,
      code: 5,
      name: :decscnm,
      default_value: false,
      dependencies: [],
      conflicts: []
    },
    # Origin Mode
    6 => %{
      category: :dec_private,
      code: 6,
      name: :decom,
      default_value: false,
      dependencies: [],
      conflicts: []
    },
    # Auto Wrap Mode
    7 => %{
      category: :dec_private,
      code: 7,
      name: :decawm,
      default_value: true,
      dependencies: [],
      conflicts: []
    },
    # Auto Repeat Mode
    8 => %{
      category: :dec_private,
      code: 8,
      name: :decarm,
      default_value: true,
      dependencies: [],
      conflicts: []
    },
    # Interlace Mode
    9 => %{
      category: :dec_private,
      code: 9,
      name: :decinlm,
      default_value: false,
      dependencies: [],
      conflicts: []
    },
    # Blink Attribute Mode
    12 => %{
      category: :dec_private,
      code: 12,
      name: :att_blink,
      default_value: true,
      dependencies: [],
      conflicts: []
    },
    # Text Cursor Enable Mode
    25 => %{
      category: :dec_private,
      code: 25,
      name: :dectcem,
      default_value: true,
      dependencies: [],
      conflicts: []
    },
    # Use Alternate Screen Buffer (Simple)
    47 => %{
      category: :screen_buffer,
      code: 47,
      name: :dec_alt_screen,
      default_value: false,
      dependencies: [],
      conflicts: [:dec_alt_screen_save, :alt_screen_buffer]
    },
    # Mouse modes
    1000 => %{
      category: :mouse,
      code: 1000,
      name: :mouse_report_x10,
      default_value: false,
      dependencies: [],
      conflicts: [:mouse_report_cell_motion]
    },
    1002 => %{
      category: :mouse,
      code: 1002,
      name: :mouse_report_cell_motion,
      default_value: false,
      dependencies: [],
      conflicts: [:mouse_report_x10]
    },
    1006 => %{
      category: :mouse,
      code: 1006,
      name: :mouse_encoding_sgr,
      default_value: false,
      dependencies: [],
      conflicts: []
    },
    # Focus events
    1004 => %{
      category: :dec_private,
      code: 1004,
      name: :focus_events,
      default_value: false,
      dependencies: [],
      conflicts: []
    },
    # Alt screen modes
    1047 => %{
      category: :screen_buffer,
      code: 1047,
      name: :dec_alt_screen_save,
      default_value: false,
      dependencies: [],
      conflicts: [:dec_alt_screen, :alt_screen_buffer]
    },
    1048 => %{
      category: :screen_buffer,
      code: 1048,
      name: :decsc_deccara,
      default_value: false,
      dependencies: [],
      conflicts: []
    },
    1049 => %{
      category: :screen_buffer,
      code: 1049,
      name: :alt_screen_buffer,
      default_value: false,
      dependencies: [],
      conflicts: [:dec_alt_screen, :dec_alt_screen_save]
    },
    # Bracketed paste
    2004 => %{
      category: :dec_private,
      code: 2004,
      name: :bracketed_paste,
      default_value: false,
      dependencies: [],
      conflicts: []
    }
  }

  # Standard Mode codes and their corresponding mode atoms
  @standard_modes %{
    # Insert Mode
    4 => %{
      category: :standard,
      code: 4,
      name: :irm,
      default_value: false,
      dependencies: [],
      conflicts: []
    },
    # Line Feed Mode
    20 => %{
      category: :standard,
      code: 20,
      name: :lnm,
      default_value: false,
      dependencies: [],
      conflicts: []
    }
  }

  @doc """
  Looks up a DEC private mode code and returns the corresponding mode definition.
  """
  @spec lookup_private(integer()) :: mode() | nil
  def lookup_private(code) when is_integer(code) do
    @dec_private_modes[code]
  end

  @doc """
  Looks up a standard mode code and returns the corresponding mode definition.
  """
  @spec lookup_standard(integer()) :: mode() | nil
  def lookup_standard(code) when is_integer(code) do
    @standard_modes[code]
  end

  @doc """
  Returns all registered modes.
  """
  @spec get_all_modes() :: %{integer() => mode()}
  def get_all_modes do
    # Create a map that preserves both standard and DEC private modes
    # even when they share the same code
    dec_private_with_keys =
      @dec_private_modes
      |> Enum.map(fn {code, mode_def} ->
        # Use a tuple key to distinguish between categories
        {{code, :dec_private}, mode_def}
      end)
      |> Map.new()

    standard_with_keys =
      @standard_modes
      |> Enum.map(fn {code, mode_def} ->
        # Use a tuple key to distinguish between categories
        {{code, :standard}, mode_def}
      end)
      |> Map.new()

    # Merge both maps, preserving all entries
    Map.merge(dec_private_with_keys, standard_with_keys)
  end

  @doc """
  Returns all modes of a specific category.
  """
  @spec get_modes_by_category(mode_category()) :: [mode()]
  def get_modes_by_category(category) do
    get_all_modes()
    |> Map.values()
    |> Enum.filter(&(&1.category == category))
  end
end
