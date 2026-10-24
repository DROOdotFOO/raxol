defmodule Raxol.Agent.OMP.RPCLiveTest do
  # Twins of the F3 no-model paths on the real `omp` binary. No model call:
  # the profile's only model is a keyless local provider on a port nothing
  # listens on, and no test here prompts.
  #
  # Not async: omp finds its profiles under $HOME, which these tests point at
  # a throwaway directory, and one test changes the VM's cwd.
  #
  #   mix test --only omp
  use ExUnit.Case, async: false

  alias Raxol.Agent.Backend.OmpGateway
  alias Raxol.Agent.OMP.RPC
  alias Raxol.Agent.OMP.RPC.Codec

  @moduletag :omp
  @moduletag :unix_only

  @profile "raxol-rpc-live"
  @models_yml """
  providers:
    raxol-offline:
      baseUrl: http://127.0.0.1:9/v1
      api: openai-completions
      auth: none
      models:
        - id: offline
          name: Offline (never answers)
  """

  setup_all do
    {:ok, omp} = OmpGateway.resolve_binary(nil)

    home =
      Path.join(System.tmp_dir!(), "raxol_omp_rpc_home_#{System.unique_integer([:positive])}")

    agent_dir = Path.join(home, ".omp/profiles/#{@profile}/agent")
    File.mkdir_p!(agent_dir)
    File.write!(Path.join(agent_dir, "models.yml"), @models_yml)

    real_home = System.get_env("HOME")
    System.put_env("HOME", home)

    on_exit(fn ->
      System.put_env("HOME", real_home)
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

  test "a session negotiates v2, answers a request and closes", %{opts: opts} do
    {:ok, rpc} = start_supervised({RPC, opts})
    ref = Process.monitor(rpc)

    assert {:ok, %{"model" => %{"provider" => "raxol-offline"}, "isSettled" => true}} =
             RPC.request(rpc, %{"type" => "get_state"})

    assert :ok = RPC.close(rpc)
    assert_receive {:DOWN, ^ref, :process, ^rpc, :normal}, 5_000
  end

  test "a reply over the frame limit is reassembled; bash answers after it", %{opts: opts} do
    {:ok, rpc} = start_supervised({RPC, opts})

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

  test "a profile with no model exits before its ready frame", %{opts: opts} do
    assert {:error, {{:omp_exit, 1}, _child}} =
             start_supervised({RPC, Keyword.put(opts, :profile, "raxol-rpc-unprovisioned")})
  end

  test "the BEAM's .omp/extensions never run; the session's own cwd is used",
       %{dir: dir, opts: opts} do
    beam_cwd = Path.join(dir, "beam")
    beam_marker = Path.join(dir, "BEAM_MARKER")
    session_marker = Path.join(dir, "SESSION_MARKER")
    write_probe(beam_cwd, beam_marker)
    write_probe(opts[:cwd], session_marker)

    File.cd!(beam_cwd, fn ->
      {:ok, rpc} = start_supervised({RPC, opts})
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
