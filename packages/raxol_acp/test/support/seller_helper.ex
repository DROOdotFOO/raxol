defmodule Raxol.ACP.TestSupport.SellerHelper do
  @moduledoc """
  Helpers for tests that exercise the seller stack.

  The Queue reads defaults from `Application` on every dispatch (not
  cached at `init/1`), so changing wallet/memo_opts/seller_address is
  just an `Application.put_env` -- no GenServer recycle needed. This
  matters for test isolation: cycling Queue + Backend + Runtime in
  every setup blows through `Seller.Supervisor`'s `max_restarts`.
  """

  alias Raxol.ACP.Job

  @doc """
  Reset the seller subsystem to a clean baseline for a test:

  - Terminate any leftover `Job.Server` children from prior tests
    (deterministic synthetic job ids would otherwise collide).
  - Set Queue defaults to `wallet/memo_opts/seller_address` (each
    `nil`-able). Picked up on the next dispatch.

  Callers pass any subset of `wallet:`, `memo_opts:`, `seller_address:`.
  Unspecified values are cleared.
  """
  @spec reset_seller(keyword()) :: :ok
  def reset_seller(opts \\ []) do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Job.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(Job.Supervisor, pid)
    end

    Application.put_env(:raxol_acp, :seller_wallet, Keyword.get(opts, :wallet))
    Application.put_env(:raxol_acp, :seller_memo_opts, Keyword.get(opts, :memo_opts))
    Application.put_env(:raxol_acp, :seller_address, Keyword.get(opts, :seller_address))

    :ok
  end
end
