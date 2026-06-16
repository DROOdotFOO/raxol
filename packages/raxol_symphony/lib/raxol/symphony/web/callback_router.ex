defmodule Raxol.Symphony.Web.CallbackRouter do
  @moduledoc """
  Module-level dispatcher for `sym:` namespace callbacks from the
  LiveView dashboard.

  Mirrors `Raxol.Symphony.Surfaces.Watch.Notifier.handle_action/2`
  and `Raxol.Symphony.Surfaces.Telegram.Notifier.handle_callback/2`
  so all three surfaces dispatch the same vocabulary through the
  same parser.

  ## Usage from LiveView

      def handle_event("callback", %{"data" => raw}, socket) do
        result = CallbackRouter.handle_callback(raw, orchestrator: socket.assigns.orchestrator)
        {:noreply, socket |> assign(:last_action, format_result(result))}
      end

  Buttons emit the same `sym:` strings as Telegram inline keyboards
  and Watch notification action ids, e.g.:

      <button phx-click="callback" phx-value-data={"sym:resume:" <> entry.issue_id <> ":approved"}>Approve</button>

  ## Return shape

      :noop
      | {:ok, :refresh | :listed | :stopped | {:resumed, decision} | {:run_detail, issue_id}}
      | {:error, :not_running | :not_paused | :orchestrator_unavailable}

  `:list` returns `:listed` (LiveView interprets as "trigger a
  refresh"). `:run_detail` returns the issue_id so the LV can
  push_patch / push_redirect to a per-run route.
  """

  alias Raxol.Symphony.Orchestrator

  @type result ::
          :noop
          | {:ok,
             :refresh
             | :listed
             | :stopped
             | {:resumed, binary()}
             | {:run_detail, binary()}}
          | {:error, atom()}

  @spec handle_callback(binary(), keyword()) :: result()
  def handle_callback(raw, opts \\ []) when is_binary(raw) do
    orch = Keyword.get(opts, :orchestrator, Raxol.Symphony.Orchestrator)

    raw
    |> Raxol.Symphony.OperatorCallback.parse()
    |> dispatch(orch)
  end

  defp dispatch(:refresh, orch), do: do_refresh(orch)
  defp dispatch(:list, orch), do: do_list(orch)
  defp dispatch(:dismiss, _orch), do: :noop
  defp dispatch({:stop, id}, orch), do: do_stop(orch, id)
  defp dispatch({:run_detail, id}, _orch), do: {:ok, {:run_detail, id}}
  defp dispatch({:approve, _id}, _orch), do: :noop
  defp dispatch({:resume, id, decision}, orch), do: do_resume(orch, id, decision)
  defp dispatch({:unknown, _raw}, _orch), do: :noop

  defp do_refresh(orch) do
    _ = safe_call(fn -> Orchestrator.refresh(orch) end)
    {:ok, :refresh}
  end

  defp do_list(orch) do
    _ = safe_call(fn -> Orchestrator.refresh(orch) end)
    {:ok, :listed}
  end

  defp do_stop(orch, id) do
    case safe_call(fn -> Orchestrator.stop_run(orch, id) end) do
      {:ok, :ok} -> {:ok, :stopped}
      {:ok, {:error, reason}} -> {:error, reason}
      _ -> {:error, :orchestrator_unavailable}
    end
  end

  defp do_resume(orch, id, decision) do
    case safe_call(fn -> Orchestrator.resume_run(orch, id, decision) end) do
      {:ok, :ok} -> {:ok, {:resumed, decision}}
      {:ok, {:error, reason}} -> {:error, reason}
      _ -> {:error, :orchestrator_unavailable}
    end
  end

  defp safe_call(fun) do
    {:ok, fun.()}
  catch
    :exit, _ -> :error
    :error, _ -> :error
  end
end
