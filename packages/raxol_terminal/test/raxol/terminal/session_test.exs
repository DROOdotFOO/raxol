defmodule Raxol.Terminal.SessionTest do
  use ExUnit.Case, async: false
  alias Raxol.Terminal.Renderer
  alias Raxol.Terminal.ScreenBuffer
  alias Raxol.Terminal.Session

  setup do
    # Clean up any existing session files
    File.rm_rf!(".tmp/sessions")
    File.mkdir_p!(".tmp/sessions")

    {:ok, pid} = Session.start_link(id: "test_session")
    %{pid: pid}
  end

  defp minimal_session_struct(id, width, height, title, theme) do
    # Create a minimal screen buffer with just 1x1 cells to avoid serialization issues
    minimal_cells = [
      [
        %Raxol.Terminal.Cell{
          char: " ",
          style: Raxol.Terminal.ANSI.TextFormatting.new(),
          dirty: false,
          wide_placeholder: false
        }
      ]
    ]

    minimal_screen_buffer = %ScreenBuffer{
      width: 1,
      height: 1,
      cells: minimal_cells,
      cursor_position: {0, 0}
    }

    # Create minimal emulator using the constructor
    minimal_emulator = Raxol.Terminal.Emulator.new(1, 1)

    # Create minimal renderer
    minimal_renderer = %Renderer{
      screen_buffer: minimal_screen_buffer,
      theme: theme
    }

    # Create the session struct
    %Raxol.Terminal.Session{
      id: id,
      emulator: minimal_emulator,
      renderer: minimal_renderer,
      width: width,
      height: height,
      title: title,
      theme: theme,
      auto_save: true
    }
  end

  describe "session persistence" do
    test "can save and load a session", %{pid: pid} do
      # Create a minimal session state for testing
      minimal_state =
        minimal_session_struct("test_session", 1, 1, "Test Session", %{
          background: :black
        })

      # Inject the minimal state into the GenServer
      :sys.replace_state(pid, fn _current_state -> minimal_state end)

      # Save the session
      assert :ok = Session.save_session(pid)

      # Load the session
      assert {:ok, new_pid} = Session.load_session("test_session")
      assert Process.alive?(new_pid)

      # Clean up
      Session.stop(new_pid)
    end

    test "can disable auto-save", %{pid: pid} do
      # Create a minimal session state
      minimal_state =
        minimal_session_struct("test_session", 1, 1, "Test Session", %{
          background: :black
        })

      minimal_state = %{minimal_state | auto_save: false}

      # Inject the minimal state into the GenServer
      :sys.replace_state(pid, fn _current_state -> minimal_state end)

      # Save the session
      assert :ok = Session.save_session(pid)

      # Load the session and verify auto_save is false
      assert {:ok, new_pid} = Session.load_session("test_session")
      new_state = :sys.get_state(new_pid)
      assert new_state.auto_save == false

      # Clean up
      Session.stop(new_pid)
    end

    test "can recover from saved state", %{pid: pid} do
      # Create a minimal session state with some content
      minimal_state =
        minimal_session_struct("test_session", 1, 1, "Test Session", %{
          background: :blue
        })

      # Inject the minimal state into the GenServer
      :sys.replace_state(pid, fn _current_state -> minimal_state end)

      # Save the session
      assert :ok = Session.save_session(pid)

      # Load the session and verify the state is preserved
      assert {:ok, new_pid} = Session.load_session("test_session")
      loaded_state = :sys.get_state(new_pid)

      assert loaded_state.id == "test_session"
      assert loaded_state.width == 1
      assert loaded_state.height == 1
      assert loaded_state.title == "Test Session"
      assert loaded_state.theme == %{background: :blue}

      # Clean up
      Session.stop(new_pid)
    end

    test "session persistence handles invalid session data gracefully" do
      # Test loading non-existent session
      assert {:error, :enoent} = Session.load_session("non_existent_session")
    end
  end
end
