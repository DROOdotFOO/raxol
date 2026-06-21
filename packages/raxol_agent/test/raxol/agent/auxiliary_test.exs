defmodule Raxol.Agent.AuxiliaryTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Auxiliary
  alias Raxol.Agent.ExecutorConfig

  @aux %{
    curation: %{harness: :anthropic, model: "claude-haiku-4-5", fallback: [:default]},
    user_model: %{harness: :anthropic, model: "claude-haiku-4-5"},
    title: %{backend: :openai, model: "gpt-5-mini"},
    default_aux: %{harness: :anthropic, model: "claude-haiku-4-5"}
  }

  defp primary, do: ExecutorConfig.new(harness: :openai, model: "gpt-5")

  describe "resolve/2" do
    test "returns the slot's ExecutorConfig for a configured task kind" do
      config = Auxiliary.resolve(:curation, auxiliary: @aux, default: primary())

      assert %ExecutorConfig{harness: :anthropic, model: "claude-haiku-4-5"} = config
    end

    test "accepts :backend as an alias for :harness" do
      config = Auxiliary.resolve(:title, auxiliary: @aux, default: primary())

      assert %ExecutorConfig{harness: :openai, model: "gpt-5-mini"} = config
    end

    test "an unknown task kind falls back to default_aux" do
      config = Auxiliary.resolve(:compression, auxiliary: @aux, default: primary())

      assert %ExecutorConfig{harness: :anthropic, model: "claude-haiku-4-5"} = config
    end

    test "an unknown task kind with no default_aux falls back to the primary executor" do
      aux = Map.delete(@aux, :default_aux)
      config = Auxiliary.resolve(:compression, auxiliary: aux, default: primary())

      assert config == primary()
    end

    test "with no auxiliary config at all, resolves to the primary executor" do
      assert Auxiliary.resolve(:curation, default: primary()) == primary()
    end

    test "with neither auxiliary nor default, resolves to a mock config" do
      assert %ExecutorConfig{harness: :mock} = Auxiliary.resolve(:curation, [])
    end

    test "a malformed slot (no harness/backend) raises a clear error" do
      aux = %{curation: %{model: "x"}}

      assert_raise ArgumentError, ~r/requires :harness/, fn ->
        Auxiliary.resolve(:curation, auxiliary: aux, default: primary())
      end
    end
  end

  describe "resolve_chain/2" do
    test "appends the slot's :default fallback and terminates at the primary executor" do
      chain = Auxiliary.resolve_chain(:curation, auxiliary: @aux, default: primary())

      assert [%ExecutorConfig{harness: :anthropic}, %ExecutorConfig{harness: :openai}] = chain
      assert List.last(chain) == primary()
    end

    test "resolves a named slot in the fallback chain" do
      aux = put_in(@aux, [:curation, :fallback], [:title, :default])
      chain = Auxiliary.resolve_chain(:curation, auxiliary: aux, default: primary())

      assert [
               %ExecutorConfig{model: "claude-haiku-4-5"},
               %ExecutorConfig{model: "gpt-5-mini"},
               %ExecutorConfig{model: "gpt-5"}
             ] = chain
    end

    test "a slot with no fallback still terminates at the primary executor" do
      chain = Auxiliary.resolve_chain(:user_model, auxiliary: @aux, default: primary())

      assert [%ExecutorConfig{model: "claude-haiku-4-5"}, %ExecutorConfig{model: "gpt-5"}] = chain
    end

    test "deduplicates when the fallback equals the primary" do
      # No auxiliary: primary and the appended default are the same config.
      chain = Auxiliary.resolve_chain(:curation, default: primary())

      assert chain == [primary()]
    end
  end

  describe "select/2" do
    test "returns the first available backend in the chain" do
      assert {:ok, Raxol.Agent.Backend.HTTP, opts} =
               Auxiliary.select(:curation, auxiliary: @aux, default: primary())

      assert opts[:provider] == :anthropic
      assert opts[:model] == "claude-haiku-4-5"
    end

    test "falls through to the fallback when the primary is unavailable" do
      # Mark the :anthropic primary unavailable; the walk degrades to :default.
      available? = fn %ExecutorConfig{harness: harness} -> harness != :anthropic end

      assert {:ok, Raxol.Agent.Backend.HTTP, opts} =
               Auxiliary.select(:curation,
                 auxiliary: @aux,
                 default: primary(),
                 available?: available?
               )

      assert opts[:provider] == :openai
    end

    test "errors when nothing in the chain is available" do
      available? = fn _config -> false end

      assert {:error, :no_available_backend} =
               Auxiliary.select(:curation,
                 auxiliary: @aux,
                 default: primary(),
                 available?: available?
               )
    end
  end
end
