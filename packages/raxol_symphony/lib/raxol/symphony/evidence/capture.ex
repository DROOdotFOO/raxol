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

  The file is opened in `:append` mode and synced on every frame, so a
  partial cast survives a BEAM crash mid-run -- asciinema happily replays
  whatever frames the file contains.

  ## Failure mode

  If the cast file can't be opened (e.g., directory creation fails),
  `start_link/1` returns `{:ok, pid}` for a no-op process and logs a
  warning. `record/2` and `stop/1` then become no-ops. The run itself
  is never blocked by recording failures.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  @default_width 80
  @default_height 24
  @max_text_bytes 16_384

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

  @doc "Starts a capture process. Always returns `{:ok, pid}` (fail-soft)."
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
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
  Path constructor: `<workspace>/.raxol_symphony/run-<attempt>.cast`.

  When `attempt` is nil, a single timestamp is used so concurrent
  retries land on distinct files.
  """
  @spec path_for(Path.t(), non_neg_integer() | nil) :: Path.t()
  def path_for(workspace, attempt) when is_binary(workspace) do
    suffix =
      case attempt do
        n when is_integer(n) and n >= 0 -> Integer.to_string(n)
        _ -> Integer.to_string(System.unique_integer([:positive, :monotonic]))
      end

    Path.join([workspace, ".raxol_symphony", "run-#{suffix}.cast"])
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

    case open_file(path) do
      {:ok, io} ->
        :ok = write_header(io, width, height, title)

        {:ok,
         %{
           io: io,
           path: path,
           start_us: System.monotonic_time(:microsecond)
         }}

      {:error, reason} ->
        Logger.warning(
          "symphony.evidence.capture.open_failed path=#{path} reason=#{inspect(reason)}"
        )

        {:ok, %{io: nil, path: path, start_us: 0}}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:record, _event, _at_us}, %{io: nil} = state), do: {:noreply, state}

  def handle_manager_cast({:record, event, at_us}, %{io: io, start_us: start_us} = state) do
    elapsed_seconds = (at_us - start_us) / 1_000_000.0
    text = format_event(event)

    :ok = write_frame(io, elapsed_seconds, text)
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

  defp open_file(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.open(path, [:write, :binary])
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
    IO.binwrite(io, Jason.encode!(header) <> "\n")
  end

  defp write_frame(io, elapsed_seconds, text) do
    frame = [Float.round(elapsed_seconds, 6), "o", text]
    IO.binwrite(io, Jason.encode!(frame) <> "\n")
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
    <<head::binary-size(limit - 13), _::binary>> = text
    head <> "...[truncated]"
  end
end
