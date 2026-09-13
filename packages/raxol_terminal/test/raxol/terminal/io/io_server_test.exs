defmodule Raxol.Terminal.IO.IOServerTest do
  use ExUnit.Case, async: false

  alias Raxol.Terminal.IO.IOServer

  setup do
    # Start the IOServer process with a unique name for this test
    {:ok, pid} = IOServer.start_link(name: :unified_io_test)
    %{pid: pid}
  end

  describe "initialization" do
    test "initializes with default values", %{pid: pid} do
      assert :ok =
               IOServer.init_terminal(
                 80,
                 24,
                 %{
                   scrollback_limit: 1000,
                   memory_limit: 50 * 1024 * 1024,
                   command_history_limit: 1000,
                   rendering: %{
                     fps: 60,
                     theme: %{
                       foreground: :white,
                       background: :black
                     },
                     font_settings: %{
                       size: 12
                     }
                   }
                 },
                 pid
               )
    end

    test "initializes with custom config", %{pid: pid} do
      custom_config = %{
        scrollback_limit: 2000,
        memory_limit: 100 * 1024 * 1024,
        command_history_limit: 2000,
        rendering: %{
          fps: 30,
          theme: %{
            foreground: :green,
            background: :black
          },
          font_settings: %{
            size: 14
          }
        }
      }

      assert :ok = IOServer.init_terminal(100, 40, custom_config, pid)
    end
  end

  describe "input processing" do
    test "processes keyboard input", %{pid: pid} do
      assert {:ok, []} = IOServer.process_input(%{type: :key, key: "a"}, pid)
    end

    test "processes special keys", %{pid: pid} do
      assert {:ok, []} =
               IOServer.process_input(%{type: :special_key, key: :up}, pid)

      assert {:ok, []} =
               IOServer.process_input(%{type: :special_key, key: :down}, pid)

      assert {:ok, []} =
               IOServer.process_input(%{type: :special_key, key: :enter}, pid)
    end

    test "processes mouse events", %{pid: pid} do
      mouse_event = %{
        type: :mouse,
        event_type: :press,
        button: 1,
        x: 10,
        y: 20
      }

      assert {:ok, []} = IOServer.process_input(mouse_event, pid)
    end

    test "handles invalid input events", %{pid: pid} do
      assert {:ok, []} = IOServer.process_input(%{type: :invalid}, pid)
    end
  end

  describe "output processing" do
    test "processes output data", %{pid: pid} do
      assert {:ok, []} = IOServer.process_output("Hello, World!\n", pid)
    end

    test "processes multiline output", %{pid: pid} do
      multiline = "Line 1\nLine 2\nLine 3\n"
      assert {:ok, []} = IOServer.process_output(multiline, pid)
    end

    test "handles empty output", %{pid: pid} do
      assert {:ok, []} = IOServer.process_output("", pid)
    end
  end

  describe "configuration" do
    test "updates configuration", %{pid: pid} do
      new_config = %{
        scrollback_limit: 2000,
        memory_limit: 100 * 1024 * 1024,
        command_history_limit: 2000,
        rendering: %{
          fps: 30,
          theme: %{
            foreground: :green,
            background: :black
          },
          font_settings: %{
            size: 14
          }
        }
      }

      assert :ok = IOServer.update_config(new_config, pid)
    end

    test "sets individual config values", %{pid: pid} do
      assert :ok = IOServer.set_config_value([:rendering, :fps], 30, pid)
      assert :ok = IOServer.set_config_value([:scrollback_limit], 2000, pid)
    end

    test "resets configuration to defaults", %{pid: pid} do
      assert :ok = IOServer.reset_config(pid)
    end
  end

  describe "terminal operations" do
    test "resizes terminal", %{pid: pid} do
      assert :ok = IOServer.resize(100, 40, pid)
    end

    test "sets cursor visibility", %{pid: pid} do
      assert :ok = IOServer.set_cursor_visibility(true, pid)
      assert :ok = IOServer.set_cursor_visibility(false, pid)
    end
  end

  # Throughput budgets live in `bench/` (and the regression workflow's
  # parser/render targets), not here: the old `:timer.tc` ceilings of 1ms
  # per key event and 10ms per 1000 lines measured a loaded runner more
  # than the server. What the suite pins is that every event in a long run
  # is accepted and answered.
  describe "bulk input and output" do
    test "accepts a thousand input events in order", %{pid: pid} do
      events =
        for i <- 1..1000 do
          %{type: :key, key: "a#{i}"}
        end

      for event <- events do
        assert {:ok, _} = IOServer.process_input(event, pid)
      end
    end

    test "accepts a thousand lines of output in one write", %{pid: pid} do
      large_output = String.duplicate("Hello, World!\n", 1000)

      assert {:ok, _} = IOServer.process_output(large_output, pid)
    end
  end
end
