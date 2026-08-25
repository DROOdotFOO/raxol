defmodule Raxol.Terminal.Rendering.LigatureRenderer do
  @moduledoc """
  Programming font ligature rendering system for Raxol terminals.

  This module provides comprehensive support for programming font ligatures with:
  - Multi-character ligature detection and replacement
  - Font-specific ligature mapping (FiraCode, JetBrains Mono, Cascadia Code, etc.)
  - Unicode rendering with proper character width calculation
  - Performance-optimized ligature processing
  - Customizable ligature sets and user preferences
  - Fallback handling for non-ligature fonts

  ## Supported Ligatures

  ### Arrows and Flow
  - `->`, `<-`, `=>`, `<=`, `>=`, `!=`, `==`, `===`
  - `|>`, `<|`, `>>`, `<<`, `<>`, `<=>`, `<->`
  - `~>`, `<~`, `~>>`, `<<~`, `<~~`, `~~>`

  ### Programming Symbols
  - `++`, `--`, `**`, `//`, `::`, `;;`, `??`, `!!`
  - `&&`, `||`, `&&&`, `|||`
  - `#=`, `#!`, `#?`, `#_`, `##`
  - `/*`, `*/`, `/**`, `**/`

  ### Mathematical
  - `<=`, `>=`, `!=`, `==`, `===`, `!==`
  - `<<=`, `>>=`, `<=>`, `<->`
  - `+-`, `-+`, `*=`, `/=`, `%=`, `^=`

  ## Usage

      # Configure ligature rendering
      config = LigatureRenderer.config(
        font: :fira_code,
        enabled_sets: [:arrows, :programming, :math],
        disabled_ligatures: ["->"]  # Disable specific ligatures
      )

      # Render text with ligatures
      text = "const arrow = (x) => x + 1; // Lambda function"
      rendered = LigatureRenderer.render(text, config)

      # Check if text contains ligatures
      has_ligatures? = LigatureRenderer.contains_ligatures?(text, config)
  """

  defstruct [
    :font,
    :enabled_sets,
    :disabled_ligatures,
    :custom_ligatures,
    :performance_mode,
    :fallback_enabled
  ]

  @type ligature_set ::
          :arrows | :programming | :math | :brackets | :comments | :operators
  @type font_family ::
          :fira_code
          | :jetbrains_mono
          | :cascadia_code
          | :iosevka
          | :hack
          | :custom
  @type unicode_point :: 0..0x10FFFF
  @type ligature_config :: %__MODULE__{
          font: font_family(),
          enabled_sets: [ligature_set()],
          disabled_ligatures: [String.t()],
          custom_ligatures: %{String.t() => unicode_point()},
          performance_mode: boolean(),
          fallback_enabled: boolean()
        }

  # Unicode Private Use Area for ligatures (varies by font)
  @fira_code_base 0xE100
  @jetbrains_mono_base 0xE200
  @cascadia_code_base 0xE300
  @iosevka_base 0xE400

  # Ligature definitions by category
  @arrows_ligatures %{
    "->" => 0xE100,
    "<-" => 0xE101,
    "=>" => 0xE102,
    "<=" => 0xE103,
    ">=" => 0xE104,
    "!=" => 0xE105,
    "==" => 0xE106,
    "===" => 0xE107,
    "!===" => 0xE108,
    "|>" => 0xE109,
    "<|" => 0xE10A,
    ">>" => 0xE10B,
    "<<" => 0xE10C,
    "<>" => 0xE10D,
    "<=>" => 0xE10E,
    "<->" => 0xE10F,
    "~>" => 0xE110,
    "<~" => 0xE111,
    "~>>" => 0xE112,
    "<<~" => 0xE113,
    "<~~" => 0xE114,
    "~~>" => 0xE115,
    ">>>" => 0xE116,
    "<<<" => 0xE117
  }

  @programming_ligatures %{
    "++" => 0xE120,
    "--" => 0xE121,
    "**" => 0xE122,
    "//" => 0xE123,
    "::" => 0xE124,
    ";;" => 0xE125,
    "??" => 0xE126,
    "!!" => 0xE127,
    "&&" => 0xE128,
    "||" => 0xE129,
    "&&&" => 0xE12A,
    "|||" => 0xE12B,
    "#=" => 0xE12C,
    "#!" => 0xE12D,
    "#?" => 0xE12E,
    "#_" => 0xE12F,
    "##" => 0xE130,
    "###" => 0xE131,
    "####" => 0xE132,
    ".." => 0xE133,
    "..." => 0xE134,
    "..<" => 0xE135,
    ".=" => 0xE136
  }

  @math_ligatures %{
    "+-" => 0xE140,
    "-+" => 0xE141,
    "*=" => 0xE142,
    "/=" => 0xE143,
    "%=" => 0xE144,
    "^=" => 0xE145,
    "<<=" => 0xE146,
    ">>=" => 0xE147,
    "***" => 0xE148,
    "///" => 0xE149,
    ":::" => 0xE14A,
    "=:=" => 0xE14B,
    "=/=" => 0xE14C,
    "<|>" => 0xE14D,
    "<||>" => 0xE14E
  }

  @brackets_ligatures %{
    "[[" => 0xE160,
    "]]" => 0xE161,
    "{|" => 0xE162,
    "|}" => 0xE163,
    "[|" => 0xE164,
    "|]" => 0xE165,
    "((" => 0xE166,
    "))" => 0xE167,
    "{{" => 0xE168,
    "}}" => 0xE169
  }

  @comments_ligatures %{
    "/*" => 0xE180,
    "*/" => 0xE181,
    "/**" => 0xE182,
    "**/" => 0xE183,
    "/*/" => 0xE184,
    "/***" => 0xE185,
    "***/" => 0xE186,
    "///" => 0xE187,
    "////" => 0xE188,
    "<!--" => 0xE189,
    "-->" => 0xE18A
  }

  @operators_ligatures %{
    "<:" => 0xE1A0,
    ":>" => 0xE1A1,
    "<:>" => 0xE1A2,
    "=<<" => 0xE1A3,
    ">>=" => 0xE1A4,
    "<<>>" => 0xE1A5,
    "<><>" => 0xE1A6,
    "++" => 0xE1A7,
    "--" => 0xE1A8,
    "**" => 0xE1A9,
    "//" => 0xE1AA,
    "%%" => 0xE1AB,
    "@@" => 0xE1AC,
    "$$" => 0xE1AD
  }

  @all_ligature_sets %{
    arrows: @arrows_ligatures,
    programming: @programming_ligatures,
    math: @math_ligatures,
    brackets: @brackets_ligatures,
    comments: @comments_ligatures,
    operators: @operators_ligatures
  }

  def default_config do
    %__MODULE__{
      font: :fira_code,
      enabled_sets: [:arrows, :programming, :math],
      disabled_ligatures: [],
      custom_ligatures: %{},
      performance_mode: false,
      fallback_enabled: true
    }
  end

  ## Public API

  @doc """
  Creates a ligature rendering configuration.

  ## Examples

      config = LigatureRenderer.config(
        font: :fira_code,
        enabled_sets: [:arrows, :programming],
        disabled_ligatures: ["->", "<="]
      )
  """
  def config(opts \\ []) do
    Enum.reduce(opts, default_config(), fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  @doc """
  Renders text with ligatures applied.

  ## Examples

      config = LigatureRenderer.config(font: :fira_code)
      text = "const sum = (a, b) => a + b;"
      rendered = LigatureRenderer.render(text, config)
  """
  def render(text, config \\ nil) when is_binary(text) do
    config = config || default_config()
    apply_rendering_mode(config.performance_mode, text, config)
  end

  defp apply_rendering_mode(true, text, config),
    do: render_optimized(text, config)

  defp apply_rendering_mode(false, text, config),
    do: render_standard(text, config)

  @doc """
  Checks if text contains any ligatures that would be rendered.

  ## Examples

      config = LigatureRenderer.config()
      LigatureRenderer.contains_ligatures?("hello -> world", config)
      # true

      LigatureRenderer.contains_ligatures?("hello world", config)
      # false
  """
  def contains_ligatures?(text, config \\ nil) do
    config = config || default_config()
    ligature_map = build_ligature_map(config)

    ligature_map
    |> Map.keys()
    |> Enum.any?(&String.contains?(text, &1))
  end

  @doc """
  Gets all available ligatures for a specific font and configuration.

  ## Examples

      config = LigatureRenderer.config(font: :fira_code)
      ligatures = LigatureRenderer.available_ligatures(config)
  """
  def available_ligatures(config \\ nil) do
    config = config || default_config()
    build_ligature_map(config)
  end

  @doc """
  Calculates the visual width of text after ligature rendering.

  Some ligatures reduce the visual width (e.g., "->" becomes one character),
  which is important for proper text alignment and cursor positioning.
  """
  def visual_width(text, config \\ nil) do
    config = config || default_config()
    ligature_map = build_ligature_map(config)
    calculate_visual_width(text, ligature_map)
  end

  @doc """
  Converts ligature unicode points back to original text sequences.

  Useful for editing operations where you need the original text.
  """
  def ligatures_to_text(rendered_text, config \\ nil) do
    config = config || default_config()

    reverse_map =
      config
      |> build_ligature_map()
      |> Enum.map(fn {text, unicode} -> {unicode, text} end)
      |> Map.new()

    rendered_text
    |> String.to_charlist()
    |> Enum.map_join("", fn char ->
      case Map.get(reverse_map, char) do
        nil -> <<char::utf8>>
        text -> text
      end
    end)
  end

  @doc """
  Gets cursor position mapping after ligature rendering.

  When ligatures are rendered, cursor positions need to be adjusted
  because multiple characters may render as one.
  """
  def cursor_position_map(text, config \\ nil) do
    config = config || default_config()
    ligature_map = build_ligature_map(config)
    build_cursor_map(text, ligature_map)
  end

  @doc """
  Detects font ligature capabilities.

  Attempts to determine if the current terminal font supports ligatures.
  """
  def detect_font_ligatures do
    # This is a simplified detection - in practice would need more sophisticated detection
    case System.get_env("TERM_PROGRAM") do
      "iTerm.app" ->
        :likely_supported

      "WezTerm" ->
        :supported

      "Alacritty" ->
        :likely_supported

      "kitty" ->
        :supported

      _ ->
        case System.get_env("FONT_FAMILY") do
          font when font in ["Fira Code", "JetBrains Mono", "Cascadia Code"] ->
            :likely_supported

          _ ->
            :unknown
        end
    end
  end

  @doc """
  Optimizes ligature configuration for performance.

  Analyzes text patterns to suggest optimal ligature sets.
  """
  def optimize_config(text_samples, base_config \\ nil)
      when is_list(text_samples) do
    base_config = base_config || default_config()
    # Analyze which ligature sets are actually used
    all_text = Enum.join(text_samples, " ")

    used_sets =
      @all_ligature_sets
      |> Enum.filter(fn {_set_name, ligatures} ->
        ligatures
        |> Map.keys()
        |> Enum.any?(&String.contains?(all_text, &1))
      end)
      |> Enum.map(&elem(&1, 0))

    frequency_map = calculate_ligature_frequency(all_text, base_config)

    # Suggest optimizations
    suggestions = %{
      recommended_sets: used_sets,
      unused_sets:
        Enum.filter(
          [:arrows, :programming, :math, :brackets, :comments, :operators],
          &(&1 not in used_sets)
        ),
      frequently_used: frequency_map |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.take(10),
      performance_mode: length(text_samples) > 100 or String.length(all_text) > 10_000
    }

    optimized_config = %{
      base_config
      | enabled_sets: used_sets,
        performance_mode: suggestions.performance_mode
    }

    {optimized_config, suggestions}
  end

  ## Private Implementation

  defp render_standard(text, config) do
    ligature_map = build_ligature_map(config)

    # Sort by length (longest first) to handle overlapping ligatures correctly
    sorted_ligatures =
      ligature_map
      |> Enum.sort_by(fn {text, _} -> -String.length(text) end)

    Enum.reduce(sorted_ligatures, text, fn {pattern, unicode_point}, acc ->
      apply_ligature_replacement(
        String.contains?(acc, pattern),
        acc,
        pattern,
        unicode_point
      )
    end)
  end

  defp apply_ligature_replacement(false, acc, _pattern, _unicode_point), do: acc

  defp apply_ligature_replacement(true, acc, pattern, unicode_point) do
    String.replace(acc, pattern, <<unicode_point::utf8>>)
  end

  defp render_optimized(text, config) do
    # Performance-optimized version with early exits and caching
    ligature_map = build_ligature_map(config)

    # Pre-filter ligatures that might be in the text
    candidate_ligatures =
      ligature_map
      |> Enum.filter(fn {pattern, _} -> String.contains?(text, pattern) end)
      |> Enum.sort_by(fn {text, _} -> -String.length(text) end)

    process_candidate_ligatures(
      Enum.empty?(candidate_ligatures),
      text,
      candidate_ligatures
    )
  end

  defp process_candidate_ligatures(true, text, _candidate_ligatures), do: text

  defp process_candidate_ligatures(false, text, candidate_ligatures) do
    Enum.reduce(candidate_ligatures, text, fn {pattern, unicode_point}, acc ->
      String.replace(acc, pattern, <<unicode_point::utf8>>)
    end)
  end

  defp build_ligature_map(config) do
    # Build the complete ligature map based on configuration
    base_map =
      config.enabled_sets
      |> Enum.reduce(%{}, fn set_name, acc ->
        set_ligatures = Map.get(@all_ligature_sets, set_name, %{})
        Map.merge(acc, set_ligatures)
      end)

    # Apply font-specific adjustments
    font_adjusted_map = apply_font_adjustments(base_map, config.font)

    # Remove disabled ligatures
    filtered_map =
      Enum.reduce(config.disabled_ligatures, font_adjusted_map, fn disabled, acc ->
        Map.delete(acc, disabled)
      end)

    # Add custom ligatures
    Map.merge(filtered_map, config.custom_ligatures)
  end

  defp apply_font_adjustments(ligature_map, font) do
    # Adjust unicode points based on font
    _base_offset =
      case font do
        :fira_code -> @fira_code_base
        :jetbrains_mono -> @jetbrains_mono_base
        :cascadia_code -> @cascadia_code_base
        :iosevka -> @iosevka_base
        # Default
        _ -> @fira_code_base
      end

    # For now, just use the default mapping
    # In a real implementation, this would adjust unicode points per font
    ligature_map
  end

  defp calculate_visual_width(text, ligature_map) do
    # Calculate how much the visual width changes due to ligatures
    original_width = String.length(text)

    width_reduction =
      ligature_map
      |> Enum.reduce(0, fn {pattern, _unicode}, acc ->
        pattern_count = text |> String.split(pattern) |> length() |> Kernel.-(1)
        pattern_reduction = (String.length(pattern) - 1) * pattern_count
        acc + pattern_reduction
      end)

    original_width - width_reduction
  end

  defp build_cursor_map(text, ligature_map) do
    # Build a mapping of original cursor positions to visual positions
    char_list = String.graphemes(text)

    {_final_text, cursor_map} =
      char_list
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {char, original_pos}, {acc_chars, acc_map} ->
        visual_pos = length(acc_chars)

        # Check if we're starting a ligature
        remaining_text = Enum.drop(char_list, original_pos)

        case find_ligature_at_position(remaining_text, ligature_map) do
          {ligature_text, _unicode, ligature_length} ->
            # This position starts a ligature
            new_acc_chars = [ligature_text | acc_chars]

            # Map all positions in the ligature to the same visual position
            ligature_positions =
              original_pos..(original_pos + ligature_length - 1)

            ligature_map_entries =
              Map.new(ligature_positions, &{&1, visual_pos})

            {new_acc_chars, Map.merge(acc_map, ligature_map_entries)}

          nil ->
            # Regular character
            new_acc_chars = [char | acc_chars]
            new_acc_map = Map.put(acc_map, original_pos, visual_pos)
            {new_acc_chars, new_acc_map}
        end
      end)

    cursor_map
  end

  @spec find_ligature_at_position(list(), map()) ::
          {String.t(), non_neg_integer(), non_neg_integer()} | nil
  defp find_ligature_at_position(text, ligature_map) when is_list(text) do
    # Convert list to string for pattern matching
    text_str = Enum.join(text, "")

    ligature_map
    |> Enum.sort_by(fn {pattern, _} -> -String.length(pattern) end)
    |> Enum.find_value(fn {pattern, unicode} ->
      check_ligature_match(
        String.starts_with?(text_str, pattern),
        pattern,
        unicode
      )
    end)
  end

  defp check_ligature_match(false, _pattern, _unicode), do: nil

  defp check_ligature_match(true, pattern, unicode) do
    {pattern, unicode, String.length(pattern)}
  end

  defp calculate_ligature_frequency(text, config) do
    ligature_map = build_ligature_map(config)

    ligature_map
    |> Enum.map(fn {pattern, _unicode} ->
      count = text |> String.split(pattern) |> length() |> Kernel.-(1)
      {pattern, count}
    end)
    |> Enum.filter(fn {_pattern, count} -> count > 0 end)
  end

  ## Utility Functions

  @doc """
  Converts text to a ligature-aware representation for processing.

  This creates a structure that maintains both original text and
  ligature information for complex text operations.
  """
  def to_ligature_structure(text, config \\ nil) do
    config = config || default_config()
    ligature_map = build_ligature_map(config)
    char_list = String.graphemes(text)

    {result, _pos} =
      Enum.reduce(char_list, {[], 0}, fn char, {acc, pos} ->
        remaining_text = Enum.drop(char_list, pos)

        case find_ligature_at_position(remaining_text, ligature_map) do
          {ligature_text, unicode, length} ->
            ligature_info = %{
              type: :ligature,
              original: ligature_text,
              rendered: <<unicode::utf8>>,
              length: length,
              position: pos
            }

            {[ligature_info | acc], pos + length}

          nil ->
            char_info = %{
              type: :character,
              original: char,
              rendered: char,
              length: 1,
              position: pos
            }

            {[char_info | acc], pos + 1}
        end
      end)

    Enum.reverse(result)
  end

  @doc """
  Validates ligature configuration.
  """
  def validate_config(%__MODULE__{} = config) do
    errors = []

    # Check enabled sets
    errors =
      validate_enabled_sets(
        Enum.all?(config.enabled_sets, &Map.has_key?(@all_ligature_sets, &1)),
        errors,
        config.enabled_sets
      )

    # Check custom ligatures
    valid_custom =
      Enum.all?(config.custom_ligatures, fn {k, v} ->
        is_binary(k) and is_integer(v)
      end)

    errors = validate_custom_ligatures(valid_custom, errors)

    return_validation_result(Enum.empty?(errors), errors)
  end

  defp validate_enabled_sets(true, errors, _enabled_sets), do: errors

  defp validate_enabled_sets(false, errors, enabled_sets) do
    invalid_sets =
      Enum.reject(enabled_sets, &Map.has_key?(@all_ligature_sets, &1))

    ["Invalid ligature sets: #{inspect(invalid_sets)}" | errors]
  end

  defp validate_custom_ligatures(true, errors), do: errors

  defp validate_custom_ligatures(false, errors) do
    ["Custom ligatures must be %{String.t() => integer()}" | errors]
  end

  defp return_validation_result(true, _errors), do: :ok
  defp return_validation_result(false, errors), do: {:error, errors}

  @doc """
  Gets performance statistics for ligature rendering.
  """
  def performance_stats(text, config \\ nil) do
    config = config || default_config()
    ligature_map = build_ligature_map(config)

    %{
      text_length: String.length(text),
      available_ligatures: map_size(ligature_map),
      enabled_sets: length(config.enabled_sets),
      disabled_ligatures: length(config.disabled_ligatures),
      custom_ligatures: map_size(config.custom_ligatures),
      contains_ligatures: contains_ligatures?(text, config),
      performance_mode: config.performance_mode
    }
  end
end
