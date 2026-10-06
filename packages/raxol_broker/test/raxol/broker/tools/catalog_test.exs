defmodule Raxol.Broker.Tools.CatalogTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Raxol.Broker.Tools.Catalog

  @read %{"annotations" => %{"readOnlyHint" => true}}

  describe "the capture" do
    defp named(class),
      do: for({name, ^class} <- Catalog.static(), do: name) |> Enum.sort()

    test "only the allowlisted order and alert tools are :write" do
      assert named(:write) ==
               ~w(cancel_crypto_order cancel_equity_order cancel_option_order create_alert
                  place_crypto_order place_equity_order place_option_order update_alert)
    end

    test "the review tools are :review, and every place tool resolves to one" do
      assert named(:review) == ~w(preview_crypto_order review_equity_order review_option_order)

      assert Catalog.review_for("place_equity_order") == {:ok, "review_equity_order"}
      assert Catalog.review_for("place_option_order") == {:ok, "review_option_order"}
      assert Catalog.review_for("place_crypto_order") == {:ok, "preview_crypto_order"}
    end

    test "no :read tool is write-shaped, and the other mutators are :unknown" do
      assert Enum.all?(
               named(:read),
               &String.match?(&1, ~r/\A(get_|preview_scan\z|run_scan\z|search\z)/)
             )

      for name <-
            ~w(exercise_option cancel_option_exercise delete_alert create_watchlist add_to_watchlist),
          do: assert(Catalog.classify(name) == :unknown, name)
    end

    test "a tool absent from the capture is :unknown, whatever its shape" do
      assert Catalog.classify("place_foo_order") == :unknown
      assert Catalog.classify("get_foo") == :unknown
      assert Catalog.review_for("place_foo_order") == {:error, :no_review}
      assert Catalog.review_for("cancel_equity_order") == {:error, :no_review}
    end
  end

  describe "shape rules" do
    test "review and preview order tools are :review" do
      for name <-
            ~w(review_equity_order review_option_order preview_crypto_order review_advanced_order),
          do: assert(Catalog.classify(name, @read) == :review, name)

      assert Catalog.classify("preview_scan", @read) == :read
    end

    test "the write allowlist, and nothing else that mutates" do
      for name <-
            ~w(place_equity_order place_advanced_order cancel_option_order replace_equity_order
                     create_price_alert update_alert),
          do: assert(Catalog.classify(name, %{}) == :write, name)

      for name <- ~w(exercise_option create_watchlist add_to_watchlist delete_alert set_margin),
          do: assert(Catalog.classify(name, @read) == :unknown, name)
    end

    test "a read tool needs the read-only hint" do
      assert Catalog.classify("get_portfolio", @read) == :read
      assert Catalog.classify("get_portfolio", %{}) == :unknown

      assert Catalog.classify("get_portfolio", %{"annotations" => %{"readOnlyHint" => false}}) ==
               :unknown
    end
  end

  describe "reconcile/1" do
    test "an unchanged live list keeps the captured classes" do
      assert Catalog.reconcile(Catalog.recorded_tools()) == Catalog.static()
    end

    test "a changed write tool is refused and logged at :error; a changed read tool is kept" do
      live =
        Enum.map(Catalog.recorded_tools(), fn
          %{"name" => name} = tool when name in ["place_equity_order", "get_equity_quotes"] ->
            put_in(tool, ["inputSchema", "properties", "extra"], %{"type" => "string"})

          tool ->
            tool
        end)

      log = capture_log(fn -> send(self(), {:session, Catalog.reconcile(live)}) end)
      assert_received {:session, session}

      assert session["place_equity_order"] == :unknown
      assert session["get_equity_quotes"] == :read
      assert log =~ ~r/\[error\].*write tool place_equity_order changed/
      assert log =~ ~r/\[warning\].*read tool get_equity_quotes changed/
    end

    test "a tool the capture lacks is :unknown; write-shaped ones log at :error" do
      live =
        Catalog.recorded_tools() ++
          [Map.put(@read, "name", "place_foo_order"), Map.put(@read, "name", "get_foo")]

      log = capture_log(fn -> send(self(), {:session, Catalog.reconcile(live)}) end)
      assert_received {:session, session}

      assert Catalog.class(session, "place_foo_order") == :unknown
      assert Catalog.class(session, "get_foo") == :unknown
      assert log =~ ~r/\[error\].*place_foo_order is not in the capture/
      assert log =~ ~r/\[warning\].*get_foo is not in the capture/
    end

    test "a captured tool the server stopped serving is absent and logged" do
      live = Enum.reject(Catalog.recorded_tools(), &(&1["name"] == "cancel_equity_order"))

      log = capture_log(fn -> send(self(), {:session, Catalog.reconcile(live)}) end)
      assert_received {:session, session}

      assert Catalog.permit(session, "cancel_equity_order", :write) ==
               {:error, {:tool_refused, "cancel_equity_order", :unknown}}

      assert log =~ "cancel_equity_order is not served"
    end
  end
end
