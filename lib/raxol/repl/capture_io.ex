defmodule Raxol.REPL.CaptureIO do
  @moduledoc """
  A bounded IO server used as the group leader for a REPL evaluation.

  `StringIO` would be the obvious choice, and was, but it accumulates without
  limit in a process of its own. That placement is what makes it unsuitable
  here: `Raxol.REPL.Evaluator` runs user code under a `max_heap_size` that
  kills on breach, and output written to a separate process does not count
  against it. `Enum.each(1..1_000_000, fn _ -> IO.puts(big) end)` therefore
  allocates almost nothing in the evaluation process while growing the capture
  without bound, inside a limit that never trips.

  Measuring the capture process from outside does not work either: output
  arrives as refc binaries, which live in the shared binary heap and are not
  counted by `:erlang.process_info/2`'s `:memory`. So the count has to be kept
  where the writes happen.

  This server counts bytes as it accepts them and stops accumulating at
  `:limit`, recording that it truncated. Writes keep succeeding afterwards --
  an evaluation is not made to crash because it printed too much; it simply
  stops being recorded, and the caller can say so.

  Reads are refused. A REPL evaluation has no stdin, and returning `:eof`
  rather than an error would let `IO.gets` look like it succeeded at reading
  end-of-input.
  """

  use GenServer

  @doc """
  Start a capture server holding at most `limit` bytes.

  Started unlinked on purpose: the caller sets it as its own group leader and
  closes it in an `after` block, and a link would turn a killed evaluation
  into a crash report for a process that is simply no longer needed.
  """
  @spec start(pos_integer()) :: {:ok, pid()}
  def start(limit) when is_integer(limit) and limit > 0 do
    GenServer.start(__MODULE__, limit)
  end

  @doc """
  Return the captured output and whether it was truncated at the limit.
  """
  @spec contents(pid()) :: {binary(), boolean()}
  def contents(pid), do: GenServer.call(pid, :contents)

  @doc "Stop the capture server."
  @spec close(pid()) :: :ok
  def close(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  @impl GenServer
  def init(limit) do
    {:ok, %{buffer: [], size: 0, limit: limit, truncated?: false}}
  end

  @impl GenServer
  def handle_call(:contents, _from, state) do
    {:reply,
     {IO.iodata_to_binary(Enum.reverse(state.buffer)), state.truncated?}, state}
  end

  @impl GenServer
  def handle_info({:io_request, from, reply_as, request}, state) do
    {reply, state} = io_request(request, state)
    send(from, {:io_reply, reply_as, reply})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- IO protocol --------------------------------------------------------------

  defp io_request({:put_chars, chars}, state), do: put(chars, state)
  defp io_request({:put_chars, _encoding, chars}, state), do: put(chars, state)

  defp io_request({:put_chars, mod, fun, args}, state) do
    put(apply(mod, fun, args), state)
  rescue
    _ -> {{:error, :put_chars}, state}
  end

  defp io_request({:put_chars, _encoding, mod, fun, args}, state) do
    put(apply(mod, fun, args), state)
  rescue
    _ -> {{:error, :put_chars}, state}
  end

  # A REPL evaluation has no stdin. `:eof` would read as "input ended", which
  # is a different and more misleading claim than "there is no input here".
  defp io_request({:get_chars, _, _, _}, state), do: {{:error, :enotsup}, state}
  defp io_request({:get_chars, _, _}, state), do: {{:error, :enotsup}, state}
  defp io_request({:get_line, _, _}, state), do: {{:error, :enotsup}, state}
  defp io_request({:get_line, _}, state), do: {{:error, :enotsup}, state}

  defp io_request({:get_until, _, _, _, _, _}, state),
    do: {{:error, :enotsup}, state}

  defp io_request({:get_password, _}, state), do: {{:error, :enotsup}, state}

  defp io_request(:getopts, state),
    do: {[binary: true, encoding: :unicode], state}

  defp io_request({:setopts, _opts}, state), do: {:ok, state}

  defp io_request({:requests, requests}, state),
    do: io_requests(requests, state)

  defp io_request(_other, state), do: {{:error, :request}, state}

  defp io_requests([], state), do: {:ok, state}

  defp io_requests([request | rest], state) do
    case io_request(request, state) do
      {:ok, state} -> io_requests(rest, state)
      {error, state} -> {error, state}
    end
  end

  # Accepting past the limit is what the whole module exists to prevent, so the
  # write is dropped rather than partially kept: a half-written line spliced
  # onto the next one reads as output the program never produced.
  defp put(chars, state) do
    data = IO.iodata_to_binary(chars)
    size = byte_size(data)

    cond do
      state.truncated? ->
        {:ok, state}

      state.size + size > state.limit ->
        {:ok, %{state | truncated?: true}}

      true ->
        {:ok, %{state | buffer: [data | state.buffer], size: state.size + size}}
    end
  rescue
    _ -> {{:error, :put_chars}, state}
  end
end
