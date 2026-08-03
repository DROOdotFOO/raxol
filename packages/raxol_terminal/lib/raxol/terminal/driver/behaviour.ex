defmodule Raxol.Terminal.Driver.Behaviour do
  @moduledoc """
  Behaviour specification for terminal drivers.

  This behaviour defines the contract that terminal drivers must implement
  to provide terminal I/O functionality. Different implementations can
  provide native (NIF-based), pure Elixir, or web-based terminal support.

  ## Implementations

  - `Raxol.Terminal.Driver` - Main driver with automatic backend selection
  - `Raxol.Terminal.IOTerminal` - Pure Elixir implementation

  ## Example Implementation

      defmodule MyTerminalDriver do
        @behaviour Raxol.Terminal.Driver.Behaviour

        @impl true
        def init(opts) do
          # Initialize terminal
          {:ok, %{}}
        end

        @impl true
        def shutdown(state) do
          # Cleanup
          :ok
        end

        # ... implement other callbacks
      end
  """

  @typedoc "Driver state - implementation specific"
  @type state :: term()

  @typedoc "Terminal dimensions"
  @type dimensions :: {width :: pos_integer(), height :: pos_integer()}

  @typedoc "Terminal event"
  @type event ::
          {:key, key_data :: map()}
          | {:mouse, mouse_data :: map()}
          | {:resize, width :: pos_integer(), height :: pos_integer()}
          | {:paste, content :: String.t()}

  @typedoc "Color specification"
  @type color ::
          atom() | non_neg_integer() | {r :: 0..255, g :: 0..255, b :: 0..255}

  @typedoc "Cell attributes"
  @type attributes :: %{
          optional(:fg) => color(),
          optional(:bg) => color(),
          optional(:bold) => boolean(),
          optional(:italic) => boolean(),
          optional(:underline) => boolean(),
          optional(:reverse) => boolean(),
          optional(:blink) => boolean()
        }

  # ============================================================================
  # Lifecycle Callbacks
  # ============================================================================

  @doc """
  Initialize the terminal driver.

  Called when the driver process starts. Should set up the terminal
  for raw input mode and prepare for rendering.

  ## Options

  Implementation-specific options may include:
  - `:width` - Initial width (for testing)
  - `:height` - Initial height (for testing)
  - `:output_device` - Output device (default: :stdio)

  ## Returns

  - `{:ok, state}` - Initialization successful
  - `{:error, reason}` - Initialization failed
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Shut down the terminal driver.

  Called when the driver process terminates. Should restore the terminal
  to its original state.
  """
  @callback shutdown(state()) :: :ok

  # ============================================================================
  # Terminal Size
  # ============================================================================

  @doc """
  Get the current terminal dimensions.

  Returns the width and height in character cells.
  """
  @callback get_size(state()) :: {:ok, dimensions()} | {:error, term()}

  # ============================================================================
  # Cursor Operations
  # ============================================================================

  @doc """
  Move the cursor to the specified position.

  Coordinates are 0-indexed, with (0, 0) at the top-left corner.
  """
  @callback move_cursor(state(), x :: non_neg_integer(), y :: non_neg_integer()) ::
              {:ok, state()} | {:error, term()}

  @doc """
  Show or hide the cursor.
  """
  @callback set_cursor_visible(state(), visible :: boolean()) ::
              {:ok, state()} | {:error, term()}

  @doc """
  Get the current cursor position.
  """
  @callback get_cursor_position(state()) ::
              {:ok, {x :: non_neg_integer(), y :: non_neg_integer()}}
              | {:error, term()}

  # ============================================================================
  # Output Operations
  # ============================================================================

  @doc """
  Write a string at the current cursor position.
  """
  @callback write(state(), content :: String.t()) ::
              {:ok, state()} | {:error, term()}

  @doc """
  Write a string at the specified position with optional attributes.
  """
  @callback write_at(
              state(),
              x :: non_neg_integer(),
              y :: non_neg_integer(),
              content :: String.t(),
              attrs :: attributes()
            ) :: {:ok, state()} | {:error, term()}

  @doc """
  Clear the entire screen.
  """
  @callback clear(state()) :: {:ok, state()} | {:error, term()}

  @doc """
  Clear from cursor to end of line.
  """
  @callback clear_line(state()) :: {:ok, state()} | {:error, term()}

  @doc """
  Flush any buffered output to the terminal.
  """
  @callback flush(state()) :: {:ok, state()} | {:error, term()}

  # ============================================================================
  # Styling
  # ============================================================================

  @doc """
  Set the foreground color for subsequent output.
  """
  @callback set_foreground(state(), color()) ::
              {:ok, state()} | {:error, term()}

  @doc """
  Set the background color for subsequent output.
  """
  @callback set_background(state(), color()) ::
              {:ok, state()} | {:error, term()}

  @doc """
  Set text attributes for subsequent output.
  """
  @callback set_attributes(state(), attributes()) ::
              {:ok, state()} | {:error, term()}

  @doc """
  Reset all styling to defaults.
  """
  @callback reset_style(state()) :: {:ok, state()} | {:error, term()}

  # Input is not polled through this behaviour. On Unix the local driver receives
  # keystrokes as messages from OTP's prim_tty reader (see Driver's `{:trace, ...}`
  # handler); SSH and LiveView input ride their own transports.

  # ============================================================================
  # Optional Callbacks
  # ============================================================================

  @doc """
  Set the terminal title.

  This is an optional callback - implementations may return `{:ok, state}`
  without taking action if not supported.
  """
  @callback set_title(state(), title :: String.t()) ::
              {:ok, state()} | {:error, term()}

  @doc """
  Enable or disable mouse input.

  This is an optional callback - implementations may return `{:ok, state}`
  without taking action if not supported.
  """
  @callback set_mouse_enabled(state(), enabled :: boolean()) ::
              {:ok, state()} | {:error, term()}

  @doc """
  Enable or disable bracketed paste mode.

  This is an optional callback - implementations may return `{:ok, state}`
  without taking action if not supported.
  """
  @callback set_bracketed_paste(state(), enabled :: boolean()) ::
              {:ok, state()} | {:error, term()}

  @optional_callbacks [
    set_title: 2,
    set_mouse_enabled: 2,
    set_bracketed_paste: 2
  ]
end
