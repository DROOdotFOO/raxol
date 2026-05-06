defmodule Raxol.ACP.Offering.RegistryTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.Offering.Registry
  alias Raxol.ACP.Offering.Registry.Spec
  alias Raxol.ACP.TestSupport.{EchoOffering, MinimalOffering}

  setup do
    Registry.clear()
    :ok
  end

  describe "register/1" do
    test "accepts a Spec struct and stores it" do
      spec = %Spec{name: "x", handler: EchoOffering, price_usdc: Decimal.new("0.5")}

      assert {:ok, ^spec} = Registry.register(spec)
      assert {:ok, ^spec} = Registry.lookup("x")
    end

    test "accepts a plain map and coerces to Spec" do
      map = %{name: "y", handler: EchoOffering, sla_minutes: 5, cluster: "info"}

      assert {:ok, %Spec{name: "y", sla_minutes: 5, cluster: "info"}} =
               Registry.register(map)
    end

    test "rejects duplicate names" do
      :ok = register_spec("dup")

      spec = %Spec{name: "dup", handler: EchoOffering}
      assert {:error, {:already_registered, "dup"}} = Registry.register(spec)
    end
  end

  describe "lookup/1" do
    test "returns :error for unknown names" do
      assert :error = Registry.lookup("not-here")
    end

    test "returns the registered spec" do
      :ok = register_spec("hello")
      assert {:ok, %Spec{name: "hello"}} = Registry.lookup("hello")
    end
  end

  describe "list_all/0 + count/0" do
    test "list and count are zero on a clean registry" do
      assert Registry.list_all() == []
      assert Registry.count() == 0
    end

    test "reflect every registration" do
      :ok = register_spec("a")
      :ok = register_spec("b")
      :ok = register_spec("c")

      assert Registry.count() == 3
      names = Registry.list_all() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["a", "b", "c"]
    end
  end

  describe "deregister/1" do
    test "removes the entry" do
      :ok = register_spec("temp")
      assert {:ok, _} = Registry.lookup("temp")

      assert :ok = Registry.deregister("temp")
      assert :error = Registry.lookup("temp")
    end

    test "is idempotent" do
      assert :ok = Registry.deregister("never-existed")
      assert :ok = Registry.deregister("never-existed")
    end
  end

  describe "concurrent reads" do
    test "lookup is a direct ETS read, safe from many processes at once" do
      :ok = register_spec("shared")

      results =
        1..50
        |> Task.async_stream(fn _ -> Registry.lookup("shared") end,
          max_concurrency: 25,
          ordered: false
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results, &match?({:ok, %Spec{name: "shared"}}, &1))
    end
  end

  describe "DSL integration: EchoOffering.register/0" do
    test "round-trips full metadata through the registry" do
      assert {:ok, %Spec{} = spec} = EchoOffering.register()

      assert spec.name == "test.echo"
      assert spec.handler == EchoOffering
      assert Decimal.equal?(spec.price_usdc, Decimal.new("0.01"))
      assert spec.sla_minutes == 1
      assert spec.cluster == "information"
      assert spec.requirements_schema == EchoOffering.requirements_schema()
      assert spec.deliverables_schema == EchoOffering.deliverables_schema()

      assert {:ok, ^spec} = Registry.lookup("test.echo")
    end

    test "MinimalOffering registers with nil metadata fields" do
      assert {:ok, %Spec{} = spec} = MinimalOffering.register()

      assert spec.name == "test.minimal"
      assert spec.handler == MinimalOffering
      assert spec.price_usdc == nil
      assert spec.sla_minutes == nil
      assert spec.cluster == nil
      assert spec.requirements_schema == nil
      assert spec.deliverables_schema == nil
    end
  end

  defp register_spec(name) do
    {:ok, _} =
      Registry.register(%Spec{name: name, handler: EchoOffering})

    :ok
  end
end
