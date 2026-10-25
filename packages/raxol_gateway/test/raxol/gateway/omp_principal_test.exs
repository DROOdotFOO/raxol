defmodule Raxol.Gateway.OMPPrincipalTest do
  # Who may front an OMP session over the gateway (ADR-0042, decision 7):
  # only a user granted on the route's own platform. Telegram reaches OMP
  # this way, with the route `Raxol.Telegram.GatewayAdapter` builds from the
  # sender's `from.id`.
  use ExUnit.Case, async: true

  alias Raxol.Agent.OMP.Lane
  alias Raxol.Agent.OMP.Principal
  alias Raxol.Gateway.Pairing
  alias Raxol.Gateway.Route

  defp start_pairing(opts) do
    name = :"omp_pairing_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {Pairing, :start_link, [[{:name, name} | opts]]}})
    name
  end

  defp route(platform, user_id),
    do: Route.new(%{platform: platform, chat_type: :group, chat_id: -100_123, user_id: user_id})

  test "a user granted on the route's platform is a principal" do
    pairing = start_pairing(platform_users: [telegram: [42]])

    assert {:ok, %Principal{surface: {:gateway, :telegram}, id: "42", pid: pid}} =
             Principal.authenticate({:gateway, pairing, route(:telegram, 42), self()})

    assert pid == self()
  end

  test "an OMP lane refuses every route not granted on its own platform" do
    pairing =
      start_pairing(
        platform_users: [discord: [42]],
        allowed_users: [7],
        allow_platforms: [:telegram]
      )

    :ok = Pairing.approve(pairing, "9")
    Process.flag(:trap_exit, true)

    refusals = [
      # Granted on Discord only; on global or DM-pairing grants; on a
      # platform that admits everyone; on nothing at all.
      {route(:telegram, 42), :not_granted},
      {route(:telegram, 7), :not_granted},
      {route(:telegram, 9), :not_granted},
      {route(:telegram, 1234), :not_granted},
      # A channel post carries no sender.
      {route(:telegram, nil), :no_user_id}
    ]

    for {route, reason} <- refusals do
      # `authorize/2` admits every one of them: Telegram admits everyone.
      assert Pairing.authorize(pairing, route) == :allow

      assert {:error, {:unauthenticated_principal, ^reason}} =
               Lane.start_link(
                 principal: {:gateway, pairing, route, self()},
                 session_id: "s",
                 rpc: []
               )
    end
  end

  test "a Pairing server that is not running grants nothing" do
    pairing = start_pairing(platform_users: [telegram: [42]])
    stop_supervised!(pairing)

    assert {:error, {:unauthenticated_principal, :pairing_unavailable}} =
             Principal.authenticate({:gateway, pairing, route(:telegram, 42), self()})
  end
end
