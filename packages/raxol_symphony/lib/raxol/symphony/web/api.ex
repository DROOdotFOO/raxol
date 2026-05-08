if Code.ensure_loaded?(Plug.Router) do
  defmodule Raxol.Symphony.Web.API do
    @moduledoc """
    JSON API for the Symphony orchestrator (Phase 10).

    A `Plug.Router` exposing four endpoints. Mount it from any host Plug
    pipeline:

        forward "/symphony", to: Raxol.Symphony.Web.API

    Or run it as a standalone Bandit/Cowboy endpoint.

    ## Endpoints

    | Method | Path                          | Returns                              |
    |--------|-------------------------------|--------------------------------------|
    | GET    | `/api/v1/state`               | full snapshot                        |
    | GET    | `/api/v1/runs/:issue_id`      | single run, retrying entry, or 404   |
    | POST   | `/api/v1/refresh`             | `{status: "refreshed"}`              |
    | POST   | `/api/v1/runs/:issue_id/stop` | `{status: "stopped" \| "not_running"}` |

    Unknown routes return 404 with `{"error": "not_found"}`.

    ## Orchestrator resolution

    The orchestrator reference is resolved per-request via, in order:

    1. `conn.private[:symphony_orchestrator]` if set by upstream plugs
    2. `Application.get_env(:raxol_symphony, :api_orchestrator, ...)`
    3. `Raxol.Symphony.Orchestrator` (the registered name)

    This makes the router safe to mount without static configuration while
    still letting tests inject a per-request override.
    """

    use Plug.Router

    alias Raxol.Symphony.Orchestrator

    plug(Plug.Parsers,
      parsers: [:json],
      json_decoder: Jason,
      pass: ["application/json"]
    )

    plug(:match)
    plug(:dispatch)

    get "/api/v1/state" do
      orch = orchestrator(conn)
      send_json(conn, 200, safe_snapshot(orch))
    end

    get "/api/v1/runs/:issue_id" do
      orch = orchestrator(conn)
      snap = safe_snapshot(orch)

      case lookup_run(snap, issue_id) do
        nil ->
          send_json(conn, 404, %{status: "not_found", issue_id: issue_id})

        {kind, run} ->
          send_json(conn, 200, %{status: Atom.to_string(kind), run: run})
      end
    end

    post "/api/v1/refresh" do
      orch = orchestrator(conn)
      _ = safe_call(fn -> Orchestrator.refresh(orch) end)
      send_json(conn, 200, %{status: "refreshed"})
    end

    post "/api/v1/runs/:issue_id/stop" do
      orch = orchestrator(conn)

      case safe_call(fn -> Orchestrator.stop_run(orch, issue_id) end) do
        {:ok, :ok} ->
          send_json(conn, 200, %{status: "stopped", issue_id: issue_id})

        {:ok, {:error, :not_running}} ->
          send_json(conn, 404, %{status: "not_running", issue_id: issue_id})

        _ ->
          send_json(conn, 503, %{status: "error", message: "orchestrator unavailable"})
      end
    end

    match _ do
      send_json(conn, 404, %{error: "not_found", path: conn.request_path})
    end

    # -- Helpers --------------------------------------------------------------

    defp orchestrator(%Plug.Conn{} = conn) do
      conn.private[:symphony_orchestrator] ||
        Application.get_env(
          :raxol_symphony,
          :api_orchestrator,
          Raxol.Symphony.Orchestrator
        )
    end

    defp send_json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end

    defp lookup_run(snapshot, issue_id) do
      cond do
        run = Enum.find(snapshot.running, &(&1.issue_id == issue_id)) ->
          {:running, run}

        run = Enum.find(snapshot.retrying, &(&1.issue_id == issue_id)) ->
          {:retrying, run}

        true ->
          nil
      end
    end

    defp safe_snapshot(orch) do
      case safe_call(fn -> Orchestrator.snapshot(orch) end) do
        {:ok, %{} = snap} ->
          snap

        _ ->
          %{
            generated_at: nil,
            counts: %{running: 0, retrying: 0},
            running: [],
            retrying: [],
            codex_totals: %{
              input_tokens: 0,
              output_tokens: 0,
              total_tokens: 0,
              seconds_running: 0.0
            },
            rate_limits: nil,
            orchestrator_unavailable: true
          }
      end
    end

    defp safe_call(fun) do
      {:ok, fun.()}
    catch
      :exit, _ -> :error
      :error, _ -> :error
    end
  end
end
