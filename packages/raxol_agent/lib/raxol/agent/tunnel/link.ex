defmodule Raxol.Agent.Tunnel.Link do
  @moduledoc """
  In-process link between two `Raxol.Agent.Tunnel` endpoints.

  Wires each endpoint's outbound `send_fun` to deliver frames into the other's
  mailbox as `{:tunnel_recv, binary}`. This is a real, deterministic transport
  (no network) for tests and same-node co-driving: the full open/data/close
  multiplex runs through the actual `Frame` encode/decode path.

  A cross-machine transport (Mint.WebSocket on the host dialling out to a
  Bandit/Cowboy endpoint on the server) is the production adapter: it does the
  same two things this helper does -- set each endpoint's `send_fun` to write the
  socket, and forward inbound socket bytes as `{:tunnel_recv, bytes}`.
  """

  alias Raxol.Agent.Tunnel

  @doc """
  Connect two endpoints so frames flow both ways in-process.

  Accepts pids or registered names. The host endpoint sends its hello frame when
  its link is attached.
  """
  @spec connect(Tunnel.server(), Tunnel.server()) :: :ok
  def connect(a, b) do
    a_pid = resolve(a)
    b_pid = resolve(b)

    :ok = Tunnel.set_link(b_pid, fn binary -> send(a_pid, {:tunnel_recv, binary}) end)
    :ok = Tunnel.set_link(a_pid, fn binary -> send(b_pid, {:tunnel_recv, binary}) end)
    :ok
  end

  defp resolve(pid) when is_pid(pid), do: pid

  defp resolve(name) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) -> pid
      _ -> raise ArgumentError, "no tunnel registered as #{inspect(name)}"
    end
  end
end
