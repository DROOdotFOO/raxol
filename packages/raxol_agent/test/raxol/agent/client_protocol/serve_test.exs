defmodule Raxol.Agent.ClientProtocol.ServeTest do
  @moduledoc """
  `raxol acp` must END when its editor closes the wire.

  Nothing covered `Serve` at all: the stdio agent tests drive the handler over
  an in-process transport and never reach the serving loop, which is where both
  callers broke -- the mix task exiting 1 on a clean disconnect, and the
  packaged binary never exiting at all.
  """
  use ExUnit.Case, async: false

  alias Raxol.Agent.ClientProtocol.Serve
  alias Raxol.AgentClientProtocol.Transport.Paired

  @moduletag :unix_only

  setup do
    {left, right} = Paired.create_pair()

    on_exit(fn ->
      for %Paired{pid: pid} <- [left, right], Process.alive?(pid) do
        Paired.close(%Paired{pid: pid})
      end
    end)

    %{left: left, right: right}
  end

  test "a peer disconnect ends serving with exit code 0", ctx do
    serving = start_serving(ctx.left)

    Paired.close(ctx.right)

    assert_receive {:acp_exit, ^serving, 0}, 5_000
  end

  test "an abnormal connection exit ends serving with a non-zero code", ctx do
    serving = start_serving(ctx.left)

    {:ok, connection} = connection_of(ctx.left)
    Process.exit(connection, :kill)

    assert_receive {:acp_exit, ^serving, 1}, 5_000
  end

  # Spawned UNLINKED: before the fix the supervisor's :shutdown travels down
  # start_link's link, which would take the ExUnit process with it.
  defp start_serving(handle) do
    test = self()

    {pid, _ref} =
      spawn_monitor(fn ->
        code =
          Serve.serve_connection({Paired, handle}, %{
            turn_opts: [backend: Raxol.Agent.Backend.Mock]
          })

        send(test, {:acp_exit, self(), code})
      end)

    # Paired drops frames sent before the Connection adopts the handle, so wait
    # for the adoption rather than racing it.
    wait_until(fn -> match?({:ok, _}, connection_of(handle)) end)
    pid
  end

  defp connection_of(%Paired{pid: pid}) do
    case :sys.get_state(pid) do
      %{owner: owner} when is_pid(owner) -> {:ok, owner}
      _ -> :error
    end
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries > 0 -> Process.sleep(5) && wait_until(fun, tries - 1)
      true -> flunk("the connection never adopted the transport handle")
    end
  end
end
