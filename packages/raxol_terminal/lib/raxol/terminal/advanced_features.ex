defmodule Raxol.Terminal.AdvancedFeatures do
  @moduledoc """
  Implements advanced terminal features for modern terminal emulators.

  This module provides support for:
  - OSC 8 Hyperlinks - Clickable links in terminal output
  - OSC 9 / 9;4 Ambient signals - Desktop notifications and taskbar/dock progress
  - OSC 22 Pointer shape - Mouse cursor shape hints
  - Synchronized Output (DEC 2026) - Flicker-free rendering
  - Focus Events - Terminal focus/blur detection
  - Enhanced Bracketed Paste - Improved paste handling
  - Window Manipulation - Advanced terminal control

  These features enable rich, interactive terminal applications with modern UX patterns.
  """

  @type hyperlink_id :: String.t()
  @type url :: String.t()
  @type hyperlink_params :: %{
          optional(:id) => hyperlink_id(),
          optional(:tooltip) => String.t(),
          optional(:params) => map()
        }
  @type progress_state :: :remove | :set | :error | :indeterminate | :warning

  # OSC 8 Hyperlink Implementation

  @doc """
  Creates a clickable hyperlink using OSC 8 escape sequences.

  ## Parameters

  - `text` - The text to display as clickable
  - `url` - The URL to open when clicked
  - `options` - Additional hyperlink options

  ## Examples

      iex> AdvancedFeatures.create_hyperlink("Visit GitHub", "https://github.com")
      "\\e]8;;https://github.com\\e\\\\Visit GitHub\\e]8;;\\e\\\\"

      iex> AdvancedFeatures.create_hyperlink("Click me", "https://example.com", %{
      ...>   id: "link1",
      ...>   tooltip: "Opens example.com"
      ...> })
  """
  @spec create_hyperlink(String.t(), url(), hyperlink_params()) :: String.t()
  def create_hyperlink(text, url, options \\ %{}) do
    # Build OSC 8 parameters
    params = build_osc8_params(options)

    param_string =
      case params do
        "" -> ""
        _ -> "#{params}:"
      end

    # OSC 8 format: \e]8;params;url\e\text\e]8;;\e\
    "\e]8;#{param_string}#{url}\e\\#{text}\e]8;;\e\\"
  end

  @doc """
  Creates multiple hyperlinks with shared parameters.

  ## Examples

      links = [
        {"GitHub", "https://github.com"},
        {"GitLab", "https://gitlab.com"}
      ]

      AdvancedFeatures.create_hyperlinks(links, %{tooltip: "Git repository"})
  """
  @spec create_hyperlinks([{String.t(), url()}], hyperlink_params()) :: [
          String.t()
        ]
  def create_hyperlinks(text_url_pairs, shared_options \\ %{}) do
    Enum.map(text_url_pairs, fn {text, url} ->
      create_hyperlink(text, url, shared_options)
    end)
  end

  @doc """
  Detects if the current terminal supports OSC 8 hyperlinks.
  """
  @spec supports_hyperlinks?() :: boolean()
  def supports_hyperlinks? do
    # Check environment variables and terminal type
    terminal_type = System.get_env("TERM_PROGRAM") || ""
    term = System.get_env("TERM") || ""

    case {terminal_type, term} do
      {"iTerm.app", _} ->
        true

      {"WezTerm", _} ->
        true

      {"kitty", _} ->
        true

      {"Alacritty", _} ->
        true

      {_, term} when term in ["xterm-kitty", "screen-256color"] ->
        true

      _ ->
        # Try to detect by querying terminal capabilities
        query_hyperlink_support()
    end
  end

  # OSC 9 / 9;4 Ambient Signal Implementation

  @doc """
  Sends a desktop notification using OSC 9.

  ## Examples

      iex> AdvancedFeatures.notify("Build finished")
      "\\e]9;Build finished\\e\\\\"
  """
  @spec notify(String.t()) :: String.t()
  def notify(message) do
    "\e]9;#{message}\e\\"
  end

  @doc """
  Reports progress on the host terminal's dock/taskbar icon using OSC 9;4.

  `state` is one of `:remove`, `:set`, `:error`, `:indeterminate`, or `:warning`.
  `value` is the progress percentage (0-100), ignored by most terminals for
  `:remove` and `:indeterminate`.

  ## Examples

      iex> AdvancedFeatures.report_progress(:set, 42)
      "\\e]9;4;1;42\\e\\\\"

      iex> AdvancedFeatures.report_progress(:remove)
      "\\e]9;4;0;0\\e\\\\"
  """
  @spec report_progress(progress_state(), 0..100) :: String.t()
  def report_progress(state, value \\ 0) do
    "\e]9;4;#{progress_state_code(state)};#{value}\e\\"
  end

  @doc """
  Clears any taskbar/dock progress previously set via `report_progress/2`.
  """
  @spec clear_progress() :: String.t()
  def clear_progress, do: report_progress(:remove, 0)

  defp progress_state_code(:remove), do: 0
  defp progress_state_code(:set), do: 1
  defp progress_state_code(:error), do: 2
  defp progress_state_code(:indeterminate), do: 3
  defp progress_state_code(:warning), do: 4

  # OSC 22 Pointer Shape Implementation

  @doc """
  Sets the mouse pointer shape using OSC 22.

  `shape` is a CSS-style cursor keyword, e.g. `"default"`, `"text"`,
  `"pointer"`, `"wait"`, `"crosshair"`.

  ## Examples

      iex> AdvancedFeatures.set_pointer_shape("pointer")
      "\\e]22;pointer\\e\\\\"
  """
  @spec set_pointer_shape(String.t()) :: String.t()
  def set_pointer_shape(shape) do
    "\e]22;#{shape}\e\\"
  end

  # Synchronized Output (DEC 2026) Implementation

  @doc """
  Enables synchronized output mode for flicker-free rendering.

  When enabled, terminal output is buffered until explicitly flushed,
  preventing screen flickering during complex updates.

  ## Examples

      AdvancedFeatures.begin_synchronized_output()
      # ... perform multiple terminal updates ...
      AdvancedFeatures.end_synchronized_output()
  """
  @spec begin_synchronized_output() :: :ok
  def begin_synchronized_output do
    # DEC 2026: Begin Synchronized Output
    IO.write("\e[?2026h")
    :ok
  end

  @doc """
  Disables synchronized output mode and flushes buffered content.
  """
  @spec end_synchronized_output() :: :ok
  def end_synchronized_output do
    # DEC 2026: End Synchronized Output
    IO.write("\e[?2026l")
    :ok
  end

  @doc """
  Executes a function with synchronized output enabled.

  ## Examples

      AdvancedFeatures.with_synchronized_output(fn ->
        Log.info("Line 1")
        Log.info("Line 2")
        # These will appear atomically
      end)
  """
  @spec with_synchronized_output((-> any())) :: any()
  def with_synchronized_output(fun) when is_function(fun, 0) do
    begin_synchronized_output()

    try do
      fun.()
    after
      end_synchronized_output()
    end
  end

  @doc """
  Detects if the terminal supports synchronized output.
  """
  @spec supports_synchronized_output?() :: boolean()
  def supports_synchronized_output? do
    terminal_type = System.get_env("TERM_PROGRAM") || ""

    case terminal_type do
      "kitty" -> true
      "WezTerm" -> true
      "iTerm.app" -> check_iterm_version_for_sync()
      _ -> query_synchronized_output_support()
    end
  end

  # Focus Events Implementation

  @doc """
  Enables terminal focus events.

  When enabled, the terminal will send escape sequences when it gains
  or loses focus, allowing applications to respond to focus changes.
  """
  @spec enable_focus_events() :: :ok
  def enable_focus_events do
    # Enable focus reporting: CSI ? 1004 h
    IO.write("\e[?1004h")
    :ok
  end

  @doc """
  Disables terminal focus events.
  """
  @spec disable_focus_events() :: :ok
  def disable_focus_events do
    # Disable focus reporting: CSI ? 1004 l
    IO.write("\e[?1004l")
    :ok
  end

  @doc """
  Parses focus event sequences.

  Returns:
  - `{:focus_in}` - Terminal gained focus
  - `{:focus_out}` - Terminal lost focus
  - `{:unknown, data}` - Unrecognized sequence
  """
  @spec parse_focus_event(binary()) ::
          {:focus_in} | {:focus_out} | {:unknown, binary()}
  def parse_focus_event("\e[I"), do: {:focus_in}
  def parse_focus_event("\e[O"), do: {:focus_out}
  def parse_focus_event(data), do: {:unknown, data}

  # Enhanced Bracketed Paste Implementation

  @doc """
  Enables enhanced bracketed paste mode.

  This prevents pasted content from being interpreted as terminal commands
  and provides better handling of multiline pastes.
  """
  @spec enable_bracketed_paste() :: :ok
  def enable_bracketed_paste do
    # Enable bracketed paste: CSI ? 2004 h
    IO.write("\e[?2004h")
    :ok
  end

  @doc """
  Disables bracketed paste mode.
  """
  @spec disable_bracketed_paste() :: :ok
  def disable_bracketed_paste do
    # Disable bracketed paste: CSI ? 2004 l
    IO.write("\e[?2004l")
    :ok
  end

  @doc """
  Parses bracketed paste sequences.

  Returns:
  - `{:paste_start}` - Beginning of pasted content
  - `{:paste_end}` - End of pasted content
  - `{:paste_content, data}` - Pasted content
  """
  @spec parse_paste_event(binary()) ::
          {:paste_start}
          | {:paste_end}
          | {:paste_content, binary()}
  def parse_paste_event("\e[200~"), do: {:paste_start}
  def parse_paste_event("\e[201~"), do: {:paste_end}
  def parse_paste_event(data), do: {:paste_content, data}

  # Window Manipulation Implementation

  @doc """
  Gets the current terminal window size.

  Returns `{:ok, {width, height}}` or `{:error, reason}`.
  """
  @spec get_window_size() ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, term()}
  def get_window_size do
    # Query terminal size: CSI 18 t
    IO.write("\e[18t")

    # In a real implementation, this would wait for the response
    # For now, fall back to environment variables
    case {System.get_env("COLUMNS"), System.get_env("LINES")} do
      {width_str, height_str}
      when is_binary(width_str) and is_binary(height_str) ->
        with {width, ""} <- Integer.parse(width_str),
             {height, ""} <- Integer.parse(height_str) do
          {:ok, {width, height}}
        else
          _ -> {:error, :invalid_size_format}
        end

      _ ->
        {:error, :size_not_available}
    end
  end

  @doc """
  Sets the terminal window title.
  """
  @spec set_window_title(String.t()) :: :ok
  def set_window_title(title) do
    # OSC 0 or OSC 2: Set window title
    IO.write("\e]0;#{title}\e\\")
    :ok
  end

  @doc """
  Gets current terminal capabilities and features.
  """
  @spec get_terminal_capabilities() :: %{
          hyperlinks: boolean(),
          synchronized_output: boolean(),
          focus_events: boolean(),
          bracketed_paste: boolean(),
          window_manipulation: boolean(),
          terminal_type: String.t(),
          term_variable: String.t()
        }
  def get_terminal_capabilities do
    %{
      hyperlinks: supports_hyperlinks?(),
      synchronized_output: supports_synchronized_output?(),
      focus_events: supports_focus_events?(),
      bracketed_paste: supports_bracketed_paste?(),
      window_manipulation: supports_window_manipulation?(),
      terminal_type: System.get_env("TERM_PROGRAM") || "unknown",
      term_variable: System.get_env("TERM") || "unknown"
    }
  end

  # Private Helper Functions

  defp build_osc8_params(options) do
    params = []

    params =
      case Map.get(options, :id) do
        nil -> params
        id -> ["id=#{id}" | params]
      end

    params =
      case Map.get(options, :tooltip) do
        nil -> params
        tooltip -> ["tooltip=#{URI.encode(tooltip)}" | params]
      end

    # Add custom parameters
    params =
      case Map.get(options, :params) do
        nil ->
          params

        custom_params when is_map(custom_params) ->
          Enum.reduce(custom_params, params, fn {key, value}, acc ->
            ["#{key}=#{URI.encode(to_string(value))}" | acc]
          end)

        _ ->
          params
      end

    Enum.join(params, ":")
  end

  defp query_hyperlink_support do
    # In a real implementation, this would query terminal capabilities
    # For now, return false as the safe default
    false
  end

  defp query_synchronized_output_support do
    # Query for DEC 2026 support
    # This would involve sending a query and waiting for response
    false
  end

  defp check_iterm_version_for_sync do
    # Check if iTerm2 version supports synchronized output
    # Requires iTerm2 3.4+
    case System.get_env("TERM_PROGRAM_VERSION") do
      nil ->
        false

      version_str ->
        case parse_version(version_str) do
          {:ok, {major, minor, _patch}}
          when major > 3 or (major == 3 and minor >= 4) ->
            true

          _ ->
            false
        end
    end
  end

  defp parse_version(version_str) do
    case String.split(version_str, ".") do
      [major, minor, patch] ->
        with {maj, ""} <- Integer.parse(major),
             {min, ""} <- Integer.parse(minor),
             {pat, ""} <- Integer.parse(patch) do
          {:ok, {maj, min, pat}}
        else
          _ -> {:error, :invalid_version}
        end

      _ ->
        {:error, :invalid_version}
    end
  end

  defp supports_focus_events? do
    # Most modern terminals support focus events
    terminal_type = System.get_env("TERM_PROGRAM") || ""
    terminal_type != ""
  end

  defp supports_bracketed_paste? do
    # Almost all modern terminals support bracketed paste
    term = System.get_env("TERM") || ""
    not String.starts_with?(term, "dumb")
  end

  defp supports_window_manipulation? do
    # Check for window manipulation support
    terminal_type = System.get_env("TERM_PROGRAM") || ""
    terminal_type in ["iTerm.app", "kitty", "WezTerm", "Alacritty"]
  end
end
