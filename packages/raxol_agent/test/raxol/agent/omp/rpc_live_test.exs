defmodule Raxol.Agent.OMP.RPCLiveTest do
  # Twins of the F3 no-model paths on the real `omp` binary. No model call:
  # the profiles' only model is a provider on a port nothing listens on,
  # keyless or with a key command that fails, every credential-looking
  # variable is removed from the VM's environment, and HTTP(S) goes to a
  # proxy on that same dead port (omp fetches model catalogs at startup).
  #
  # Not async: omp finds its profiles under $HOME, which these tests point at
  # a throwaway directory, the environment is changed for the whole VM, and
  # one test changes the VM's cwd.
  #
  #   mix test --only omp
  use ExUnit.Case, async: false

  alias Raxol.Agent.Backend.OmpGateway
  alias Raxol.Agent.OMP.RPC
  alias Raxol.Agent.OMP.RPC.Codec

  @moduletag :omp
  @moduletag :unix_only

  @profile "raxol-rpc-live"
  # A prompt fails before the agent runs: its key command resolves nothing.
  @keyless_profile "raxol-rpc-live-keyless"
  @dead "http://127.0.0.1:9"
  @models_yml """
  providers:
    raxol-offline:
      baseUrl: #{@dead}/v1
      api: openai-completions
      auth: none
      models:
        - id: offline
          name: Offline (never answers)
  """
  @keyless_models_yml """
  providers:
    raxol-offline:
      baseUrl: #{@dead}/v1
      api: openai-completions
      apiKey: "!false"
      models:
        - id: offline
          name: Offline (never answers)
  """

  setup_all do
    {:ok, omp} = OmpGateway.resolve_binary(nil)

    home =
      Path.join(System.tmp_dir!(), "raxol_omp_rpc_home_#{System.unique_integer([:positive])}")

    for {profile, models} <- [{@profile, @models_yml}, {@keyless_profile, @keyless_models_yml}] do
      agent_dir = Path.join(home, ".omp/profiles/#{profile}/agent")
      File.mkdir_p!(agent_dir)
      File.write!(Path.join(agent_dir, "models.yml"), models)
    end

    credentials =
      for {name, _value} <- System.get_env(),
          String.match?(name, ~r/KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|BROKER/i),
          do: name

    changed = ["HOME", "HTTPS_PROXY", "HTTP_PROXY" | credentials]
    saved = Map.new(changed, &{&1, System.get_env(&1)})
    Enum.each(credentials, &System.delete_env/1)
    System.put_env(%{"HOME" => home, "HTTPS_PROXY" => @dead, "HTTP_PROXY" => @dead})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      File.rm_rf!(home)
    end)

    %{binary: omp}
  end

  setup %{binary: omp} do
    dir = Path.join(System.tmp_dir!(), "raxol_omp_rpc_#{System.unique_integer([:positive])}")
    cwd = Path.join(dir, "session")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, opts: [path: omp, cwd: cwd, profile: @profile, subscriber: self()]}
  end

  defp start_ready(opts) do
    {:ok, rpc} = start_supervised({RPC, opts})
    assert :ok = RPC.await_ready(rpc)
    rpc
  end

  test "a session negotiates v2, answers a request and closes", %{opts: opts} do
    rpc = start_ready(opts)
    ref = Process.monitor(rpc)

    assert {:ok, %{"model" => %{"provider" => "raxol-offline"}, "isSettled" => true}} =
             RPC.request(rpc, %{"type" => "get_state"})

    assert :ok = RPC.close(rpc)
    assert_receive {:DOWN, ^ref, :process, ^rpc, :normal}, 5_000
  end

  test "a reply over the frame limit is reassembled; bash answers after it", %{opts: opts} do
    rpc = start_ready(opts)

    # Sent from this process, so the barrier below orders it first: `bash`
    # takes id "1", and `set_todos` (id "2") is exactly OMP's 1 MiB limit.
    {:ok, "bash", encoded} =
      Codec.encode_command(%{"type" => "bash", "command" => "sleep 1; echo done"})

    bash = :gen_server.send_request(rpc, {:request, "bash", encoded, 30_000})
    _ = :sys.get_state(rpc)

    todos = fn content ->
      %{
        "type" => "set_todos",
        "phases" => [
          %{"name" => "Todos", "tasks" => [%{"content" => content, "status" => "pending"}]}
        ]
      }
    end

    overhead = byte_size(Jason.encode!(Map.put(todos.(""), "id", "2"))) + 1
    content = String.duplicate("x", 1_048_576 - overhead)

    assert {:ok, %{"todoPhases" => [%{"tasks" => [%{"content" => ^content}]}]}} =
             RPC.request(rpc, todos.(content))

    assert {:reply, {:ok, %{"output" => "done\n"}}} = :gen_server.receive_response(bash, 30_000)
  end

  test "a prompt that never reached the agent settles on its prompt_result", %{opts: opts} do
    rpc = start_ready(Keyword.put(opts, :profile, @keyless_profile))
    ref = Process.monitor(rpc)

    assert {:ok, nil} = RPC.request(rpc, %{"type" => "prompt", "message" => "hi"})
    assert :ok = RPC.close(rpc, 30_000)

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

  @tag capture_log: true
  test "a profile with no model stops the session before its ready frame", %{opts: opts} do
    Process.flag(:trap_exit, true)
    {:ok, rpc} = RPC.start_link(Keyword.put(opts, :profile, "raxol-rpc-unprovisioned"))
    assert_receive {:EXIT, ^rpc, {:omp_exit, 1}}, 30_000
  end

  test "stopping the session aborts an RPC bash in flight", %{dir: dir, opts: opts} do
    fifo = Path.join(dir, "bash.fifo")
    marker = Path.join(dir, "BASH_FINISHED")
    {_, 0} = System.cmd("mkfifo", [fifo])

    # `cat` prints what the command writes to the FIFO and exits once every
    # writer is gone: the command's `sh` and its `sleep`, and omp itself at
    # the latest. (omp runs `bash` in its own shell, which has no `exec`.)
    cat =
      Port.open({:spawn_executable, System.find_executable("cat")}, [
        :binary,
        :exit_status,
        {:line, 64},
        {:args, [fifo]}
      ])

    rpc = start_ready(opts)
    command = ~s(sh -c "exec 3>'#{fifo}'; echo started >&3; sleep 5; touch '#{marker}'")
    bash = Task.async(fn -> RPC.request(rpc, %{"type" => "bash", "command" => command}) end)

    assert_receive {^cat, {:data, {:eol, "started"}}}, 30_000
    GenServer.stop(rpc)
    assert {:error, :rpc_down} = Task.await(bash)

    # Once the command can no longer write, it can no longer finish either.
    assert_receive {^cat, {:exit_status, 0}}, 60_000
    refute File.exists?(marker)
  end

  test "the BEAM's .omp/extensions never run; the session's own cwd is used",
       %{dir: dir, opts: opts} do
    beam_cwd = Path.join(dir, "beam")
    beam_marker = Path.join(dir, "BEAM_MARKER")
    session_marker = Path.join(dir, "SESSION_MARKER")
    write_probe(beam_cwd, beam_marker)
    write_probe(opts[:cwd], session_marker)
    link = Path.join(dir, "beam_link")
    File.ln_s!(beam_cwd, link)

    File.cd!(beam_cwd, fn ->
      # Another name for the BEAM's cwd is refused before omp is spawned.
      for cwd <- [link, beam_cwd, File.cwd!()] do
        assert {:error, {{:invalid_cwd, :beam_cwd}, _child}} =
                 start_supervised({RPC, Keyword.put(opts, :cwd, cwd)})
      end

      rpc = start_ready(opts)
      assert {:ok, _state} = RPC.request(rpc, %{"type" => "get_state"})
      assert :ok = RPC.close(rpc)
    end)

    refute File.exists?(beam_marker)
    assert File.exists?(session_marker)
  end

  defp write_probe(cwd, marker) do
    File.mkdir_p!(Path.join(cwd, ".omp/extensions"))

    File.write!(Path.join(cwd, ".omp/extensions/probe.ts"), """
    import { writeFileSync } from "node:fs";
    export default function () { writeFileSync(#{inspect(marker)}, "ran"); }
    """)
  end
end
