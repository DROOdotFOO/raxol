defmodule Raxol.ACP.SignerSidecarTest do
  # async: false -- these exercise process-global env vars.
  use ExUnit.Case, async: false

  alias Raxol.ACP.SignerSidecar

  # Only base_url/1 is unit-testable in isolation; init/1 opens a Node Port and
  # blocks on GET /health, which needs the real sidecar (integration-level).

  setup do
    prior_url = System.get_env("RAXOL_ACP_SIDECAR_URL")
    prior_port = System.get_env("RAXOL_ACP_SIGNER_PORT")
    System.delete_env("RAXOL_ACP_SIDECAR_URL")
    System.delete_env("RAXOL_ACP_SIGNER_PORT")

    on_exit(fn ->
      restore("RAXOL_ACP_SIDECAR_URL", prior_url)
      restore("RAXOL_ACP_SIGNER_PORT", prior_port)
    end)

    :ok
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, val), do: System.put_env(key, val)

  describe "base_url/1" do
    test "defaults to loopback on the default port" do
      assert SignerSidecar.base_url([]) == "http://127.0.0.1:4048"
    end

    test "honors an explicit :port" do
      assert SignerSidecar.base_url(port: 5000) == "http://127.0.0.1:5000"
    end

    test "an explicit :base_url wins over the default" do
      assert SignerSidecar.base_url(base_url: "http://sidecar:9000") == "http://sidecar:9000"
    end

    test "falls back to RAXOL_ACP_SIDECAR_URL when no :base_url is given" do
      System.put_env("RAXOL_ACP_SIDECAR_URL", "http://env-host:1234")
      assert SignerSidecar.base_url([]) == "http://env-host:1234"
      # An explicit :base_url still overrides the env.
      assert SignerSidecar.base_url(base_url: "http://opt-host") == "http://opt-host"
    end

    test "the default url uses RAXOL_ACP_SIGNER_PORT" do
      System.put_env("RAXOL_ACP_SIGNER_PORT", "7000")
      assert SignerSidecar.base_url([]) == "http://127.0.0.1:7000"
      # An explicit :port still wins over the env.
      assert SignerSidecar.base_url(port: 8001) == "http://127.0.0.1:8001"
    end
  end
end
