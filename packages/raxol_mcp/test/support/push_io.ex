defmodule Raxol.MCP.TestSupport.PushIO do
  @moduledoc """
  An Erlang io-protocol device whose input the test feeds one line at a time.

  `get_line` is answered only when the test pushes a line or `:eof`, so a test
  decides exactly what the reader has seen and when input ends, with no
  sleeps. Everything written to the device (`put_chars`) is forwarded to the
  owner as `{:push_io, device, chars}` and acknowledged, so the owner can
  `assert_receive` each frame as it is written.

  It is a real io device, not a stand-in for one: `IO.gets/2` and `IO.write/2`
  talk to it through the same protocol they use for `:stdio`.
  """

  @doc "Start a device owned (and linked to) the calling process."
  @spec start_link() :: {:ok, pid()}
  def start_link do
    owner = self()
    {:ok, spawn_link(fn -> loop(owner, :queue.new(), nil) end)}
  end

  @doc "Make `line` (a newline is appended) or `:eof` available to the reader."
  @spec push(pid(), String.t() | :eof) :: :ok
  def push(device, line_or_eof) do
    send(device, {:push, if(line_or_eof == :eof, do: :eof, else: line_or_eof <> "\n")})
    :ok
  end

  defp loop(owner, queue, waiting) do
    receive do
      {:push, item} ->
        {queue, waiting} = answer(:queue.in(item, queue), waiting)
        loop(owner, queue, waiting)

      {:io_request, from, reply_as, request} ->
        {queue, waiting} = handle(request, {from, reply_as}, owner, queue, waiting)
        loop(owner, queue, waiting)
    end
  end

  defp handle({:get_line, _encoding, _prompt}, client, _owner, queue, nil),
    do: answer(queue, client)

  defp handle({:get_line, _prompt}, client, _owner, queue, nil), do: answer(queue, client)

  defp handle({:put_chars, _encoding, chars}, client, owner, queue, waiting) do
    send(owner, {:push_io, self(), IO.chardata_to_string(chars)})
    reply(client, :ok)
    {queue, waiting}
  end

  defp handle({:put_chars, chars}, client, owner, queue, waiting),
    do: handle({:put_chars, :unicode, chars}, client, owner, queue, waiting)

  defp handle(_request, client, _owner, queue, waiting) do
    reply(client, {:error, :request})
    {queue, waiting}
  end

  # `:eof` stays queued: every later read sees end of input too.
  defp answer(queue, nil), do: {queue, nil}

  defp answer(queue, client) do
    case :queue.peek(queue) do
      :empty ->
        {queue, client}

      {:value, :eof} ->
        reply(client, :eof)
        {queue, nil}

      {:value, line} ->
        reply(client, line)
        {:queue.drop(queue), nil}
    end
  end

  defp reply({from, reply_as}, reply), do: send(from, {:io_reply, reply_as, reply})
end
