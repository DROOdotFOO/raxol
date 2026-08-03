import ExUnit.Assertions
import ExUnit.Callbacks

defmodule Raxol.Terminal.DriverTestHelper do
  @moduledoc """
  Helper module for terminal driver tests providing common test utilities and fixtures.

  `feed_input/2` feeds fabricated `{:trace, ...}` messages -- the same shape
  prim_tty's reader emits -- to drive the REAL input path: Driver
  `buffer_and_dispatch` -> `Raxol.Terminal.ANSI.InputParser` -> dispatch of a
  decoded `%Raxol.Core.Events.Event{}` to the driver's dispatcher pid. These
  helpers exercise DECODE coverage (byte string in, decoded event out); they
  do NOT verify the prim_tty trace wire protocol itself -- that lives in
  `input_protocol_canary_test`.
  """

  alias Raxol.Core.Events.Event
  alias Raxol.Terminal.Driver

  def start_driver(test_pid) do
    IO.puts("[TestHelper] Starting driver with test_pid: #{inspect(test_pid)}")
    {:ok, driver_pid} = Driver.start_link(test_pid)
    IO.puts("[TestHelper] Driver started with pid: #{inspect(driver_pid)}")
    driver_pid
  end

  def wait_for_driver_ready(driver_pid, timeout \\ 500) do
    wait_for_driver_ready_recursive(
      driver_pid,
      timeout,
      System.monotonic_time(:millisecond)
    )
  end

  defp wait_for_driver_ready_recursive(driver_pid, timeout, start_time) do
    current_time = System.monotonic_time(:millisecond)
    remaining_timeout = timeout - (current_time - start_time)

    if remaining_timeout <= 0 do
      flunk("Timeout waiting for {:driver_ready, \\#{inspect(driver_pid)}}")
    else
      receive do
        {:driver_ready, ^driver_pid} ->
          :ok

        {:driver_ready, other_pid} ->
          assert other_pid == driver_pid

        {:EXIT, _port, :normal} ->
          # Ignore normal port exits (from stty calls)
          wait_for_driver_ready_recursive(driver_pid, timeout, start_time)

        other ->
          flunk("Expected {:driver_ready, \\#{inspect(driver_pid)}}, got: \\#{inspect(other)}")
      after
        remaining_timeout ->
          flunk("Timeout waiting for {:driver_ready, \\#{inspect(driver_pid)}}")
      end
    end
  end

  def consume_initial_resize(timeout \\ 500) do
    assert_receive {:"$gen_cast", {:dispatch, %Event{type: :resize}}}, timeout
  end

  @doc """
  Feeds raw input bytes to the driver via the REAL input path.

  Wraps the bytes in the `{:trace, ...}` message shape prim_tty's reader
  emits, so the driver runs `buffer_and_dispatch/2` ->
  `Raxol.Terminal.ANSI.InputParser` -> dispatch, exactly as in production.
  """
  def feed_input(driver_pid, bytes) when is_binary(bytes) do
    send(driver_pid, {:trace, self(), :send, {make_ref(), {:data, bytes}}, self()})
  end

  @doc """
  Asserts a decoded printable-character key event.

  The parser emits `%{key: :char, char: <<byte>>}` with no modifier fields
  when none are set (`InputParser.key_event/2` drops false modifiers).
  """
  def assert_char_key(char) when is_binary(char) do
    assert_receive {:"$gen_cast",
                    {:dispatch, %Event{type: :key, data: %{key: :char, char: ^char}}}},
                   500
  end

  @doc """
  Asserts a decoded special (non-printable) key event, e.g. `:up`, `:escape`.

  The parser emits `%{key: key}` with no `:char` field for these.
  """
  def assert_special_key(key) when is_atom(key) do
    assert_receive {:"$gen_cast", {:dispatch, %Event{type: :key, data: %{key: ^key} = data}}},
                   500

    refute Map.has_key?(data, :char),
           "special key #{inspect(key)} unexpectedly carried a :char field"
  end

  def assert_mouse_event(x, y, button) do
    assert_receive {:"$gen_cast",
                    {:dispatch,
                     %Event{
                       type: :mouse,
                       data: %{x: ^x, y: ^y, button: ^button}
                     }}},
                   500
  end

  def assert_resize_event(width, height) do
    assert_receive {:"$gen_cast",
                    {:dispatch,
                     %Event{
                       type: :resize,
                       data: %{width: ^width, height: ^height}
                     }}},
                   2000
  end

  def setup_terminal do
    original_stty =
      case System.cmd("stty", ["-g"]) do
        {output, 0} -> String.trim(output)
        {_error, _exit_code} -> nil
      end

    on_exit(fn ->
      if original_stty do
        System.cmd("stty", [original_stty])
      end
    end)

    %{original_stty: original_stty}
  end
end
