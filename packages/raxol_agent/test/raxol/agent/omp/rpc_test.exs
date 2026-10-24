defmodule Raxol.Agent.OMP.RPCTest do
  # The client over a real Port, against the generic transcript player
  # (`test/support/gateway_transcript_player.exs`) replaying F3 transcripts
  # recorded from the real `omp --mode rpc`. Each test gets its own session
  # and binary.
  use ExUnit.Case, async: true

  alias Raxol.Agent.OMP.RPC
  alias Raxol.Agent.OMP.RPC.Codec
  alias Raxol.Agent.OMPTranscriptBinary

  @moduletag :tmp_dir

  @fixtures Path.expand("../../../fixtures/omp/rpc", __DIR__)

  # `omp` in the test's tmp dir, playing `transcript` in `mode`
  # (`Raxol.Agent.OMPTranscriptBinary`), so the client vets, version-checks
  # and spawns it like the real binary.
  defp write_binary(dir, transcript, mode),
    do: OMPTranscriptBinary.write(dir, Path.join(@fixtures, "#{transcript}.jsonl"), mode)

  defp session_dir(dir) do
    cwd = Path.join(dir, "session")
    File.mkdir_p!(cwd)
    cwd
  end

  defp start_rpc(dir, transcript, opts \\ []) do
    {mode, opts} = Keyword.pop(opts, :mode, "play")
    path = write_binary(dir, transcript, mode)

    start_supervised(
      {RPC,
       Keyword.merge(
         [path: path, cwd: session_dir(dir), profile: "raxol-test", subscriber: self()],
         opts
       )}
    )
  end

  # The command a transcript recorded, without its id, for a request that
  # must match it byte for byte (the 1 MiB `set_todos`).
  defp recorded_command(transcript, type) do
    Path.join(@fixtures, "#{transcript}.jsonl")
    |> File.stream!()
    |> Stream.map(&Jason.decode!/1)
    |> Enum.find_value(fn
      %{"in" => line} ->
        case Jason.decode!(line) do
          %{"type" => ^type} = command -> command
          _other -> nil
        end

      _ ->
        nil
    end)
    |> Map.delete("id")
  end

  test "the handshake negotiates v2 and each request gets its own response", %{tmp_dir: dir} do
    {:ok, rpc} = start_rpc(dir, "handshake")

    # Sent before `start_link/1` returned: the session forwards frames from
    # the moment omp prints them.
    assert_received {:omp_rpc, ^rpc, %{"type" => "available_commands_update"}}

    assert {:ok, %{"sessionId" => _, "dumpTools" => [_ | _]}} =
             RPC.request(rpc, %{"type" => "get_state"})

    assert {:ok, %{"models" => []}} = RPC.request(rpc, %{type: "get_available_models"})

    assert {:ok, %{"commands" => [_ | _]}} =
             RPC.request(rpc, %{"type" => "get_available_commands"})

    assert {:ok, %{"levels" => ["off" | _]}} =
             RPC.request(rpc, %{"type" => "get_available_thinking_levels"})

    ref = Process.monitor(rpc)
    assert :ok = RPC.close(rpc)
    assert_receive {:DOWN, ^ref, :process, ^rpc, :normal}, 5_000
  end

  test "a frame over the limit is reassembled and replies reach their own callers",
       %{tmp_dir: dir} do
    {:ok, rpc} = start_rpc(dir, "chunked_out_of_order")
    todos = recorded_command("chunked_out_of_order", "set_todos")

    # Sent from this process, so the barrier below orders it first: `bash`
    # takes id "1" and answers only after `set_todos` (id "2").
    {:ok, "bash", encoded} =
      Codec.encode_command(%{"type" => "bash", "command" => "sleep 1; echo done"})

    bash = :gen_server.send_request(rpc, {:request, "bash", encoded, 60_000})
    _ = :sys.get_state(rpc)

    assert {:ok, %{"todoPhases" => [%{"tasks" => [%{"content" => content}]}]}} =
             RPC.request(rpc, todos, 60_000)

    assert content == get_in(todos, ["phases", Access.at(0), "tasks", Access.at(0), "content"])
    assert byte_size(content) > 1_000_000

    assert {:reply, {:ok, %{"output" => "done\n", "exitCode" => 0}}} =
             :gen_server.receive_response(bash, 60_000)
  end

  test "a request past its deadline times out", %{tmp_dir: dir} do
    # The recorded `bash` is answered only after the `set_todos` sent with
    # it, which never comes.
    {:ok, rpc} = start_rpc(dir, "chunked_out_of_order")

    assert {:error, {:rpc_timeout, 200}} =
             RPC.request(rpc, %{"type" => "bash", "command" => "sleep 1; echo done"}, 200)
  end

  test "a prompt that never reached the agent settles on its prompt_result", %{tmp_dir: dir} do
    {:ok, rpc} = start_rpc(dir, "unreached_prompt")
    ref = Process.monitor(rpc)

    assert {:ok, nil} = RPC.request(rpc, %{"type" => "prompt", "message" => "hi"})
    assert :ok = RPC.close(rpc, 30_000)

    # OMP's second, failed response for the admitted prompt is forwarded.
    assert_received {:omp_rpc, ^rpc, %{"type" => "response", "id" => "1", "success" => false}}

    assert_received {:omp_rpc, ^rpc,
                     %{
                       "type" => "prompt_result",
                       "agentInvoked" => false,
                       "sessionSettled" => true
                     }}

    refute_received {:omp_rpc, ^rpc, %{"type" => "session_settled"}}
    assert_receive {:DOWN, ^ref, :process, ^rpc, :normal}, 5_000
  end

  describe "approvals" do
    @prompt %{
      "type" => "prompt",
      "message" => "Use the bash tool to run `echo raxol`. Do not write any text."
    }

    test "go to the principal, and close waits for session_settled", %{tmp_dir: dir} do
      {:ok, rpc} = start_rpc(dir, "approval", principal: self())

      assert {:ok, nil} = RPC.request(rpc, @prompt)
      closing = Task.async(fn -> RPC.close(rpc, 60_000) end)

      assert_receive {:omp_rpc_approval, ^rpc, ui_id,
                      %{"method" => "select", "options" => ["Approve" | _] = options}},
                     30_000

      assert "Deny" in options
      # The session cannot settle before the answer: omp waits for it.
      assert Task.yield(closing, 0) == nil

      assert {:error, :invalid_choice} = RPC.answer(rpc, ui_id, "Maybe")
      assert :ok = RPC.answer(rpc, ui_id, "Deny")
      assert {:error, :unknown_request} = RPC.answer(rpc, ui_id, "Deny")

      assert :ok = Task.await(closing, 60_000)
      assert_receive {:omp_rpc, ^rpc, %{"type" => "session_settled"}}, 5_000

      assert_received {:omp_rpc, ^rpc,
                       %{
                         "type" => "prompt_result",
                         "agentInvoked" => true,
                         "status" => "completed"
                       }}

      assert_received {:omp_rpc, ^rpc,
                       %{"type" => "tool_execution_end", "toolName" => "bash", "isError" => true}}
    end

    # The player answers nothing more unless the next line is the recorded
    # `Deny`, so the session settling proves the answer was sent.
    test "are denied when there is no principal", %{tmp_dir: dir} do
      {:ok, rpc} = start_rpc(dir, "approval")

      assert {:ok, nil} = RPC.request(rpc, @prompt)
      assert :ok = RPC.close(rpc, 60_000)
      refute_received {:omp_rpc_approval, _, _, _}
    end

    test "are denied when the principal exits", %{tmp_dir: dir} do
      principal = spawn(fn -> receive do: ({:omp_rpc_approval, _, _, _} -> :ok) end)
      {:ok, rpc} = start_rpc(dir, "approval", principal: principal)

      assert {:ok, nil} = RPC.request(rpc, @prompt)
      assert :ok = RPC.close(rpc, 60_000)
    end
  end

  describe "omp itself" do
    test "an exit fails the pending request and stops the session", %{tmp_dir: dir} do
      # Request 1 is the negotiation; omp exits 3 on matching request 2.
      {:ok, rpc} = start_rpc(dir, "handshake", mode: "exit-after:2:3")
      ref = Process.monitor(rpc)

      assert {:error, {:omp_exit, 3}} = RPC.request(rpc, %{"type" => "get_state"})
      assert_receive {:DOWN, ^ref, :process, ^rpc, {:shutdown, {:omp_exit, 3}}}, 5_000
    end

    test "an exit before the handshake fails the start", %{tmp_dir: dir} do
      assert {:error, {{:omp_exit, 3}, _child}} =
               start_rpc(dir, "handshake", mode: "exit-after:1:3")
    end

    test "no negotiation in time fails the start", %{tmp_dir: dir} do
      assert {:error, {:rpc_ready_timeout, _child}} =
               start_rpc(dir, "handshake", mode: "never-answer", ready_timeout_ms: 300)
    end
  end

  describe "a bad request fails only its own caller" do
    test "refusals happen in the caller, before any server is reached" do
      # No server by this name: anything that reached one would be
      # `:rpc_not_started`.
      absent = :"omp_rpc_absent_#{System.unique_integer([:positive])}"

      for timeout <- [:infinity, -1, 1.5, 4_294_967_296] do
        assert {:error, {:invalid_request, :timeout}} =
                 RPC.request(absent, %{"type" => "get_state"}, timeout)
      end

      assert {:error, {:invalid_request, Jason.EncodeError}} =
               RPC.request(absent, %{"type" => "prompt", "message" => <<"x", 0xFF>>})

      assert {:error, {:invalid_request, :id}} =
               RPC.request(absent, %{"type" => "get_state", "id" => "1"})

      assert {:error, {:invalid_request, :not_a_command}} =
               RPC.request(absent, %{"type" => "extension_ui_response"})

      assert {:error, :rpc_not_started} = RPC.request(absent, %{"type" => "get_state"})
    end

    test "a line over omp's frame limit is refused by the session", %{tmp_dir: dir} do
      {:ok, rpc} = start_rpc(dir, "handshake")
      big = %{"type" => "prompt", "message" => String.duplicate("x", 1_048_576)}

      assert {:error, {:invalid_request, :too_large}} = RPC.request(rpc, big)
      assert {:ok, %{"sessionId" => _}} = RPC.request(rpc, %{"type" => "get_state"})
    end

    test "the session's status shows no request content", %{tmp_dir: dir} do
      {:ok, rpc} = start_rpc(dir, "chunked_out_of_order")

      {:ok, "bash", encoded} =
        Codec.encode_command(%{"type" => "bash", "command" => "sleep 1; echo done"})

      _pending = :gen_server.send_request(rpc, {:request, "bash", encoded, 60_000})
      _ = :sys.get_state(rpc)

      status = rpc |> :sys.get_status() |> inspect(limit: :infinity, printable_limit: :infinity)
      refute status =~ "echo done"
      assert status =~ "pending: 1"

      redacted = RPC.format_status(%{message: {:request, "bash", encoded, 60_000}})
      refute inspect(redacted, limit: :infinity, printable_limit: :infinity) =~ "echo done"
    end
  end

  describe "start refuses" do
    test "a profile that could be read as a flag or a path", %{tmp_dir: dir} do
      for profile <- ["--yolo", "../x", "", nil] do
        assert {:error, {:invalid_profile, _child}} =
                 start_rpc(dir, "handshake", profile: profile)
      end
    end

    test "the BEAM's working directory and relative or missing ones", %{tmp_dir: dir} do
      assert {:error, {{:invalid_cwd, :beam_cwd}, _}} =
               start_rpc(dir, "handshake", cwd: File.cwd!())

      assert {:error, {{:invalid_cwd, :not_absolute}, _}} =
               start_rpc(dir, "handshake", cwd: "session")

      assert {:error, {{:invalid_cwd, :enoent}, _}} =
               start_rpc(dir, "handshake", cwd: Path.join(dir, "absent"))
    end

    @tag :unix_only
    test "a working directory others may write", %{tmp_dir: dir} do
      shared = Path.join(dir, "shared")
      File.mkdir!(shared)
      File.chmod!(shared, 0o777)

      assert {:error, {{:invalid_cwd, {:group_or_other_writable, 0o777}}, _}} =
               start_rpc(dir, "handshake", cwd: shared)
    end

    test "a missing subscriber", %{tmp_dir: dir} do
      assert {:error, {{:invalid_option, :subscriber}, _}} =
               start_rpc(dir, "handshake", subscriber: nil)
    end
  end
end
