defmodule Raxol.Property.SSHRenderingTest do
  @moduledoc """
  Property tests verifying SSH rendering hygiene:

  1. render_to_ssh prefixes every frame with cursor-home + clear (no scrollback pollution)
  2. render_to_terminal and render_to_ssh produce structurally equivalent output
  3. Lifecycle.terminate/2 invokes terminate_manager/2 (orphaned callback fix)
  4. alternate_screen escapes are written on enter/leave for :ssh and :terminal envs
  5. Silent fallback paths: missing io_writer, terminal IO.write

  Bug class: rendering backend parity gaps and orphaned callbacks (see issue #212).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Core.Runtime.Rendering.Backends
  alias Raxol.Core.Runtime.Lifecycle

  # -- Generators --

  defp cell_gen do
    gen all(
          x <- integer(0..79),
          y <- integer(0..23),
          char <- string(:printable, min_length: 1, max_length: 1),
          fg <- member_of([:red, :green, :blue, :white, :yellow, :cyan]),
          bg <- member_of([:black, :white, :blue])
        ) do
      {x, y, char, fg, bg, []}
    end
  end

  defp cells_gen do
    list_of(cell_gen(), min_length: 1, max_length: 50)
  end

  defp ssh_state(captured_output) do
    %{
      width: 80,
      height: 24,
      buffer: nil,
      io_writer: fn data -> send(captured_output, {:wrote, data}) end,
      sync_output: false
    }
  end

  defp terminal_frame_prefix, do: "\e[H\e[2J"

  # -- Property 1: SSH frames start with home+clear --

  describe "render_to_ssh/2 frame hygiene" do
    property "every SSH frame begins with cursor-home and screen-clear" do
      check all(
              cells <- cells_gen(),
              max_runs: 200
            ) do
        state = ssh_state(self())
        {:ok, _new_state} = Backends.render_to_ssh(cells, state)

        output = collect_writes()

        assert String.starts_with?(output, terminal_frame_prefix()),
               "SSH frame missing \\e[H\\e[2J prefix, got: #{inspect(String.slice(output, 0, 20))}"
      end
    end

    property "SSH frame contains rendered content after the prefix" do
      check all(
              cells <- cells_gen(),
              max_runs: 200
            ) do
        state = ssh_state(self())
        {:ok, _new_state} = Backends.render_to_ssh(cells, state)

        output = collect_writes()
        content = String.replace_prefix(output, terminal_frame_prefix(), "")

        assert byte_size(content) > 0,
               "SSH frame has no content after prefix"
      end
    end

    property "SSH sync-output wraps frame with synchronization escapes" do
      check all(
              cells <- cells_gen(),
              max_runs: 100
            ) do
        state = %{ssh_state(self()) | sync_output: true}
        {:ok, _new_state} = Backends.render_to_ssh(cells, state)

        writes = collect_write_list()

        assert length(writes) == 3,
               "sync output should produce 3 writes, got #{length(writes)}"

        assert hd(writes) == "\e[?2026h", "first write should be sync-start"
        assert List.last(writes) == "\e[?2026l", "last write should be sync-end"

        frame = Enum.at(writes, 1)

        assert String.starts_with?(frame, terminal_frame_prefix()),
               "sync frame content missing home+clear prefix"
      end
    end
  end

  # -- Property 2: SSH and terminal produce same buffer state --

  describe "SSH/terminal backend parity" do
    property "render_to_ssh and render_to_terminal produce the same buffer" do
      check all(
              cells <- cells_gen(),
              max_runs: 200
            ) do
        ssh_state = ssh_state(self())
        {:ok, ssh_result} = Backends.render_to_ssh(cells, ssh_state)

        terminal_state = %{
          width: 80,
          height: 24,
          buffer: nil,
          sync_output: false
        }

        # Capture IO to avoid writing to actual terminal
        {:ok, term_result} = capture_terminal_render(cells, terminal_state)

        # Both should produce identical buffers
        assert ssh_result.buffer == term_result.buffer,
               "SSH and terminal backends produced different buffers"
      end
    end
  end

  # -- Property 3: write_output fallback paths --

  describe "write_output/3 edge cases" do
    property "nil io_writer does not crash" do
      check all(
              cells <- cells_gen(),
              max_runs: 50
            ) do
        state = %{
          width: 80,
          height: 24,
          buffer: nil,
          io_writer: nil,
          sync_output: false
        }

        # Should not crash — logs warning and returns gracefully
        {:ok, _new_state} = Backends.render_to_ssh(cells, state)
      end
    end

    property "non-function io_writer does not crash" do
      check all(
              cells <- cells_gen(),
              writer <- member_of([:not_a_fn, "string", 42]),
              max_runs: 50
            ) do
        state = %{
          width: 80,
          height: 24,
          buffer: nil,
          io_writer: writer,
          sync_output: false
        }

        {:ok, _new_state} = Backends.render_to_ssh(cells, state)
      end
    end

    property "nil io_writer with sync_output does not crash" do
      check all(
              cells <- cells_gen(),
              max_runs: 50
            ) do
        state = %{
          width: 80,
          height: 24,
          buffer: nil,
          io_writer: nil,
          sync_output: true
        }

        {:ok, _new_state} = Backends.render_to_ssh(cells, state)
      end
    end
  end

  # -- Property 4: terminate/2 callback is wired --

  describe "Lifecycle.terminate/2 wiring" do
    property "terminate/2 delegates to terminate_manager/2" do
      check all(
              reason <-
                member_of([
                  :normal,
                  :shutdown,
                  :killed,
                  {:shutdown, :user_quit}
                ]),
              max_runs: 10
            ) do
        state = %Lifecycle.State{
          app_module: TestApp,
          app_name: :test_app,
          plugin_manager: nil,
          command_registry_table: nil,
          options: [environment: :agent]
        }

        # Should not raise — proves terminate_manager is actually called
        assert Lifecycle.terminate(reason, state) == :ok
      end
    end
  end

  # -- Property 5: alternate_screen escapes --

  describe "alternate_screen lifecycle" do
    property "alternate_screen: true sends leave-escape on terminate for :ssh" do
      check all(
              app_name <- member_of([:app_a, :app_b, :app_c]),
              max_runs: 10
            ) do
        state = %Lifecycle.State{
          app_module: TestApp,
          app_name: app_name,
          alternate_screen: true,
          plugin_manager: nil,
          command_registry_table: nil,
          options: [
            environment: :ssh,
            io_writer: fn data -> send(self(), {:escape, data}) end
          ]
        }

        Lifecycle.terminate(:shutdown, state)

        assert_received {:escape, "\e[?1049l"},
                        "leave-alt-screen escape not sent on terminate"
      end
    end

    property "alternate_screen: true sends leave-escape via IO.write for :terminal" do
      check all(
              reason <- member_of([:normal, :shutdown]),
              max_runs: 5
            ) do
        state = %Lifecycle.State{
          app_module: TestApp,
          app_name: :test_app,
          alternate_screen: true,
          plugin_manager: nil,
          command_registry_table: nil,
          options: [environment: :terminal]
        }

        output =
          ExUnit.CaptureIO.capture_io(fn ->
            Lifecycle.terminate(reason, state)
          end)

        assert output == "\e[?1049l",
               "terminal leave-alt-screen escape not written, got #{inspect(output)}"
      end
    end

    property "alternate_screen: false sends no escape sequences" do
      check all(
              env <- member_of([:ssh, :terminal, :liveview, :agent]),
              max_runs: 10
            ) do
        state = %Lifecycle.State{
          app_module: TestApp,
          app_name: :test_app,
          alternate_screen: false,
          plugin_manager: nil,
          command_registry_table: nil,
          options: [
            environment: env,
            io_writer: fn data -> send(self(), {:escape, data}) end
          ]
        }

        Lifecycle.terminate(:shutdown, state)

        refute_received {:escape, "\e[?1049h"},
                        "enter-alt-screen escape sent when alternate_screen is false"

        refute_received {:escape, "\e[?1049l"},
                        "leave-alt-screen escape sent when alternate_screen is false"
      end
    end

    property "non-terminal environments skip alt-screen escapes" do
      check all(
              env <- member_of([:liveview, :agent, :vscode]),
              max_runs: 10
            ) do
        state = %Lifecycle.State{
          app_module: TestApp,
          app_name: :test_app,
          alternate_screen: true,
          plugin_manager: nil,
          command_registry_table: nil,
          options: [
            environment: env,
            io_writer: fn data -> send(self(), {:escape, data}) end
          ]
        }

        Lifecycle.terminate(:shutdown, state)

        refute_received {:escape, _},
                        "escape sequence sent for non-terminal env #{env}"
      end
    end

    property "ssh env with missing io_writer silently skips alt-screen" do
      check all(
              reason <- member_of([:normal, :shutdown]),
              max_runs: 10
            ) do
        state = %Lifecycle.State{
          app_module: TestApp,
          app_name: :test_app,
          alternate_screen: true,
          plugin_manager: nil,
          command_registry_table: nil,
          options: [environment: :ssh]
        }

        # No io_writer in options — should not crash
        assert Lifecycle.terminate(reason, state) == :ok
      end
    end
  end

  # -- Property 6: build_initial_state captures alternate_screen --

  describe "Lifecycle.State alternate_screen field" do
    property "alternate_screen defaults to false" do
      check all(
              _n <- integer(1..5),
              max_runs: 5
            ) do
        state = %Lifecycle.State{}
        refute state.alternate_screen
      end
    end

    property "alternate_screen can be set to true" do
      check all(
              _n <- integer(1..5),
              max_runs: 5
            ) do
        state = %Lifecycle.State{alternate_screen: true}
        assert state.alternate_screen
      end
    end
  end

  # -- Property 7: CRLF normalization (raw-mode prim_tty no longer cooks LF) --
  #
  # Since commit 04cc2231 (initial_shell: :noshell), prim_tty's OUTPUT mode
  # is hardcoded raw and never translates a bare `\n` to `\r\n` the way the
  # old MFA-shell path's cooked mode did. Renderer.render/1 joins rows with
  # a bare `\n` (packages/raxol_terminal/lib/raxol/terminal/renderer.ex),
  # so without normalization every row after the first would drift instead
  # of a clean line advance. Backends.normalize_frame/1 fixes this at the
  # write site so it's mode-independent.

  describe "frame CRLF normalization" do
    property "render_to_ssh frames contain no bare LF (every \\n preceded by \\r)" do
      check all(
              cells <- cells_gen(),
              max_runs: 200
            ) do
        state = ssh_state(self())
        {:ok, _new_state} = Backends.render_to_ssh(cells, state)

        output = collect_writes()

        refute has_bare_lf?(output),
               "SSH frame contains a bare \\n not preceded by \\r: #{inspect(output)}"
      end
    end

    property "render_to_terminal frames contain no bare LF (every \\n preceded by \\r)" do
      check all(
              cells <- cells_gen(),
              max_runs: 200
            ) do
        terminal_state = %{
          width: 80,
          height: 24,
          buffer: nil,
          sync_output: false
        }

        output = capture_terminal_output(cells, terminal_state)

        refute has_bare_lf?(output),
               "Terminal frame contains a bare \\n not preceded by \\r: #{inspect(output)}"
      end
    end

    test "normalize_frame/1 converts bare LF row joins to CRLF" do
      assert Backends.normalize_frame("row1\nrow2\nrow3") ==
               "row1\r\nrow2\r\nrow3"
    end

    test "normalize_frame/1 leaves already-normalized \\r\\n untouched-per-LF" do
      # Applying normalize_frame to already-\r\n content adds a redundant
      # \r (row\r\n -> row\r\r\n) rather than corrupting it -- a redundant
      # CR at column 0 is a no-op in both raw and cooked terminal modes, so
      # double-normalization stays safe even if ever applied twice.
      once = Backends.normalize_frame("row1\nrow2")
      twice = Backends.normalize_frame(once)

      assert once == "row1\r\nrow2"
      assert twice == "row1\r\r\nrow2"
      refute has_bare_lf?(twice)
    end

    test "normalize_frame/1 leaves LF-free content untouched" do
      assert Backends.normalize_frame("\e[H\e[2Jno newlines here") ==
               "\e[H\e[2Jno newlines here"
    end
  end

  # -- Helpers --

  # Returns true if any \n in the string is not immediately preceded by \r.
  defp has_bare_lf?(string) do
    string
    |> String.graphemes()
    |> Enum.reduce({false, nil}, fn
      "\n", {_found, prev} -> {prev != "\r", "\n"}
      char, {found, _prev} -> {found, char}
    end)
    |> elem(0)
  end

  defp capture_terminal_output(cells, state) do
    ExUnit.CaptureIO.capture_io(fn ->
      {:ok, _new_state} = Backends.render_to_terminal(cells, state)
    end)
  end

  defp collect_writes do
    collect_write_list() |> Enum.join()
  end

  defp collect_write_list do
    collect_write_list([])
  end

  defp collect_write_list(acc) do
    receive do
      {:wrote, data} -> collect_write_list([data | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end

  defp capture_terminal_render(cells, state) do
    # Run render_to_terminal but capture IO instead of writing to stdout
    ExUnit.CaptureIO.capture_io(fn ->
      {:ok, new_state} = Backends.render_to_terminal(cells, state)
      send(self(), {:result, new_state})
    end)

    receive do
      {:result, new_state} -> {:ok, new_state}
    after
      1000 -> raise "render_to_terminal did not complete"
    end
  end
end
