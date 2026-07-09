defmodule Raxol.Terminal.Emulator.SafeEmulator do
  @moduledoc """
  Enhanced terminal emulator with comprehensive error handling.
  Refactored to use functional error handling patterns instead of try/catch.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Core.ErrorRecovery
  alias Raxol.Core.Runtime.Log
  alias Raxol.Terminal.Emulator.Telemetry

  @default_width Raxol.Core.Defaults.terminal_width()
  @default_height Raxol.Core.Defaults.terminal_height()

  # 1MB max input
  @max_input_size 1_048_576
  @processing_timeout Raxol.Core.Defaults.timeout_ms()
  @recovery_delay Raxol.Core.Defaults.monitor_interval_ms()
  @health_check_interval_ms Raxol.Core.Defaults.health_check_interval_ms()

  defstruct [
    :emulator_state,
    :error_stats,
    :recovery_state,
    :input_buffer,
    :last_checkpoint,
    :config
  ]

  @type error_stats :: %{
          total_errors: non_neg_integer(),
          errors_by_type: map(),
          last_error: {DateTime.t(), term()} | nil,
          recovery_attempts: non_neg_integer()
        }

  @type t :: %__MODULE__{
          emulator_state: term(),
          error_stats: error_stats(),
          recovery_state: atom(),
          input_buffer: binary(),
          last_checkpoint: term(),
          config: map()
        }

  # Client API

  # BaseManager provides start_link/1 and start_link/2 automatically

  @doc """
  Safely processes input with validation and error recovery.
  """
  def process_input(pid \\ __MODULE__, input) do
    with {:ok, :valid_size} <- validate_input_size(input),
         {:ok, result} <- safe_call_with_timeout(pid, {:process_input, input}) do
      result
    else
      {:error, :input_too_large} ->
        {:error, :input_too_large}

      {:error, :timeout} ->
        Log.error("Input processing timeout")
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Safely handles ANSI sequences with fallback.
  """
  def handle_sequence(pid \\ __MODULE__, sequence) do
    GenServer.call(pid, {:handle_sequence, sequence})
  end

  @doc """
  Safely resizes the terminal with validation.
  """
  def resize(pid \\ __MODULE__, width, height) do
    with {:ok, :valid} <- validate_resize_dimensions(width, height),
         {:ok, result} <- safe_genserver_call(pid, {:resize, width, height}) do
      result
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Triggers recovery mechanism manually.
  """
  def recover(pid \\ __MODULE__) do
    GenServer.call(pid, :recover)
  end

  @doc """
  Gets the current terminal state with error recovery.
  """
  def get_state(pid \\ __MODULE__) do
    GenServer.call(pid, :get_state)
  end

  @doc """
  Gets error statistics and health status.
  """
  def get_health(pid \\ __MODULE__) do
    GenServer.call(pid, :get_health)
  end

  @doc """
  Performs checkpoint/restore operations.
  """
  def checkpoint(pid \\ __MODULE__) do
    GenServer.call(pid, :checkpoint)
  end

  def restore(pid \\ __MODULE__, checkpoint) do
    GenServer.call(pid, {:restore, checkpoint})
  end

  # Server callbacks

  @impl true
  def init_manager(opts) do
    {:ok, initial_state} = create_initial_emulator_state(opts)
    {:ok, config} = build_config(opts)

    state = %__MODULE__{
      emulator_state: initial_state,
      error_stats: init_error_stats(),
      recovery_state: :healthy,
      input_buffer: <<>>,
      last_checkpoint: initial_state,
      config: config
    }

    # Schedule periodic health checks
    schedule_health_check()

    {:ok, state}
  end

  @impl true
  def handle_manager_call({:process_input, input}, _from, state) do
    Telemetry.span(
      [:raxol, :emulator, :input],
      %{input_size: byte_size(input)},
      fn ->
        with {:ok, chunks} <- perform_input_chunking(input),
             {:ok, new_emulator_state} <-
               process_chunks_safely(chunks, state.emulator_state),
             {:ok, updated_state} <-
               update_state_safely(state, new_emulator_state) do
          {:reply, {:ok, :ok}, updated_state}
        else
          {:error, reason} ->
            Telemetry.record_error(:processing_error, reason)
            new_state = handle_processing_error(reason, input, state)
            {:reply, {:error, reason}, new_state}
        end
      end
    )
  end

  @impl true
  def handle_manager_call({:handle_sequence, sequence}, _from, state) do
    Telemetry.span([:raxol, :emulator, :sequence], %{sequence: sequence}, fn ->
      with {:ok, valid_sequence} <- perform_sequence_validation(sequence),
           {:ok, new_emulator_state} <-
             perform_sequence_application(valid_sequence, state.emulator_state),
           {:ok, updated_state} <-
             update_state_safely(state, new_emulator_state) do
        {:reply, :ok, updated_state}
      else
        {:error, reason} ->
          Telemetry.record_error(:sequence_error, reason)
          new_state = record_error(state, :sequence_error, reason)
          {:reply, {:error, reason}, new_state}
      end
    end)
  end

  @impl true
  def handle_manager_call({:resize, width, height}, _from, state) do
    Telemetry.span(
      [:raxol, :emulator, :resize],
      %{width: width, height: height},
      fn ->
        with {:ok, new_emulator_state} <-
               perform_resize(state.emulator_state, width, height),
             {:ok, updated_state} <-
               update_state_safely(state, new_emulator_state) do
          {:reply, {:ok, :ok}, updated_state}
        else
          {:error, reason} ->
            Telemetry.record_error(:resize_error, reason)
            new_state = record_error(state, :resize_error, reason)
            {:reply, {:error, reason}, new_state}
        end
      end
    )
  end

  @impl true
  def handle_manager_call(:get_state, _from, state) do
    # Return a safe copy of the state
    safe_state = safe_state_copy(state.emulator_state)
    {:reply, {:ok, safe_state}, state}
  end

  @impl true
  def handle_manager_call(:get_health, _from, state) do
    health = %{
      status: determine_health_status(state),
      error_stats: state.error_stats,
      recovery_state: state.recovery_state,
      buffer_size: byte_size(state.input_buffer)
    }

    {:reply, {:ok, health}, state}
  end

  @impl true
  def handle_manager_call(:checkpoint, _from, state) do
    checkpoint = create_checkpoint(state.emulator_state)
    new_state = %{state | last_checkpoint: checkpoint}

    Telemetry.record_checkpoint_created(%{
      checkpoint_size: map_size(checkpoint)
    })

    {:reply, {:ok, checkpoint}, new_state}
  end

  @impl true
  def handle_manager_call({:restore, checkpoint}, _from, state) do
    case perform_restore(checkpoint) do
      {:ok, restored_state} ->
        new_state = %{
          state
          | emulator_state: restored_state,
            recovery_state: :restored
        }

        Telemetry.record_checkpoint_restored(%{
          checkpoint_size: map_size(checkpoint)
        })

        {:reply, {:ok, :restored}, new_state}

      {:error, reason} ->
        Telemetry.record_error(:restore_error, reason)
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_manager_call(:recover, _from, state) do
    case state.recovery_state do
      %{attempts: attempts} when attempts >= 3 ->
        {:reply, {:error, :max_recovery_attempts_exceeded}, state}

      _ ->
        case perform_recovery(state) do
          {:ok, recovered_state} ->
            updated_recovery = update_recovery_attempts(state.recovery_state)
            new_state = %{recovered_state | recovery_state: updated_recovery}
            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_manager_info(:health_check, state) do
    new_state = perform_health_check(state)
    schedule_health_check()
    {:noreply, new_state}
  end

  def handle_manager_info({:retry_processing, input}, state) do
    case process_with_retry(input, state) do
      {:ok, _result} ->
        Log.info("Retry successful for buffered input")
        new_state = %{state | input_buffer: <<>>, recovery_state: :healthy}
        {:noreply, new_state}

      {:error, _type, message, _context} ->
        Log.error("Retry failed, discarding input: #{inspect(message)}")
        new_state = %{state | input_buffer: <<>>, recovery_state: :degraded}
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_manager_info(msg, state) do
    Log.debug("Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private helper functions

  defp validate_input_size(input) when is_binary(input) do
    validate_size_limit(byte_size(input) > @max_input_size)
  end

  defp validate_input_size(_), do: {:error, :invalid_input}

  # Pattern matching helpers to eliminate if statements
  defp validate_size_limit(true), do: {:error, :input_too_large}
  defp validate_size_limit(false), do: {:ok, :valid_size}

  defp validate_sequence_type(sequence)
       when is_binary(sequence) or is_list(sequence),
       do: {:ok, sequence}

  defp validate_sequence_type(_sequence), do: {:error, :invalid_sequence}

  defp handle_input_buffering(true, new_state, state, input) do
    buffered_state = %{new_state | input_buffer: state.input_buffer <> input}

    # Schedule retry
    Process.send_after(self(), {:retry_processing, input}, @recovery_delay)

    buffered_state
  end

  defp handle_input_buffering(false, new_state, _state, _input), do: new_state

  defp handle_recovery_check(:recovering, state)
       when state.error_stats.total_errors > 0 do
    # Try to recover
    case perform_recovery(state) do
      {:ok, recovered_state} ->
        Telemetry.record_recovery_success()
        recovered_state

      {:error, reason} ->
        Telemetry.record_recovery_failure(reason)
        state
    end
  end

  defp handle_recovery_check(_recovery_state, state), do: state

  defp recover_from_checkpoint(nil, _state), do: {:error, :no_checkpoint}

  defp recover_from_checkpoint(checkpoint, state) do
    {:ok,
     %{
       state
       | emulator_state: checkpoint,
         recovery_state: :recovered,
         error_stats: Map.update!(state.error_stats, :recovery_attempts, &(&1 + 1))
     }}
  end

  defp safe_call_with_timeout(pid, message) do
    case Process.alive?(pid) do
      true ->
        task =
          Task.async(fn ->
            GenServer.call(pid, message, @processing_timeout)
          end)

        case Task.yield(task, @processing_timeout) || Task.shutdown(task) do
          {:ok, result} -> {:ok, result}
          nil -> {:error, :timeout}
          {:exit, reason} -> {:error, {:exit, reason}}
        end

      false ->
        {:error, :process_dead}
    end
  end

  defp validate_resize_dimensions(width, height)
       when width <= 0 or height <= 0,
       do: {:error, :invalid_dimensions}

  defp validate_resize_dimensions(width, height)
       when width > 10_000 or height > 10_000,
       do: {:error, :dimensions_too_large}

  defp validate_resize_dimensions(_width, _height), do: {:ok, :valid}

  defp safe_genserver_call(pid, message) do
    case Process.alive?(pid) do
      true ->
        Raxol.Core.ErrorHandling.safe_call(fn ->
          GenServer.call(pid, message)
        end)
        |> case do
          {:ok, result} -> {:ok, result}
          {:error, {:exit, reason}} -> {:error, {:genserver_exit, reason}}
          {:error, reason} -> {:error, {:call_exception, reason}}
        end

      false ->
        {:error, :process_dead}
    end
  end

  defp perform_input_chunking(input) do
    Raxol.Core.ErrorHandling.safe_call(fn ->
      with {:ok, validated_input} <- validate_input(input) do
        chunks = chunk_input(validated_input)
        {:ok, chunks}
      end
    end)
    |> case do
      {:ok, result} ->
        result

      {:error, reason} ->
        Log.error("Exception in input chunking: #{inspect(reason)}")
        {:error, {:chunking_exception, reason}}
    end
  end

  defp validate_input(input) when is_binary(input), do: {:ok, input}
  defp validate_input(_), do: {:error, :invalid_input_type}

  defp chunk_input(input) do
    # Simple chunking implementation - can be customized
    chunk_size = 1024
    for <<chunk::binary-size(^chunk_size) <- input>>, do: chunk
  end

  defp process_chunks_safely(chunks, initial_state) do
    result =
      Enum.reduce_while(chunks, {:ok, initial_state}, fn chunk, {:ok, acc} ->
        case process_chunk(chunk, acc) do
          {:ok, new_state} -> {:cont, {:ok, new_state}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    result
  end

  defp process_chunk(chunk, state) do
    Raxol.Core.ErrorHandling.safe_call(fn ->
      # Placeholder for actual chunk processing
      # This would call into the actual emulator logic
      {:ok, Map.put(state, :last_chunk, chunk)}
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:chunk_processing_error, reason}}
    end
  end

  defp update_state_safely(state, new_emulator_state) do
    safe_state_update(state, :emulator_state, new_emulator_state)
  end

  defp safe_state_update(state, key, value) do
    Raxol.Core.ErrorHandling.safe_call(fn ->
      updated = Map.put(state, key, value)
      {:ok, updated}
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:state_update_error, reason}}
    end
  end

  defp perform_sequence_validation(sequence) do
    # Placeholder for sequence validation logic
    validate_sequence_type(sequence)
  end

  defp perform_sequence_application(sequence, emulator_state) do
    Raxol.Core.ErrorHandling.safe_call(fn ->
      # Placeholder for sequence application logic
      {:ok, Map.put(emulator_state, :last_sequence, sequence)}
    end)
    |> case do
      {:ok, result} ->
        result

      {:error, reason} ->
        Log.error("Exception applying sequence: #{inspect(reason)}")
        {:error, {:application_exception, reason}}
    end
  end

  defp perform_resize(emulator_state, width, height) do
    Raxol.Core.ErrorHandling.safe_call(fn ->
      # Placeholder for resize logic
      {:ok, Map.merge(emulator_state, %{width: width, height: height})}
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:resize_exception, reason}}
    end
  end

  defp create_initial_emulator_state(opts) do
    width = Keyword.get(opts, :width, @default_width)
    height = Keyword.get(opts, :height, @default_height)

    state = %{
      width: width,
      height: height,
      buffer: [],
      cursor: {0, 0},
      attributes: %{}
    }

    {:ok, state}
  end

  defp build_config(opts) do
    config = %{
      max_retries: Keyword.get(opts, :max_retries, 3),
      buffer_inputs: Keyword.get(opts, :buffer_inputs, true),
      telemetry_enabled: Keyword.get(opts, :telemetry_enabled, true)
    }

    {:ok, config}
  end

  defp init_error_stats do
    %{
      total_errors: 0,
      errors_by_type: %{},
      last_error: nil,
      recovery_attempts: 0
    }
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval_ms)
  end

  defp handle_processing_error(reason, input, state) do
    new_stats = update_error_stats(state.error_stats, :processing_error, reason)

    new_state = %{state | error_stats: new_stats, recovery_state: :recovering}

    # Buffer input for retry if configured
    handle_input_buffering(
      state.config[:buffer_inputs],
      new_state,
      state,
      input
    )
  end

  defp record_error(state, error_type, reason) do
    new_stats = update_error_stats(state.error_stats, error_type, reason)
    %{state | error_stats: new_stats}
  end

  defp update_error_stats(stats, error_type, reason) do
    %{
      stats
      | total_errors: stats.total_errors + 1,
        errors_by_type: Map.update(stats.errors_by_type, error_type, 1, &(&1 + 1)),
        last_error: {DateTime.utc_now(), reason}
    }
  end

  defp safe_state_copy(emulator_state) do
    Raxol.Core.ErrorHandling.safe_call_with_default(
      fn ->
        # Create a safe copy of the state
        Map.new(emulator_state)
      end,
      %{}
    )
  end

  defp determine_health_status(%{error_stats: %{total_errors: 0}}), do: :healthy

  defp determine_health_status(%{error_stats: %{total_errors: errors}})
       when errors < 10,
       do: :degraded

  defp determine_health_status(_state), do: :critical

  defp create_checkpoint(emulator_state) do
    # Create a checkpoint of the current state
    Map.new(emulator_state)
  end

  defp perform_restore(checkpoint) do
    Raxol.Core.ErrorHandling.safe_call(fn ->
      # Restore from checkpoint
      {:ok, Map.new(checkpoint)}
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:restore_error, reason}}
    end
  end

  defp perform_health_check(state) do
    health_status = determine_health_status(state)

    Telemetry.record_health_check(health_status, %{
      total_errors: state.error_stats.total_errors
    })

    # Perform health check and potentially recover
    handle_recovery_check(state.recovery_state, state)
  end

  defp perform_recovery(state) do
    Telemetry.record_recovery_attempt()

    # Attempt to recover from errors
    recover_from_checkpoint(state.last_checkpoint, state)
  end

  defp update_recovery_attempts(recovery_state) when is_map(recovery_state) do
    current_attempts = Map.get(recovery_state, :attempts, 0)
    %{recovery_state | attempts: current_attempts + 1}
  end

  defp update_recovery_attempts(_recovery_state) do
    %{attempts: 1}
  end

  defp process_with_retry(input, state) do
    ErrorRecovery.with_retry(
      fn -> process_input_internal(input, state) end,
      max_attempts: 3,
      backoff: 100
    )
  end

  defp process_input_internal(input, state) do
    with {:ok, chunks} <- perform_input_chunking(input) do
      process_chunks_safely(chunks, state.emulator_state)
    end
  end
end
