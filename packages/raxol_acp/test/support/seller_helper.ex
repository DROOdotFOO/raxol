defmodule Raxol.ACP.TestSupport.SellerHelper do
  @moduledoc """
  Helpers for tests that exercise the seller stack.

  The Queue reads its `seller_address` default from `Application` on
  every dispatch (not cached at `init/1`), so changing it is just an
  `Application.put_env` -- no GenServer recycle needed. This matters
  for test isolation: cycling Queue + Backend + Runtime in every
  setup blows through `Seller.Supervisor`'s `max_restarts`.
  """

  alias Raxol.ACP.JobSession

  @doc """
  Reset the seller subsystem to a clean baseline for a test:

  - Terminate any leftover `Raxol.ACP.JobSession` children from prior
    tests (synthetic job ids would otherwise collide, and stale sessions
    count against the Queue's active-job cap).
  - Set the Queue's `seller_address` default. Picked up on next dispatch.

  Callers pass `seller_address:`. Unspecified values are cleared. The
  legacy `:wallet` and `:memo_opts` keys are accepted but ignored --
  memos no longer require a separate signing wallet.
  """
  @spec reset_seller(keyword()) :: :ok
  def reset_seller(opts \\ []) do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(JobSession.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(JobSession.Supervisor, pid)
    end

    Application.put_env(:raxol_acp, :seller_address, Keyword.get(opts, :seller_address))

    :ok
  end
end
