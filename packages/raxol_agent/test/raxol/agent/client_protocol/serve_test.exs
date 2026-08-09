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

  describe "apply_requested_model/2" do
    test "a harness-requested provider/model becomes the backend and model" do
      env = %{"HARBOR_ACP_REQUESTED_MODEL" => "anthropic/claude-sonnet-4-5"}

      assert {:ok, opts} = Serve.apply_requested_model([], env)
      assert Keyword.get(opts, :backend) == "anthropic"
      assert Keyword.get(opts, :model) == "claude-sonnet-4-5"
    end

    test "only the FIRST slash splits, so a qualified model name survives" do
      env = %{
        "HARBOR_ACP_REQUESTED_MODEL" => "openrouter/meta-llama/llama-3.1-70b"
      }

      assert {:ok, opts} = Serve.apply_requested_model([], env)
      assert Keyword.get(opts, :backend) == "openrouter"
      assert Keyword.get(opts, :model) == "meta-llama/llama-3.1-70b"
    end

    test "an absent or blank request leaves opts untouched" do
      for env <- [
            %{},
            %{"HARBOR_ACP_REQUESTED_MODEL" => ""},
            %{"HARBOR_ACP_REQUESTED_MODEL" => "   "}
          ] do
        assert {:ok, []} = Serve.apply_requested_model([], env)
      end
    end

    # Fail CLOSED. Ignoring a set-but-broken request would serve a different
    # model than the harness recorded, which is the misattribution this reader
    # exists to prevent.
    test "a set but unparseable request is refused, not ignored" do
      for bad <- ["claude-sonnet-4-5", "anthropic/", "/claude", "/"] do
        env = %{"HARBOR_ACP_REQUESTED_MODEL" => bad}

        assert {:error, message} = Serve.apply_requested_model([], env)
        assert message =~ "HARBOR_ACP_REQUESTED_MODEL must be provider/model"
        assert message =~ inspect(bad)
      end
    end

    test "--model wins over the harness request" do
      env = %{"HARBOR_ACP_REQUESTED_MODEL" => "anthropic/claude-sonnet-4-5"}

      assert {:ok, opts} = Serve.apply_requested_model([model: "gpt-5"], env)
      assert Keyword.get(opts, :model) == "gpt-5"
    end

    # Ignored WHOLE, not merged per key: pairing a flagged provider with a
    # model from another provider would be a silently wrong request.
    test "--backend suppresses the request entirely rather than merging it" do
      env = %{"HARBOR_ACP_REQUESTED_MODEL" => "anthropic/claude-sonnet-4-5"}

      assert {:ok, opts} = Serve.apply_requested_model([backend: "openai"], env)
      assert Keyword.get(opts, :backend) == "openai"
      refute Keyword.has_key?(opts, :model)
    end

    test "the deprecated --harness alias suppresses it too" do
      env = %{"HARBOR_ACP_REQUESTED_MODEL" => "anthropic/claude-sonnet-4-5"}

      assert {:ok, opts} = Serve.apply_requested_model([harness: "openai"], env)
      refute Keyword.has_key?(opts, :model)
    end
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
