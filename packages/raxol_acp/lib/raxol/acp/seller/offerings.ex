defmodule Raxol.ACP.Seller.Offerings do
  @moduledoc """
  Registers the seller's ACP offerings with `Raxol.ACP.Offering.Registry`.

  Offerings come from `config :raxol_acp, :offerings` (default: the split
  Xochi pair `StablePublicOffering` + `StableStealthOffering`, plus the
  deprecated `TransferOffering` for one migration cycle).
  `Raxol.ACP.Seller.Supervisor` calls `register_all/0` on start; registration is
  idempotent.
  """

  @default [
    Raxol.ACP.Xochi.StablePublicOffering,
    Raxol.ACP.Xochi.StableStealthOffering,
    Raxol.ACP.Xochi.TransferOffering
  ]

  @doc "The offering modules to register, from `:offerings` config or the default."
  @spec configured() :: [module()]
  def configured, do: Application.get_env(:raxol_acp, :offerings, @default)

  @doc """
  Register every configured offering. A no-op when the registry is not running.
  """
  @spec register_all() :: :ok
  def register_all do
    if Process.whereis(Raxol.ACP.Offering.Registry) do
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
