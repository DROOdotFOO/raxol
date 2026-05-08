if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Raxol.Symphony.Web.DashboardLive do
    @moduledoc """
    Phoenix LiveView dashboard for the Symphony orchestrator (Phase 10).

    Mounts the orchestrator subscription, refreshes the snapshot every
    second, and renders running + retrying tables in HTML. Mirrors the data
    shape served by `Raxol.Symphony.Web.API` and the terminal surface so all
    three converge on the same SPEC s13 snapshot.

    ## Usage

    Mount in a Phoenix router:

        live "/symphony", Raxol.Symphony.Web.DashboardLive

    Or pass an explicit orchestrator via session for test rigs:

        live "/symphony", Raxol.Symphony.Web.DashboardLive,
          session: %{"orchestrator" => "my_named_orchestrator"}

    ## Events

    - `phx-click="refresh"` -- triggers `Orchestrator.refresh/1`
    - `phx-click="stop_run"` with `phx-value-issue_id` -- terminates a run

    ## Test seam

    `apply_snapshot/2` and the event handlers operate on plain assigns maps,
    so unit tests can exercise behaviour without a running LiveView socket.
    See `test/raxol/symphony/web/dashboard_live_test.exs`.
    """

    use Phoenix.LiveView

    alias Raxol.Symphony.Orchestrator

    @poll_ms 1_000

    # -- LiveView callbacks ---------------------------------------------------

    @impl true
    def mount(_params, session, socket) do
      orchestrator = resolve_orchestrator(session, socket)

      if connected?(socket) do
        Process.send_after(self(), :tick, @poll_ms)
      end

      socket =
        socket
        |> assign(:orchestrator, orchestrator)
        |> assign(:snapshot, safe_snapshot(orchestrator))
        |> assign(:last_action, nil)

      {:ok, socket}
    end

    @impl true
    def handle_info(:tick, socket) do
      Process.send_after(self(), :tick, @poll_ms)
      {:noreply, refresh_assigns(socket)}
    end

    def handle_info({:symphony_event, _name, _snap}, socket) do
      {:noreply, refresh_assigns(socket)}
    end

    def handle_info(_msg, socket), do: {:noreply, socket}

    @impl true
    def handle_event("refresh", _params, socket) do
      _ = safe_call(fn -> Orchestrator.refresh(socket.assigns.orchestrator) end)

      {:noreply,
       socket
       |> assign(:last_action, "refresh requested")
       |> refresh_assigns()}
    end

    def handle_event("stop_run", %{"issue_id" => id}, socket) do
      result = safe_call(fn -> Orchestrator.stop_run(socket.assigns.orchestrator, id) end)
      msg = stop_run_message(id, result)

      {:noreply,
       socket
       |> assign(:last_action, msg)
       |> refresh_assigns()}
    end

    def handle_event(_evt, _params, socket), do: {:noreply, socket}

    # -- Render ---------------------------------------------------------------

    @impl true
    def render(assigns) do
      ~H"""
      <div id="symphony-dashboard" class="symphony-dashboard" style="font-family: monospace; padding: 1rem; max-width: 1200px;">
        <header style="display: flex; justify-content: space-between; align-items: baseline; border-bottom: 1px solid #444; padding-bottom: 0.5rem; margin-bottom: 1rem;">
          <h1 style="font-size: 1.25rem; margin: 0;">Symphony</h1>
          <div>
            <span>running {counts(@snapshot).running}</span>
            &nbsp;
            <span>retrying {counts(@snapshot).retrying}</span>
            &nbsp;
            <button phx-click="refresh" type="button" style="margin-left: 1rem;">refresh</button>
          </div>
        </header>

        <%= if @last_action do %>
          <div style="color: #6c6; margin-bottom: 1rem;">{@last_action}</div>
        <% end %>

        <section style="margin-bottom: 1.5rem;">
          <h2 style="font-size: 1rem; margin-bottom: 0.5rem;">Active runs</h2>
          <%= if Enum.empty?(@snapshot.running) do %>
            <p style="color: #888;">No active runs</p>
          <% else %>
            <table style="width: 100%; border-collapse: collapse;">
              <thead>
                <tr style="text-align: left; border-bottom: 1px solid #444;">
                  <th style="padding: 4px;">Issue</th>
                  <th style="padding: 4px;">State</th>
                  <th style="padding: 4px;">Turns</th>
                  <th style="padding: 4px;">Last event</th>
                  <th style="padding: 4px;">Runtime</th>
                  <th style="padding: 4px;">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for run <- @snapshot.running do %>
                  <tr style="border-bottom: 1px solid #222;">
                    <td style="padding: 4px;">{run.issue_identifier}</td>
                    <td style="padding: 4px;">{run.state}</td>
                    <td style="padding: 4px;">{run.turn_count}</td>
                    <td style="padding: 4px;">{format_event(run.last_event)}</td>
                    <td style="padding: 4px;">{format_ms(run.started_ms_ago)}</td>
                    <td style="padding: 4px;">
                      <button
                        phx-click="stop_run"
                        phx-value-issue_id={run.issue_id}
                        type="button"
                      >
                        stop
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          <% end %>
        </section>

        <section>
          <h2 style="font-size: 1rem; margin-bottom: 0.5rem;">Pending retries</h2>
          <%= if Enum.empty?(@snapshot.retrying) do %>
            <p style="color: #888;">No retries pending</p>
          <% else %>
            <table style="width: 100%; border-collapse: collapse;">
              <thead>
                <tr style="text-align: left; border-bottom: 1px solid #444;">
                  <th style="padding: 4px;">Issue</th>
                  <th style="padding: 4px;">Attempt</th>
                  <th style="padding: 4px;">Due in</th>
                  <th style="padding: 4px;">Last error</th>
                </tr>
              </thead>
              <tbody>
                <%= for retry <- @snapshot.retrying do %>
                  <tr style="border-bottom: 1px solid #222;">
                    <td style="padding: 4px;">{retry.issue_identifier}</td>
                    <td style="padding: 4px;">{retry.attempt}</td>
                    <td style="padding: 4px;">{format_ms(retry.due_in_ms)}</td>
                    <td style="padding: 4px;">{retry.error || ""}</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          <% end %>
        </section>
      </div>
      """
    end

    # -- Public helpers (testing seam) ---------------------------------------

    @doc """
    Refreshes the snapshot in the assigns map by re-querying the orchestrator.
    Used internally and exposed for unit tests.
    """
    @spec refresh_assigns(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
    def refresh_assigns(socket) do
      assign(socket, :snapshot, safe_snapshot(socket.assigns.orchestrator))
    end

    @doc "Resolve the orchestrator reference from session or fallback to default."
    @spec resolve_orchestrator(map(), Phoenix.LiveView.Socket.t()) :: GenServer.server()
    def resolve_orchestrator(session, _socket) do
      case Map.get(session, "orchestrator") do
        nil ->
          Application.get_env(:raxol_symphony, :liveview_orchestrator, Orchestrator)

        atom when is_atom(atom) ->
          atom

        name when is_binary(name) ->
          String.to_existing_atom(name)

        pid when is_pid(pid) ->
          pid
      end
    end

    @doc "Empty snapshot -- public so tests/templates can rely on the shape."
    @spec empty_snapshot() :: map()
    def empty_snapshot do
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
        rate_limits: nil
      }
    end

    # -- Internals ------------------------------------------------------------

    defp counts(%{counts: c}), do: c
    defp counts(_), do: %{running: 0, retrying: 0}

    defp safe_snapshot(orch) do
      case safe_call(fn -> Orchestrator.snapshot(orch) end) do
        {:ok, %{} = snap} -> snap
        _ -> empty_snapshot()
      end
    end

    defp safe_call(fun) do
      {:ok, fun.()}
    catch
      :exit, _ -> :error
      :error, _ -> :error
    end

    defp stop_run_message(id, {:ok, :ok}), do: "stopped #{id}"
    defp stop_run_message(id, {:ok, {:error, :not_running}}), do: "#{id} not running"
    defp stop_run_message(id, _), do: "stop #{id} failed"

    defp format_event(nil), do: "(no events yet)"
    defp format_event(atom) when is_atom(atom), do: Atom.to_string(atom)
    defp format_event(binary) when is_binary(binary), do: binary
    defp format_event(other), do: inspect(other)

    defp format_ms(ms) when is_integer(ms) and ms < 1_000, do: "#{ms}ms"
    defp format_ms(ms) when is_integer(ms) and ms < 60_000, do: "#{div(ms, 1000)}s"

    defp format_ms(ms) when is_integer(ms) do
      mins = div(ms, 60_000)
      secs = div(rem(ms, 60_000), 1000)
      "#{mins}m#{secs}s"
    end

    defp format_ms(_), do: "?"
  end
end
