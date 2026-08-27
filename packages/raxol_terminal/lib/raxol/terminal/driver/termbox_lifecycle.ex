defmodule Raxol.Terminal.Driver.TermboxLifecycle do
  @moduledoc """
  Termbox NIF initialization, shutdown, and recovery helpers.
  """

  alias Raxol.Core.Runtime.Log
  alias Raxol.Terminal.IOTerminal

  import Raxol.Terminal.TerminalUtils, only: [has_terminal_device?: 0]

  @termbox2_available Code.ensure_loaded?(:termbox2_nif)
  alias Raxol.Terminal.Env

  @doc """
  Initializes termbox. Returns :ok or {:error, reason}.
  """
  @dialyzer {:nowarn_function, initialize: 0}
  def initialize do
    case call_termbox_init() do
      0 ->
        :ok

      -1 ->
        {:error, :init_failed}
        # NIF only returns 0 or -1
    end
  end

  @doc """
  Shuts down termbox.
  """
  @dialyzer {:nowarn_function, terminate: 0}
  def terminate do
    if @termbox2_available do
      :termbox2_nif.tb_shutdown()
    else
      IOTerminal.shutdown()
      0
    end
  end

  @doc """
  Attempts recovery from a termbox error by shutting down and reinitializing.
  Returns {:noreply, state} or {:stop, reason, state}.
  """
  @dialyzer {:nowarn_function, handle_recovery: 2}
  def handle_recovery(reason, state) do
    case terminate() do
      :ok ->
        case initialize() do
          :ok ->
            Log.info("Successfully recovered from termbox error")
            {:noreply, state}

          {:error, init_reason} ->
            Log.error("Failed to recover from termbox error: #{inspect(init_reason)}")

            {:stop, {:termbox_error, reason}, state}
        end

      _ ->
        {:stop, {:termbox_error, reason}, state}
    end
  end

  @doc """
  Cleans up terminal state during shutdown: kills stdin reader, closes tty port,
  restores terminal modes and original stty settings.
  """
  @dialyzer {:nowarn_function, cleanup_terminal: 1}
  def cleanup_terminal(state) do
    # Kill the stdin reader process
    case get_in(state, [
           Access.key(:io_terminal_state),
           Access.key(:input_reader)
         ]) do
      pid when is_pid(pid) ->
        Process.exit(pid, :shutdown)

      _ ->
        :ok
    end

    # Close tty port if open
    case get_in(state, [
           Access.key(:io_terminal_state),
           Access.key(:tty_port)
         ]) do
      port when is_port(port) ->
        try do
          Port.close(port)
        catch
          _, _ -> :ok
        end

      _ ->
        :ok
    end

    # Only attempt shutdown if not in test environment
    if not Env.test?() and has_terminal_device?() do
      # Disable terminal modes before restoring
      IO.write("\e[?1000l\e[?1006l\e[?1004l\e[?2004l")
      # Restore terminal: re-enable autowrap (DECAWM, paired with the
      # \e[?7l written at init in driver.ex's TTY-detected branch), show
      # cursor, leave alternate screen. Autowrap is restored before the
      # alt-screen exit so the primary screen the user returns to behaves
      # normally.
      IO.write("\e[?7h\e[?25h\e[?1049l")
      _ = :io.setopts(:standard_io, echo: true)

      # Restore original TTY settings (OS-level via /dev/tty)
      Raxol.Terminal.Driver.Stty.restore(state.original_stty)

      # Restore Logger output
      Logger.configure(level: :debug)
    end

    :ok
  end

  @dialyzer {:nowarn_function, call_termbox_init: 0}
  defp call_termbox_init do
    if @termbox2_available do
      :termbox2_nif.tb_init()
    else
      0
    end
  end
end
