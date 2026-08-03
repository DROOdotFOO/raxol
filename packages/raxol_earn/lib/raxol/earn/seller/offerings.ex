defmodule Raxol.Earn.Seller.Offerings do
  @moduledoc """
  Registers the seller's ACP offerings with `Raxol.Earn.Offering.Registry`.

  Offerings come from `config :raxol_earn, :offerings`. The default is fail-closed:
  only the USDC-only launch offering `UsdcPublicOffering` (`xochi_usdc_public`) is
  registered, because it is the only rail that settles without reverting today.
  The token-agnostic `StablePublicOffering` / `StableStealthOffering` and the
  deprecated `TransferOffering` accept tokens (USDT/USDG) whose settlement is not
  yet ready, so they are NOT advertised by default -- add them to `:offerings`
  explicitly once their rails land, so a buyer can never be routed into a
  settlement that reverts.

  `Raxol.Earn.Seller.Supervisor` calls `register_all/0` on start; registration is
  idempotent.
  """

  @default [
    Raxol.Earn.Xochi.UsdcPublicOffering
  ]

  @doc "The offering modules to register, from `:offerings` config or the default."
  @spec configured() :: [module()]
  def configured, do: Application.get_env(:raxol_earn, :offerings, @default)

  @doc """
  Register every configured offering. A no-op when the registry is not running.
  """
  @spec register_all() :: :ok
  def register_all do
    if Process.whereis(Raxol.Earn.Offering.Registry) do
      Enum.each(configured(), &register/1)
    end

    :ok
  end

  defp register(module) do
    case module.register() do
      {:ok, _spec} -> :ok
      {:error, {:already_registered, _name}} -> :ok
    end
  end
end
