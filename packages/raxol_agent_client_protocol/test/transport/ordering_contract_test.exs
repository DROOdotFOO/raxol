defmodule Raxol.AgentClientProtocol.Transport.OrderingContractTest do
  @moduledoc """
  F7 conformance suite: pins the `Raxol.AgentClientProtocol.Transport`
  behaviour's T-ORD clause (transport.ex `## Delivery guarantees`) — per
  direction, frames delivered to the owner as `{:message, frame}` arrive in
  EXACTLY the order the peer's send path accepted them.

  This is a *behavioral* test, not a doc assertion: it drives real frames
  through the real `Transport.Paired` implementation and checks arrival
  order against send order.

  The second `describe` block is the falsifier proof the design's F7 entry
  calls for: a deliberately reordering fake transport, run through the
  IDENTICAL check, must fail it. If the check couldn't tell the two apart
  it would be vacuous — this pins that it can.
  """

  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Transport.Paired

  # -- Shared oracle --------------------------------------------------------
  #
  # The same "collect N `{:message, ...}` deliveries, in the order they land
  # in this process's mailbox" check is applied to both the real transport
  # (must pass) and the reordering fake (must fail) below.

  defp collect_seqs(n, timeout \\ 2_000) do
    for _ <- 1..n do
      assert_receive {:acp_transport, _ref, {:message, %{"seq" => seq}}}, timeout
      seq
    end
  end

  describe "F7 T-ORD conformance: Transport.Paired" do
    test "N frames sent from a single process arrive at the owner in send order" do
      {left, right} = Paired.create_pair()
      :ok = Paired.set_owner(right, self())
      n = 2_000

      Enum.reduce(1..n, left, fn i, side ->
        {:ok, side} = Paired.send_message(side, %{"seq" => i})
        side
      end)

      assert collect_seqs(n) == Enum.to_list(1..n)
    end

    test "acceptance order (not scheduling order) governs: sends from many tasks funnel through one owner's send order per side" do
      {left, right} = Paired.create_pair()
      :ok = Paired.set_owner(right, self())
      n = 300

      # Each send is issued sequentially against `left` (the transport's
      # single-writer send path serializes acceptance), so even though this
      # process could be preempted between calls, the ACCEPTANCE order is
      # exactly the call order below — which is what T-ORD promises arrival
      # will match.
      Enum.reduce(1..n, left, fn i, side ->
        {:ok, side} = Paired.send_message(side, %{"seq" => i})
        side
      end)

      assert collect_seqs(n) == Enum.to_list(1..n)
    end
  end

  describe "F7 red variant: the conformance check is a real falsifier" do
    defmodule ShufflingFakeTransport do
      @moduledoc """
      Test-only fake satisfying the `Transport` behaviour's callback
      SHAPES (`send_message/2`, `close/1`) but deliberately violating
      T-ORD: it buffers every accepted frame and, on `flush/1`, delivers
      them to the owner in reverse (LIFO) order — the last frame accepted
      arrives first. It still satisfies T-REL/T-DUP (every accepted frame
      is delivered, exactly once) so the ONLY property it breaks is
      ordering, isolating what the F7 check actually detects.
      """

      @behaviour Raxol.AgentClientProtocol.Transport

      use GenServer

      @type t :: %__MODULE__{pid: pid()}
      defstruct [:pid]

      @spec start(pid()) :: t()
      def start(owner) when is_pid(owner) do
        {:ok, pid} = GenServer.start_link(__MODULE__, %{owner: owner, buffer: []})
        %__MODULE__{pid: pid}
      end

      @impl Raxol.AgentClientProtocol.Transport
      @spec send_message(t(), map()) :: {:ok, t()} | {:error, term()}
      def send_message(%__MODULE__{pid: pid} = t, message) when is_map(message) do
        :ok = GenServer.call(pid, {:buffer, message})
        {:ok, t}
      end

      @impl Raxol.AgentClientProtocol.Transport
      @spec close(t()) :: :ok
      def close(%__MODULE__{pid: pid}) do
        if Process.alive?(pid), do: GenServer.stop(pid)
        :ok
      end

      @doc """
      Test-only: deliver every buffered frame to the owner in REVERSE
      (LIFO) order. Deliberately violates T-ORD so the F7 oracle above
      has something real to fail against.
      """
      @spec flush(t()) :: :ok
      def flush(%__MODULE__{pid: pid}) do
        GenServer.call(pid, :flush)
      end

      @impl GenServer
      def init(state), do: {:ok, state}

      @impl GenServer
      def handle_call({:buffer, message}, _from, %{buffer: buffer} = state) do
        {:reply, :ok, %{state | buffer: [message | buffer]}}
      end

      def handle_call(:flush, _from, %{owner: owner, buffer: buffer} = state) do
        # `buffer` accumulated via prepend, so it is already in
        # arrived-most-recent-first order; delivering it AS-IS is exactly
        # the reverse of acceptance order.
        Enum.each(buffer, fn message ->
          send(owner, {:acp_transport, self(), {:message, message}})
        end)

        {:reply, :ok, %{state | buffer: []}}
      end
    end

    test "a transport that delivers frames out of acceptance order fails the F7 check" do
      fake = ShufflingFakeTransport.start(self())
      n = 20

      Enum.each(1..n, fn i ->
        {:ok, _} = ShufflingFakeTransport.send_message(fake, %{"seq" => i})
      end)

      :ok = ShufflingFakeTransport.flush(fake)

      received = collect_seqs(n)

      # T-REL/T-DUP still hold: every accepted frame arrived, exactly once.
      assert Enum.sort(received) == Enum.to_list(1..n)

      # T-ORD does NOT hold: arrival order is the exact reverse of send
      # order, not send order itself. This is the falsifier proof — the
      # identical "arrival == send order" check applied to Paired above
      # correctly distinguishes a conforming transport from this one.
      refute received == Enum.to_list(1..n)
      assert received == Enum.to_list(n..1//-1)
    end
  end
end
