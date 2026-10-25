defmodule Raxol.Agent.OMP.RPCTest do
  # The client over a real Port, against the generic transcript player
  # (`test/support/gateway_transcript_player.exs`) replaying F3 transcripts
  # recorded from the real `omp --mode rpc`. Each test gets its own session
  # and binary, in a directory outside the BEAM's cwd (ExUnit's `:tmp_dir`
  # is inside it, so a session there is refused).
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Raxol.Agent.OMP.RPC
  alias Raxol.Agent.OMP.RPC.Codec
  alias Raxol.Agent.OMP.Version
  alias Raxol.Agent.OMPTranscriptBinary

  @fixtures Path.expand("../../../fixtures/omp/rpc", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "raxol_omp_rpc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

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

  defp rpc_opts(dir, transcript, opts) do
    {mode, opts} = Keyword.pop(opts, :mode, "play")
    path = write_binary(dir, transcript, mode)

    Keyword.merge(
      [path: path, cwd: session_dir(dir), profile: "raxol-test", subscriber: self()],
      opts
    )
  end

  defp start_rpc(dir, transcript, opts),
    do: start_supervised({RPC, rpc_opts(dir, transcript, opts)})

  defp start_ready(dir, transcript, opts \\ []) do
    {:ok, rpc} = start_rpc(dir, transcript, opts)
    assert :ok = RPC.await_ready(rpc)
    rpc
  end

  # Linked from birth, so a failed handshake's exit reason always arrives,
  # however early the session stops.
  defp start_linked(dir, transcript, opts) do
    Process.flag(:trap_exit, true)
    {:ok, rpc} = RPC.start_link(rpc_opts(dir, transcript, opts))
    rpc
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

  test "the handshake negotiates v2 and each request gets its own response", %{dir: dir} do
    rpc = start_ready(dir, "handshake")

    # Sent before the session was ready: it forwards frames from the moment
    # omp prints them.
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
       %{dir: dir} do
    rpc = start_ready(dir, "chunked_out_of_order")
    todos = recorded_command("chunked_out_of_order", "set_todos")

    # Sent from this process, so the barrier below orders it first: `bash`
    # takes id "1" and answers only after `set_todos` (id "2").
    #
    # The player relabels the ids of plain lines but not the id inside a
    # chunk run's base64 (it stays content-free), so the reassembled reply
    # keeps its recorded id "2". It reaches the `set_todos` caller because
    # this session assigns the same ids in the same order as the capture.
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

  test "a request past its deadline times out", %{dir: dir} do
    # The recorded `bash` is answered only after the `set_todos` sent with
    # it, which never comes.
    rpc = start_ready(dir, "chunked_out_of_order")

    assert {:error, {:rpc_timeout, 200}} =
             RPC.request(rpc, %{"type" => "bash", "command" => "sleep 1; echo done"}, 200)
  end

  test "a prompt that never reached the agent settles on its prompt_result", %{dir: dir} do
    rpc = start_ready(dir, "unreached_prompt")
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

    test "go to the principal, and close waits for session_settled", %{dir: dir} do
      rpc = start_ready(dir, "approval", principal: self())

      assert {:ok, nil} = RPC.request(rpc, @prompt)
      closing = Task.async(fn -> RPC.close(rpc, 60_000) end)

      assert_receive {:omp_rpc_approval, ^rpc, ui_id,
                      %{"method" => "select", "options" => ["Approve" | _] = options}},
                     30_000

      assert "Deny" in options
      # The session cannot settle before the answer: omp waits for it.
      assert Task.yield(closing, 0) == nil

      # The subscriber sees the frame too, but only the principal answers.
      not_principal = Task.async(fn -> RPC.answer(rpc, ui_id, "Approve") end)
      assert {:error, :not_principal} = Task.await(not_principal)

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
    test "are denied when there is no principal", %{dir: dir} do
      rpc = start_ready(dir, "approval")

      assert {:ok, nil} = RPC.request(rpc, @prompt)
      assert :ok = RPC.close(rpc, 60_000)
      refute_received {:omp_rpc_approval, _, _, _}
    end

    test "are denied when the principal exits", %{dir: dir} do
      principal = spawn(fn -> receive do: ({:omp_rpc_approval, _, _, _} -> :ok) end)
      rpc = start_ready(dir, "approval", principal: principal)

      assert {:ok, nil} = RPC.request(rpc, @prompt)
      assert :ok = RPC.close(rpc, 60_000)
    end

    test "an open approval shows in the session's status only as a count", %{dir: dir} do
      rpc = start_ready(dir, "approval", principal: self())
      assert {:ok, nil} = RPC.request(rpc, @prompt)

      assert_receive {:omp_rpc_approval, ^rpc, ui_id, %{"title" => "Allow tool: bash" <> _}},
                     30_000

      # Unredacted, the state holds the approval's options, which name the
      # tool ("Approve bash for this session").
      status = rpc |> :sys.get_status() |> inspect(limit: :infinity, printable_limit: :infinity)
      assert status =~ "approvals: 1"
      refute status =~ "for this session"
      refute status =~ "echo raxol"

      assert :ok = RPC.answer(rpc, ui_id, "Deny")
      assert :ok = RPC.close(rpc, 60_000)
    end
  end

  describe "omp itself" do
    test "an exit fails the pending request and stops the session", %{dir: dir} do
      # Request 1 is the negotiation; omp exits 3 on matching request 2.
      rpc = start_ready(dir, "handshake", mode: "exit-after:2:3")
      ref = Process.monitor(rpc)

      assert {:error, {:omp_exit, 3}} = RPC.request(rpc, %{"type" => "get_state"})
      assert_receive {:DOWN, ^ref, :process, ^rpc, {:shutdown, {:omp_exit, 3}}}, 5_000
    end

    @tag capture_log: true
    test "an exit before the handshake stops the session with the reason", %{dir: dir} do
      rpc = start_linked(dir, "handshake", mode: "exit-after:1:3")
      assert_receive {:EXIT, ^rpc, {:omp_exit, 3}}, 30_000
    end

    @tag capture_log: true
    test "no negotiation in time stops the session", %{dir: dir} do
      rpc = start_linked(dir, "handshake", mode: "never-answer", ready_timeout_ms: 300)
      assert_receive {:EXIT, ^rpc, :rpc_ready_timeout}, 30_000
    end

    @tag capture_log: true
    test "start_link returns before the handshake; requests wait for it", %{dir: dir} do
      # omp prints its ready frame and never answers the negotiation.
      rpc = start_linked(dir, "handshake", mode: "never-answer")

      assert {:error, :not_ready} = RPC.request(rpc, %{"type" => "get_state"})
      waiting = :gen_server.send_request(rpc, :await_ready)
      %{phase: phase, os_pid: os_pid} = :sys.get_state(rpc)
      assert phase in [:starting, :negotiating]

      # A waiting caller gets the reason the handshake failed.
      {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
      assert {:reply, {:error, {:omp_exit, 137}}} = :gen_server.receive_response(waiting, 30_000)
      assert_receive {:EXIT, ^rpc, {:omp_exit, 137}}, 5_000
    end

    test "close before the handshake finished stops the session", %{dir: dir} do
      rpc = start_linked(dir, "handshake", mode: "never-answer")
      assert :ok = RPC.close(rpc)
      assert_receive {:EXIT, ^rpc, :normal}, 5_000
    end

    @tag skip: Elixir.Version.parse!(Version.tested()).minor == 0 && "the pin has no lower minor"
    test "a minor below the pin logs a warning and the handshake completes", %{dir: dir} do
      %{major: major, minor: minor} = Elixir.Version.parse!(Version.tested())
      older = "#{major}.#{minor - 1}.0"
      pinned = ~s("omp_version":"#{Version.tested()}")
      recorded = File.read!(Path.join(@fixtures, "handshake.jsonl"))
      assert [_, _] = String.split(recorded, pinned)

      fixture = Path.join(dir, "older_minor.jsonl")
      File.write!(fixture, String.replace(recorded, pinned, ~s("omp_version":"#{older}")))
      path = OMPTranscriptBinary.write(dir, fixture, "play")
      opts = [path: path, cwd: session_dir(dir), profile: "raxol-test", subscriber: self()]

      log =
        capture_log(fn ->
          {:ok, rpc} = start_supervised({RPC, opts})
          assert :ok = RPC.await_ready(rpc)
        end)

      assert log =~ "omp #{older} is older than the tested #{Version.tested()}; continuing"
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

    test "a line over omp's frame limit is refused by the session", %{dir: dir} do
      rpc = start_ready(dir, "handshake")
      big = %{"type" => "prompt", "message" => String.duplicate("x", 1_048_576)}

      assert {:error, {:invalid_request, :too_large}} = RPC.request(rpc, big)
      assert {:ok, %{"sessionId" => _}} = RPC.request(rpc, %{"type" => "get_state"})
    end

    test "a crash report's last message shows no request content" do
      {:ok, "bash", encoded} =
        Codec.encode_command(%{"type" => "bash", "command" => "sleep 1; echo done"})

      redacted = RPC.format_status(%{message: {:request, "bash", encoded, 60_000}})
      refute inspect(redacted, limit: :infinity, printable_limit: :infinity) =~ "echo done"
    end
  end

  describe "start refuses" do
    test "a profile that could be read as a flag or a path", %{dir: dir} do
      for profile <- ["--yolo", "../x", "", nil] do
        assert {:error, {:invalid_profile, _child}} =
                 start_rpc(dir, "handshake", profile: profile)
      end
    end

    test "the BEAM's working directory under any name, and relative or missing ones",
         %{dir: dir} do
      assert {:error, {{:invalid_cwd, :beam_cwd}, _}} =
               start_rpc(dir, "handshake", cwd: File.cwd!())

      # A symlink names the same directory; paths would differ.
      link = Path.join(dir, "beam_link")
      File.ln_s!(File.cwd!(), link)

      assert {:error, {{:invalid_cwd, :beam_cwd}, _}} =
               start_rpc(dir, "handshake", cwd: link)

      assert {:error, {{:invalid_cwd, :not_absolute}, _}} =
               start_rpc(dir, "handshake", cwd: "session")

      assert {:error, {{:invalid_cwd, :enoent}, _}} =
               start_rpc(dir, "handshake", cwd: Path.join(dir, "absent"))
    end

    # ExUnit's `:tmp_dir` is inside the BEAM's cwd (the project's `tmp/`).
    @tag :tmp_dir
    test "a directory inside the BEAM's working directory, under any name",
         %{dir: dir, tmp_dir: inside} do
      assert {:error, {{:invalid_cwd, :inside_beam_cwd}, _}} =
               start_rpc(dir, "handshake", cwd: inside)

      link = Path.join(dir, "inside_link")
      File.ln_s!(inside, link)

      assert {:error, {{:invalid_cwd, :inside_beam_cwd}, _}} =
               start_rpc(dir, "handshake", cwd: link)

      # A directory outside it, next to the link, is accepted.
      assert is_pid(start_ready(dir, "handshake"))
    end

    @tag :unix_only
    test "a working directory others may write", %{dir: dir} do
      shared = Path.join(dir, "shared")
      File.mkdir!(shared)
      File.chmod!(shared, 0o777)

      assert {:error, {{:invalid_cwd, {:group_or_other_writable, 0o777}}, _}} =
               start_rpc(dir, "handshake", cwd: shared)
    end

    test "a missing subscriber", %{dir: dir} do
      assert {:error, {{:invalid_option, :subscriber}, _}} =
               start_rpc(dir, "handshake", subscriber: nil)
    end
  end
end
