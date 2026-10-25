defmodule Raxol.Agent.OMP.LaneTest do
  # The lane over a real Port, against the generic transcript player
  # replaying the F3 `approval` recording, fronted by a real SSH connection:
  # a `Raxol.SSH.Server` on an ephemeral port, a client key generated per
  # test, and the server-side connection the served app was handed.
  use ExUnit.Case, async: true

  alias Raxol.Agent.OMP.Lane
  alias Raxol.Agent.OMP.RPC
  alias Raxol.Agent.OMPTranscriptBinary

  @fixtures Path.expand("../../../fixtures/omp/rpc", __DIR__)
  @prompt "Use the bash tool to run `echo raxol`. Do not write any text."

  defmodule ConnectionProbe do
    @moduledoc false
    # Hands its `:ssh_connection` option to the test.
    def init(%{options: options}) do
      send(Keyword.fetch!(options, :probe), {:ssh_connection, options[:ssh_connection]})
      %{}
    end

    def update(_msg, model), do: {model, []}
    def view(_model), do: Raxol.Core.Renderer.View.text("probe")
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:ssh)
    dir = Path.join(System.tmp_dir!(), "raxol_omp_lane_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "session"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp rpc_opts(dir) do
    path = OMPTranscriptBinary.write(dir, Path.join(@fixtures, "approval.jsonl"), "play")
    [path: path, cwd: Path.join(dir, "session"), profile: "raxol-test"]
  end

  # A server in `auth` mode (`:tenants_dir` or `:authorized_keys_dir`) that
  # accepts one generated key for `user`, and the server-side
  # `{server, connection}` its app was handed for that user's connection.
  defp ssh_connection(dir, auth, user) do
    client_dir = Path.join(dir, "client")
    keys_dir = Path.join(dir, "keys")
    write_keys(client_dir, keys_dir, auth, user)
    name = :"omp_lane_ssh_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Raxol.SSH.Server,
       [
         {auth, keys_dir},
         app_module: ConnectionProbe,
         app_opts: [probe: self()],
         port: 0,
         host_keys_dir: Path.join(dir, "host"),
         name: name
       ]}
    )

    {:ok, conn} =
      :ssh.connect(~c"127.0.0.1", Raxol.SSH.Server.port(name),
        user: String.to_charlist(user),
        silently_accept_hosts: true,
        save_accepted_host: false,
        user_interaction: false,
        user_dir: String.to_charlist(client_dir)
      )

    on_exit(fn -> :ssh.close(conn) end)
    {:ok, channel} = :ssh_connection.session_channel(conn, 5_000)
    # The handler answers no want_reply, so the reply is not awaited.
    {:ok, _} = Task.start(fn -> :ssh_connection.ptty_alloc(conn, channel, term: ~c"xterm") end)
    assert_receive {:ssh_connection, {^name, _connection} = server_side}, 10_000
    server_side
  end

  # The client's private key, and its public key filed for `user` the way
  # the `auth` mode reads it.
  defp write_keys(client_dir, keys_dir, auth, user) do
    key = :public_key.generate_key({:namedCurve, :secp256r1})

    keys_file =
      if auth == :tenants_dir,
        do: Path.join([keys_dir, user, "ssh", "authorized_keys"]),
        else: Path.join(keys_dir, "authorized_keys")

    File.mkdir_p!(client_dir)
    File.mkdir_p!(Path.dirname(keys_file))
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
    File.write!(Path.join(client_dir, "id_ecdsa"), pem)
    public = :ssh_file.extract_public_key(key)
    File.write!(keys_file, :ssh_file.encode([{public, [comment: ~c"test"]}], :auth_keys))
  end

  test "an exec tool's approval reaches the principal, and the run maps to contract events",
       %{dir: dir} do
    {server, connection} = ssh_connection(dir, :tenants_dir, "alice")
    session_id = "omp-lane-#{System.unique_integer([:positive])}"

    {:ok, lane} =
      start_supervised(
        {Lane,
         principal: {:ssh, server, connection, self()}, session_id: session_id, rpc: rpc_opts(dir)}
      )

    session = Lane.session(lane)
    assert :ok = Lane.subscribe(session)
    assert :ok = RPC.await_ready(session.rpc)
    assert :ok = Lane.prompt(session, %{text: @prompt})

    rpc = session.rpc

    assert_receive {:omp_rpc_approval, ^rpc, ui_id,
                    %{"title" => "Allow tool: bash" <> _, "options" => options}},
                   30_000

    assert options == ["Approve", "Approve bash for this session", "Deny"]
    # The player plays on only after the recorded `Deny`.
    assert :ok = RPC.answer(rpc, ui_id, "Deny")
    ref = Lane.monitor(session)
    assert :ok = Lane.close(session)
    # The lane stops after OMP's last frame: every event has been sent.
    assert_receive {:DOWN, ^ref, :process, ^lane, :normal}, 5_000

    events = drain_events(session_id)

    assert [
             {:turn_started, %{prompt: @prompt}},
             {:item_started, %{item_type: :tool_use}},
             {:item_completed, %{item_type: :tool_use, name: "bash"}},
             {:item_started, %{item_type: :tool_result}},
             {:item_completed, %{item_type: :tool_result, name: "bash", is_error: true}},
             {:turn_completed, %{final: false}},
             {:item_started, %{item_type: :message}}
             | rest
           ] = Enum.map(events, &{&1.type, &1.payload})

    {deltas, tail} = Enum.split_while(rest, &match?({:item_delta, _}, &1))

    assert [
             {:item_completed, %{item_type: :message, content: answer}},
             {:turn_completed, %{final: false}},
             {:turn_completed, %{final: true}}
           ] = tail

    assert Enum.map_join(deltas, fn {:item_delta, %{chunk: chunk}} -> chunk end) == answer
    assert Enum.all?(events, &(&1.turn_id == "t1" and &1.provenance.trust == :tainted))
    assert Enum.map(events, & &1.id) == Enum.to_list(1..length(events))
  end

  test "the lane stops when its principal exits", %{dir: dir} do
    {server, connection} = ssh_connection(dir, :tenants_dir, "alice")
    test = self()

    principal =
      spawn(fn ->
        receive do: ({:omp_rpc_approval, _rpc, ui_id, _frame} -> send(test, {:asked, ui_id}))
      end)

    {:ok, lane} =
      start_supervised(
        {Lane,
         principal: {:ssh, server, connection, principal}, session_id: "s", rpc: rpc_opts(dir)}
      )

    session = Lane.session(lane)
    lane_ref = Lane.monitor(session)
    rpc_ref = Process.monitor(session.rpc)
    assert :ok = RPC.await_ready(session.rpc)
    assert :ok = Lane.prompt(session, %{text: @prompt})

    # The principal took the approval and exited without answering.
    assert_receive {:asked, _ui_id}, 30_000
    assert_receive {:DOWN, ^lane_ref, :process, ^lane, {:shutdown, :principal_down}}, 5_000
    assert_receive {:DOWN, ^rpc_ref, :process, _rpc, _reason}, 5_000
  end

  test "prompt/2 refuses once the principal no longer authenticates", %{dir: dir} do
    {server, connection} = ssh_connection(dir, :tenants_dir, "alice")

    {:ok, lane} =
      start_supervised(
        {Lane, principal: {:ssh, server, connection, self()}, session_id: "s", rpc: rpc_opts(dir)}
      )

    session = Lane.session(lane)
    assert :ok = RPC.await_ready(session.rpc)
    stop_supervised!(Raxol.SSH.Server)

    assert {:error, {:unauthenticated_principal, :ssh_server_down}} =
             Lane.prompt(session, %{text: @prompt})
  end

  describe "an unauthenticated principal is refused before omp starts" do
    test "SSH without :tenants_dir", %{dir: dir} do
      {server, connection} = ssh_connection(dir, :authorized_keys_dir, "alice")
      Process.flag(:trap_exit, true)

      assert {:error, {:unauthenticated_principal, :no_tenants_dir}} =
               Lane.start_link(
                 principal: {:ssh, server, connection, self()},
                 session_id: "s",
                 rpc: rpc_opts(dir)
               )
    end

    test "a Telegram Bot chat, LiveView, or no principal at all", %{dir: dir} do
      Process.flag(:trap_exit, true)

      for claim <- [{:telegram_bot, -100_123, self()}, {:liveview, self()}, nil] do
        assert {:error, {:unauthenticated_principal, :unsupported}} =
                 Lane.start_link(principal: claim, session_id: "s", rpc: rpc_opts(dir))
      end
    end
  end

  defp drain_events(session_id) do
    receive do
      {:session_event, ^session_id, event} -> [event | drain_events(session_id)]
    after
      0 -> []
    end
  end
end
