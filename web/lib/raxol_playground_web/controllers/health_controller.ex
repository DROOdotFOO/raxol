defmodule RaxolPlaygroundWeb.HealthController do
  use RaxolPlaygroundWeb, :controller

  @memory_warn_mb String.to_integer(System.get_env("HEALTH_MEMORY_WARN_MB") || "500")
  @memory_crit_mb String.to_integer(System.get_env("HEALTH_MEMORY_CRIT_MB") || "900")

  def check(conn, _params) do
    checks = %{
      pubsub: check_pubsub(),
      memory: check_memory(),
      ssh: check_ssh()
    }

    # Only genuinely fatal states take the machine out of rotation (503).
    # PubSub down breaks LiveView, and critical memory is unsafe. SSH is an
    # optional playground extra and a memory "warning" is tolerable, so neither
    # degrades the service to 503; the JSON still reports the real state.
    critical? = checks.pubsub in ["down", "error"] or checks.memory == "critical"

    all_ok = Enum.all?(checks, fn {_k, v} -> v in ["ok", "not_configured"] end)

    status = %{
      status: if(all_ok, do: "healthy", else: "degraded"),
      version: Application.spec(:raxol_playground, :vsn) |> to_string(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      checks: checks
    }

    http_status = if critical?, do: 503, else: 200

    conn
    |> put_status(http_status)
    |> put_resp_content_type("application/json")
    |> json(status)
  end

  defp check_pubsub do
    case Process.whereis(Raxol.PubSub) do
      nil -> "down"
      pid when is_pid(pid) -> if Process.alive?(pid), do: "ok", else: "down"
    end
  rescue
    _ -> "error"
  end

  defp check_ssh do
    if System.get_env("RAXOL_SSH_PLAYGROUND") == "true" do
      port = String.to_integer(System.get_env("RAXOL_SSH_PORT") || "2222")

      # Probe the protocol, not the socket: a daemon that accepts and hangs
      # up would pass a bare connect during exactly the outage this check
      # exists to catch. "ok" requires an SSH-2.0 banner.
      case Raxol.SSH.Server.banner_probe(~c"127.0.0.1", port, 2_000) do
        :ok -> "ok"
        {:error, _} -> "down"
      end
    else
      "not_configured"
    end
  rescue
    _ -> "error"
  end

  defp check_memory do
    total_mb = :erlang.memory(:total) / 1_048_576

    cond do
      total_mb > @memory_crit_mb -> "critical"
      total_mb > @memory_warn_mb -> "warning"
      true -> "ok"
    end
  end
end
