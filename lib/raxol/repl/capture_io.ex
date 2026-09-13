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
  Start a capture server holding at most `limit` bytes, owned by the caller.

  `:mfa_timeout` bounds the MFA form of `put_chars` (see `put_mfa/4`): the
  expansion runs in a throwaway process, and the monitor that watches it only
  covers an expander that DIES. One that neither answers nor dies wedges this
  server for good, so the wait is bounded. There is no timeout of its own to
  invent: the evaluation this capture belongs to already has one, and
  `Raxol.REPL.Evaluator` passes it -- an expansion cannot usefully outlive the
  evaluation that asked for it. It defaults to the same
  `Raxol.Core.Defaults.timeout_ms/0` the evaluator's own default comes from.

  Unlinked on purpose: the caller sets it as its own group leader and closes it
  in an `after` block, and a link would turn a killed evaluation into a crash
  report for a process that is simply no longer needed.

  Unlinked is not unattached. The caller is MONITORED, and the server stops
  when it goes: an `after` block does not run when the evaluation is killed by
  `Process.exit(pid, :brutal_kill)` on timeout, or by the VM on a
  `max_heap_size` breach -- which are the two paths hostile input is meant to
  take. Without the monitor each of them orphaned one capture server holding up
  to `limit` bytes, forever, on a surface served anonymously over SSH. Stopping
  on `:DOWN` is a normal exit, so it still produces no crash report.
  """
  @spec start(pos_integer(), keyword()) :: {:ok, pid()}
  def start(limit, opts \\ []) when is_integer(limit) and limit > 0 do
    mfa_timeout =
      Keyword.get(opts, :mfa_timeout, Raxol.Core.Defaults.timeout_ms())

    GenServer.start(__MODULE__, {limit, self(), mfa_timeout})
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
  def init({limit, owner, mfa_timeout}) do
    Process.monitor(owner)

    {:ok,
     %{
       buffer: [],
       size: 0,
       limit: limit,
       truncated?: false,
       owner: owner,
       mfa_timeout: mfa_timeout
     }}
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

  # The evaluation this capture belongs to is gone, so nothing will ever read
  # the buffer or call `close/1`. Stop, whatever killed it.
  def handle_info(
        {:DOWN, _ref, :process, owner, _reason},
        %{owner: owner} = state
      ) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- IO protocol --------------------------------------------------------------

  defp io_request({:put_chars, chars}, state), do: put(chars, state)
  defp io_request({:put_chars, _encoding, chars}, state), do: put(chars, state)

  defp io_request({:put_chars, mod, fun, args}, state),
    do: put_mfa(mod, fun, args, state)

  defp io_request({:put_chars, _encoding, mod, fun, args}, state),
    do: put_mfa(mod, fun, args, state)

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

  # Headroom for the expansion process itself and the term it builds on the way
  # to a binary. The cap is a backstop against unbounded growth, not an exact
  # byte budget.
  @mfa_heap_slack_words 64 * 1024

  # The MFA form of `put_chars` asks the GROUP LEADER to build the text, and
  # `:io.format/2` uses exactly that form -- it sends `{put_chars, unicode,
  # io_lib, format, [Format, Args]}` rather than the finished bytes. Applying
  # it here ran the expansion in THIS process, which has no `max_heap_size`,
  # so `:io.format("~1000000000c", [?x])` allocated a gigabyte before the byte
  # cap below ever saw it -- straight through the limit this module exists to
  # impose, since the caller's own cap does not cover work done on its behalf
  # over here.
  #
  # So the expansion runs in a throwaway process capped at what the buffer
  # could still accept. A breach kills that process and the write is refused;
  # nothing else is affected, and the evaluation is told its write failed
  # rather than the node dying.
  #
  # The monitor covers an expander that DIES. One that neither answers nor
  # dies -- `Process.sleep(:infinity)` inside the formatter, a NIF that never
  # returns -- wedged this server in a receive with no `after`, and because
  # the wedge also swallows the owner's `:DOWN`, killing the evaluation did
  # not reclaim it: one capture server plus its expander leaked per wedge, on
  # an anonymous SSH surface. The wait is bounded by `:mfa_timeout` (the
  # evaluation's own timeout; see `start/2`) and expiry is the `:DOWN` case:
  # kill the expander, mark truncated, refuse the write.
  defp put_mfa(mod, fun, args, state) do
    ref = make_ref()

    {pid, monitor} =
      spawn_expander({mod, fun, args}, ref, expansion_words(state))

    await_expansion(pid, monitor, ref, state)
  end

  defp expansion_words(state) do
    remaining = max(state.limit - state.size, 0) + 1
    div(remaining + word_size(), word_size()) + @mfa_heap_slack_words
  end

  defp spawn_expander({mod, fun, args}, ref, words) do
    parent = self()

    :erlang.spawn_opt(
      fn ->
        result =
          try do
            {:ok, IO.iodata_to_binary(apply(mod, fun, args))}
          catch
            _kind, _reason -> :error
          end

        send(parent, {ref, result})
      end,
      [:monitor, max_heap_size: %{size: words, kill: true, error_logger: false}]
    )
  end

  defp await_expansion(pid, monitor, ref, state) do
    receive do
      {^ref, {:ok, data}} ->
        Process.demonitor(monitor, [:flush])
        put(data, state)

      {^ref, :error} ->
        Process.demonitor(monitor, [:flush])
        {{:error, :put_chars}, state}

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        # Over the cap (or a crash while expanding). Recorded as truncated so
        # the caller can say the output was cut rather than silently short.
        {:ok, %{state | truncated?: true}}
    after
      state.mfa_timeout ->
        # Neither answered nor died. Same outcome as the :DOWN above, plus the
        # kill that branch got for free.
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        flush_expansion(ref)
        {:ok, %{state | truncated?: true}}
    end
  end

  # An expansion that answered while the kill was in flight must not sit in
  # the mailbox: the next `put_mfa/4` waits on its own fresh ref, so a stale
  # reply is never matched, but it would grow this server's mailbox for the
  # life of the evaluation.
  defp flush_expansion(ref) do
    receive do
      {^ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp word_size, do: :erlang.system_info(:wordsize)

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
