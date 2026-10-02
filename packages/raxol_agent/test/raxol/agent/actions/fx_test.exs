defmodule Raxol.Agent.Actions.FXTest do
  # async: false -- the configuration tests set :raxol_agent, :web3 and the
  # RAXOL_SLEUTH_API_KEY environment variable.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Actions.FX, as: FXAction
  alias Raxol.Web3.FX
  alias Raxol.Web3.FX.{Chainlink, Sleuth}

  # One EURC row in Sleuth's recorded shape. Chainlink has no RPC URLs here, so
  # every EUR asset is judged :no_rate without a feed read.
  @page ~s({"asOf":"2026-09-30T14:00:00Z","fxRatesUsd":{"EUR":1.134404},"total":1,
    "assets":[{"symbol":"EURC","aliases":["EURC"],"pegCurrency":"EUR","yieldBearing":false,
    "priceUsd":1.133365,"deviationBps":-9}]})

  defp fx do
    exchange = fn _vetted, request, _opts ->
      send(self(), {:request, request.path})
      {:ok, %{status: 200, headers: [], body: @page}}
    end

    http_opts = [
      exchange: exchange,
      rate_limit: [capacity: 1_000_000, refill_per_second: 1_000_000.0],
      breaker: [failure_threshold: 1_000_000],
      resolver: fn _host, family ->
        if family == :inet, do: {:ok, [{93, 184, 216, 34}]}, else: {:ok, []}
      end
    ]

    {:ok, sleuth} = Sleuth.new(api_key: "k", cache: false, http_opts: http_opts)
    FX.new(sleuth, Chainlink.new())
  end

  describe "the fx tool" do
    test "an unconfigured session says so rather than guessing at an upstream" do
      assert {:error, :fx_not_configured} = FXAction.call(%{operation: "stables"}, %{})
    end

    test "a jailed session with no network grant is refused before any read" do
      context = %{fx_source: fx(), jail: true, network: false}
      assert {:error, :network_disabled} = FXAction.call(%{operation: "stables"}, context)
      refute_received {:request, _}
    end

    test "it is sensitive" do
      assert FXAction.__action_meta__().sensitive == true
    end

    test "stables answers JSON-safe data with our verdict on each asset" do
      assert {:ok, %{operation: "stables", result: result}} =
               FXAction.call(%{operation: "stables", partner_only: true}, %{fx_source: fx()})

      assert_received {:request, "/api/mcp/fx/stables?partnerOnly=1"}

      assert [%{symbol: "EURC", price_usd: "1.133365", quality: %{status: :no_rate}}] =
               result.assets
    end

    test "an argument the source refuses comes back as a closed error code" do
      assert {:error, %{code: "invalid_argument", detail: "limit"}} =
               FXAction.call(%{operation: "stables", limit: 0}, %{fx_source: fx()})

      refute_received {:request, _}
    end
  end

  describe "Raxol.Agent.Web3 configuration" do
    setup do
      previous = Application.get_env(:raxol_agent, :web3)
      key = System.get_env("RAXOL_SLEUTH_API_KEY")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:raxol_agent, :web3, previous),
          else: Application.delete_env(:raxol_agent, :web3)

        if key,
          do: System.put_env("RAXOL_SLEUTH_API_KEY", key),
          else: System.delete_env("RAXOL_SLEUTH_API_KEY")

        Raxol.Agent.Web3.load!()
      end)

      Application.delete_env(:raxol_agent, :web3)
      System.delete_env("RAXOL_SLEUTH_API_KEY")
      Raxol.Agent.Web3.load!()
      :ok
    end

    test "unconfigured, nothing is added to a context or a toolset" do
      assert Raxol.Agent.Web3.put_context(%{cwd: "/x"}) == %{cwd: "/x"}
      assert Raxol.Agent.Web3.enabled_actions() == []
    end

    test "fx configured with the key in the environment adds the tool and the handle" do
      Application.put_env(:raxol_agent, :web3, fx: [rpc_urls: %{1 => "https://rpc.test"}])
      # Pasted with its newline, which would otherwise reach the header.
      System.put_env("RAXOL_SLEUTH_API_KEY", " from-env\r\n")
      Raxol.Agent.Web3.load!()

      assert Raxol.Agent.Web3.enabled_actions() == [FXAction]
      assert %{fx_source: %FX{} = source} = Raxol.Agent.Web3.put_context(%{})
      assert source.sleuth.api_key == "from-env"
      assert source.chainlink.rpc_urls == %{1 => "https://rpc.test"}
      refute Map.has_key?(Raxol.Agent.Web3.put_context(%{}), :web3_router)
    end

    test "fx configured without a key refuses the load and names the variable" do
      Application.put_env(:raxol_agent, :web3, fx: [])
      System.put_env("RAXOL_SLEUTH_API_KEY", "  \n")

      assert_raise ArgumentError, ~r/RAXOL_SLEUTH_API_KEY/, fn ->
        Raxol.Agent.Web3.load!()
      end
    end

    test "a key no header can carry refuses the load, names its source and not the key" do
      Application.put_env(:raxol_agent, :web3, fx: [])
      System.put_env("RAXOL_SLEUTH_API_KEY", "secret-half\r\nx-injected: 1")

      error = assert_raise ArgumentError, fn -> Raxol.Agent.Web3.load!() end
      assert error.message =~ "RAXOL_SLEUTH_API_KEY"
      refute error.message =~ "secret-half"

      Application.put_env(:raxol_agent, :web3, fx: [sleuth_api_key: "secret-half two"])

      error = assert_raise ArgumentError, fn -> Raxol.Agent.Web3.load!() end
      assert error.message =~ "sleuth_api_key"
      refute error.message =~ "secret-half"
    end

    test "a malformed :web3, fx: or router: setting refuses the load by name" do
      for {config, setting} <- [
            {[fx: true], "fx:"},
            {[fx: %{sleuth_api_key: "secret-half"}], "fx:"},
            {%{fx: []}, ":web3"},
            # It loaded and offered the `web3` tool over no router.
            {[router: false], "router:"}
          ] do
        Application.put_env(:raxol_agent, :web3, config)

        error = assert_raise ArgumentError, fn -> Raxol.Agent.Web3.load!() end
        assert error.message =~ setting
        refute error.message =~ "secret-half"
      end
    end

    test "a context build reads what was loaded, so it never raises per turn" do
      # Loaded unconfigured in setup; a later bad config or a key change is
      # not re-read by every session context, only by the next load.
      Application.put_env(:raxol_agent, :web3, fx: [])

      assert Raxol.Agent.Web3.put_context(%{}) == %{}
      assert Raxol.Agent.Web3.enabled_actions() == []

      Application.put_env(:raxol_agent, :web3, fx: [sleuth_api_key: "k"])
      Raxol.Agent.Web3.load!()
      System.put_env("RAXOL_SLEUTH_API_KEY", "changed")

      assert %{fx_source: %FX{sleuth: %{api_key: "k"}}} = Raxol.Agent.Web3.put_context(%{})
    end
  end
end
