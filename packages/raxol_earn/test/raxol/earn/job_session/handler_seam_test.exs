defmodule Raxol.Earn.JobSession.HandlerSeamTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.JobSession.HandlerSeam

  defmodule FullHandler do
    @behaviour Raxol.Earn.Offering.Handler

    @impl true
    def handle_request(request, ctx), do: {:accept, %{echo: request, job: ctx.job_id}}

    @impl true
    def handle_deliver(request, _ctx), do: {:deliver, %{result: request}}

    @impl true
    def handle_evaluate(deliverable, _ctx), do: {:approve, %{ok: deliverable}}
  end

  defmodule NoEvaluateHandler do
    @behaviour Raxol.Earn.Offering.Handler

    @impl true
    def handle_request(_request, _ctx), do: {:reject, :nope}

    @impl true
    def handle_deliver(_request, _ctx), do: {:error, :cannot}
  end

  @ctx %{job_id: "job-1", buyer: "0xbuyer", seller: "0xseller", state: :open}

  describe "invoke/4" do
    test ":request dispatches to handle_request/2" do
      assert {:accept, %{echo: %{a: 1}, job: "job-1"}} =
               HandlerSeam.invoke(FullHandler, :request, %{a: 1}, @ctx)
    end

    test ":deliver dispatches to handle_deliver/2" do
      assert {:deliver, %{result: %{b: 2}}} =
               HandlerSeam.invoke(FullHandler, :deliver, %{b: 2}, @ctx)
    end

    test ":evaluate dispatches to handle_evaluate/2 when implemented" do
      assert {:approve, %{ok: %{c: 3}}} =
               HandlerSeam.invoke(FullHandler, :evaluate, %{c: 3}, @ctx)
    end

    test ":evaluate falls back to :evaluate_not_supported when the handler omits it" do
      assert {:error, :evaluate_not_supported} =
               HandlerSeam.invoke(NoEvaluateHandler, :evaluate, %{c: 3}, @ctx)
    end

    test "handler rejections and errors pass through unchanged" do
      assert {:reject, :nope} = HandlerSeam.invoke(NoEvaluateHandler, :request, %{}, @ctx)
      assert {:error, :cannot} = HandlerSeam.invoke(NoEvaluateHandler, :deliver, %{}, @ctx)
    end
  end
end
