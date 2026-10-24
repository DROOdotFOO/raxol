defmodule Raxol.Agent.Backend.OmpGatewayLiveTest do
  # Twins of the F1 no-model paths on the real `omp` binary. No model call:
  # every request here is answered by the gateway itself.
  #
  #   mix test --only omp
  use ExUnit.Case, async: true

  alias Raxol.Agent.Backend.OmpGateway
  alias Raxol.Agent.Backend.OmpGateway.Codec
  alias Raxol.Agent.Backend.OmpGateway.Server

  @moduletag :omp
  @moduletag :unix_only

  setup do
    {:ok, omp} = OmpGateway.resolve_binary(nil)
    %{omp: omp, server: start_supervised!({Server, name: nil, path: omp})}
  end

  # The gateway's own stdin, fed from a shell so it sees EOF.
  defp run_with_stdin(omp, input) do
    System.cmd("/bin/sh", [
      "-c",
      ~s(printf '%s' "$1" | "$0" auth-gateway stdio),
      omp,
      input
    ])
  end

  test "the gateway prints a ready line, answers bad JSON, and exits 0 on EOF", %{omp: omp} do
    {out, status} = run_with_stdin(omp, "not json\n")
    [ready, reply] = String.split(out, "\n", trim: true)

    assert {:ok, _version, _warnings} = Codec.decode_ready(ready)
    assert {:ok, %{id: nil} = response} = Codec.decode_response(reply)
    assert {:error, {:http_error, 400, "invalid_request_error"}} = Codec.result(response)
    assert status == 0
  end

  test "GET /v1/models lists model ids", %{server: server} do
    assert {:ok, ids} = OmpGateway.list_models(server: server)
    assert Enum.all?(ids, &is_binary/1)
  end

  test "a relative path is a 400", %{server: server} do
    assert {:error, {:http_error, 400, "invalid_request_error"}} =
             OmpGateway.request(:get, "v1/models", nil, server: server)
  end

  test "an unknown model is a 404", %{server: server} do
    assert {:error, {:http_error, 404, "invalid_request_error"}} =
             OmpGateway.complete([%{role: :user, content: "hi"}],
               model: "nope/does-not-exist",
               max_tokens: 16,
               server: server
             )
  end

  test "an unknown route is a 404", %{server: server} do
    assert {:error, {:http_error, 404, nil}} =
             OmpGateway.request(:get, "/nope", nil, server: server)
  end

  test "a stopped gateway misses the deadline; killed, it fails the pending caller",
       %{server: server} do
    assert {:ok, _ids} = OmpGateway.list_models(server: server)
    os_pid = gateway_os_pid(server)

    {_, 0} = System.cmd("kill", ["-STOP", os_pid])
    {stat, 0} = System.cmd("ps", ["-o", "stat=", "-p", os_pid])
    assert String.starts_with?(String.trim(stat), "T")

    assert {:error, {:gateway_timeout, 300}} =
             OmpGateway.request(:get, "/v1/models", nil, server: server, timeout: 300)

    # Sent from this process, so the barrier below is ordered after it: the
    # request is pending in the server before the kill.
    pending = :gen_server.send_request(server, {:request, :get, "/v1/models", nil, 60_000})
    _ = :sys.get_state(server)
    {_, 0} = System.cmd("kill", ["-KILL", os_pid])

    assert {:reply, {:error, {:gateway_exit, 137}}} =
             :gen_server.receive_response(pending, 10_000)

    assert {:ok, _ids} = OmpGateway.list_models(server: server)
  end

  defp gateway_os_pid(server) do
    Enum.find_value(Port.list(), fn port ->
      with {:connected, ^server} <- Port.info(port, :connected),
           {:os_pid, os_pid} <- Port.info(port, :os_pid) do
        Integer.to_string(os_pid)
      else
        _ -> nil
      end
    end)
  end
end
