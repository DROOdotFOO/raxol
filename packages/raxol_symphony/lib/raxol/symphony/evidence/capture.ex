defmodule Raxol.Symphony.Evidence.Capture do
  @moduledoc """
  Per-run asciicast writer.

  Streams Symphony run events to an asciicast v2 (`*.cast`) file inside
  `<workspace>/.raxol_symphony/`. The orchestrator starts one Capture
  process per dispatched run when recording is enabled, calls
  `record/2` on each `:run_event`, and `stop/1` when the worker exits.

  ## File layout

      header     -- {"version":2, "width":80, "height":24, "timestamp":<unix>, ...}
      frame...   -- [<elapsed_seconds>, "o", "<text>\\r\\n"]

  Each dispatch gets its own file (`path_for/2` mints a fresh name), so a
  run that takes several dispatches to finish leaves several fragments
  rather than one cast. asciinema happily replays whatever frames a
  fragment contains, including a partial one.

  ## Failure mode

  If the cast file can't be opened or its header can't be written (e.g.,
  directory creation fails, the disk is full), `start/1` returns
  `{:ok, pid}` for a no-op process and logs a warning. `record/2` and
  `stop/1` then become no-ops. A frame the JSON encoder rejects is
  dropped; a write the device rejects retires the recording. The run
  itself is never blocked by recording failures, and the process is
  unlinked so a fault here cannot reach the orchestrator.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  @default_width 80
  @default_height 24
  @max_text_bytes 16_384
  @truncation_marker "...[truncated]"

  @type opts :: [
          path: Path.t(),
          width: pos_integer(),
          height: pos_integer(),
          title: binary() | nil,
          identifier: binary() | nil
        ]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts a capture process. Always returns `{:ok, pid}` (fail-soft).

  The process is deliberately NOT linked to its caller: recording is
  best-effort evidence, and the orchestrator does not trap exits, so a
  link makes every capture fault fatal to the run loop. The caller is
  monitored instead, which also cleans up better than a link did -- a
  caller exiting `:normal` leaves a linked child running.
  """
  @spec start(opts()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, Keyword.put(opts, :owner, self()))
  end

  # BaseManager hands every manager a linked start and a `child_spec/1`
  # pointing at it. Both are wrong here for the reason above, so refuse
  # rather than let a supervisor quietly wire recording into the run's
  # fate.
  @doc false
  def start_link(_opts) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} must be started unlinked via start/1: " <>
            "a linked capture makes a recording fault fatal to the run it observes"
  end

  @doc "Records a Symphony run event. Returns `:ok`. Safe with `nil` pid."
  @spec record(pid() | nil, map()) :: :ok
  def record(nil, _event), do: :ok

  def record(pid, %{} = event) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.cast(pid, {:record, event, System.monotonic_time(:microsecond)})
    end

    :ok
  end

  @doc "Stops the capture process and closes the file. Safe with `nil` pid."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @doc """
  Path constructor: `<workspace>/.raxol_symphony/run-<attempt>-<stamp>.cast`.

  The stamp makes the name unique per dispatch, not per attempt. The
  orchestrator re-enters the same workspace with the same attempt on
  every continuation retry and on every resume, and a name stable across
  those would have the next capture truncate the stretch the previous
  one recorded. `Evidence.Recording` advertises every `*.cast` in the
  directory, so the extra files stay visible.
  """
  @spec path_for(Path.t(), non_neg_integer() | nil) :: Path.t()
  def path_for(workspace, attempt) when is_binary(workspace) do
    prefix =
      case attempt do
        n when is_integer(n) and n >= 0 -> "run-#{n}-"
        _ -> "run-"
      end

    Path.join([workspace, ".raxol_symphony", prefix <> dispatch_stamp() <> ".cast"])
  end

  # Wall clock disambiguates across BEAM restarts (the unique integer
  # restarts with the VM and would collide with a prior boot's files);
  # the unique integer disambiguates within one millisecond.
  defp dispatch_stamp do
    "#{System.os_time(:millisecond)}-#{System.unique_integer([:positive, :monotonic])}"
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    path = Keyword.fetch!(opts, :path)
    width = Keyword.get(opts, :width, @default_width)
    height = Keyword.get(opts, :height, @default_height)
    title = Keyword.get(opts, :title)

    owner_ref = monitor_owner(Keyword.get(opts, :owner))

    case start_cast(path, width, height, title) do
      {:ok, io} ->
        {:ok,
         %{
           io: io,
           path: path,
           owner_ref: owner_ref,
           start_us: System.monotonic_time(:microsecond)
         }}

      {:error, reason} ->
        Logger.warning(
          "symphony.evidence.capture.open_failed path=#{path} reason=#{inspect(reason)}"
        )

        {:ok, %{io: nil, path: path, owner_ref: owner_ref, start_us: 0}}
    end
  end

  defp monitor_owner(owner) when is_pid(owner), do: Process.monitor(owner)
  defp monitor_owner(_owner), do: nil

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:record, _event, _at_us}, %{io: nil} = state), do: {:noreply, state}

  def handle_manager_cast({:record, event, at_us}, %{io: io, start_us: start_us} = state) do
    elapsed_seconds = (at_us - start_us) / 1_000_000.0

    case write_frame(io, elapsed_seconds, format_event(event)) do
      :ok ->
        {:noreply, state}

      {:error, {:encode, reason}} ->
        Logger.warning(
          "symphony.evidence.capture.frame_dropped path=#{state.path} reason=#{inspect(reason)}"
        )

        {:noreply, state}

      {:error, reason} ->
        # The device is gone (full disk, closed fd): retire the recording
        # rather than raising on every subsequent frame.
        Logger.warning(
          "symphony.evidence.capture.write_failed path=#{state.path} reason=#{inspect(reason)}"
        )

        {:noreply, %{state | io: nil}}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_manager_info(message, state) do
    Logger.debug("symphony.evidence.capture.unhandled_info message=#{inspect(message)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{io: nil}), do: :ok

  def terminate(_reason, %{io: io}) do
    try do
      File.close(io)
    catch
      _, _ -> :ok
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # A cast without its header is not a cast, so a failed header is a
  # failed open: close the handle and let the caller go no-op.
  defp start_cast(path, width, height, title) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- File.open(path, [:write, :binary]) do
      case write_header(io, width, height, title) do
        :ok ->
          {:ok, io}

        {:error, reason} ->
          File.close(io)
          {:error, reason}
      end
    end
  end

  defp write_header(io, width, height, title) do
    header = %{
      "version" => 2,
      "width" => width,
      "height" => height,
      "timestamp" => System.os_time(:second),
      "env" => %{"TERM" => "xterm-256color"}
    }

    header = if is_binary(title), do: Map.put(header, "title", title), else: header

    case Jason.encode(header) do
      {:ok, encoded} -> binwrite(io, encoded <> "\n")
      {:error, reason} -> {:error, {:encode, reason}}
    end
  end

  defp write_frame(io, elapsed_seconds, text) do
    case Jason.encode([Float.round(elapsed_seconds, 6), "o", text]) do
      {:ok, frame} -> binwrite(io, frame <> "\n")
      {:error, reason} -> {:error, {:encode, reason}}
    end
  end

  # IO.binwrite/2 is specced `:ok` but exits when the device is gone (a
  # closed fd, a full disk). A best-effort recorder should not die of that.
  defp binwrite(io, data) do
    IO.binwrite(io, data)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  @spec format_event(map()) :: binary()
  def format_event(%{} = event) do
    label = label_for(Map.get(event, :event))
    body = body_for(event)

    label
    |> Kernel.<>(body)
    |> Kernel.<>("\r\n")
    |> truncate(@max_text_bytes)
  end

  defp label_for(:session_started), do: "[session] "
  defp label_for(:text_delta), do: ""
  defp label_for(:tool_use), do: "[tool] "
  defp label_for(:tool_result), do: "[result] "
  defp label_for(:turn_completed), do: "[turn complete] "
  defp label_for(:turn_failed), do: "[turn failed] "
  defp label_for(:blocked), do: "[blocked] "
  defp label_for(other) when is_atom(other), do: "[#{other}] "
  defp label_for(other) when is_binary(other), do: "[#{other}] "
  defp label_for(_), do: "[event] "

  defp body_for(%{message: message}) when is_binary(message), do: message

  defp body_for(%{event: :turn_completed, usage: %{} = usage}) do
    total = Map.get(usage, :total_tokens, Map.get(usage, "total_tokens", 0))
    "tokens=#{total}"
  end

  defp body_for(%{payload: payload}) when is_map(payload), do: inspect(payload, limit: 5)
  defp body_for(_), do: ""

  defp truncate(text, limit) when byte_size(text) <= limit, do: text

  defp truncate(text, limit) do
    text
    |> binary_part(0, limit - byte_size(@truncation_marker))
    |> valid_prefix()
    |> Kernel.<>(@truncation_marker)
  end

  # The budget is bytes, so the cut can land inside a multi-byte
  # codepoint; Jason rejects the invalid binary that would leave behind.
  # A codepoint is at most four bytes, so three trims settle any cut. A
  # head still invalid after that was invalid before the cut (a tool
  # result carrying raw binary), and scanning the whole 16 KB head byte
  # by byte would not rescue it -- leave it for the encoder to drop.
  defp valid_prefix(head, trims_left \\ 3)
  defp valid_prefix(head, 0), do: head

  defp valid_prefix(head, trims_left) do
    case String.valid?(head) do
      true -> head
      false -> head |> binary_part(0, byte_size(head) - 1) |> valid_prefix(trims_left - 1)
    end
  end
end
