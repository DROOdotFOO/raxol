defmodule Raxol.ACP.Offering do
  @moduledoc """
  DSL for declaring an ACP offering.

  ## Example

      defmodule Xochi.ACP.PrivateSwapOffering do
        use Raxol.ACP.Offering,
          name: "xochi.private_swap",
          price_usdc: "0.50",
          sla_minutes: 5,
          cluster: "on_chain"

        @impl true
        def requirements_schema do
          %{
            type: "object",
            required: ["sell_token", "buy_token", "amount", "src_chain", "dst_chain"],
            properties: %{...}
          }
        end

        @impl true
        def deliverables_schema do
          %{type: "object", required: ["tx_hash", "stealth_addr"]}
        end

        @impl true
        def handle_request(req, _ctx), do: {:accept, req}

        @impl true
        def handle_deliver(req, _ctx) do
          # do the work, return the deliverable
          {:deliver, %{tx_hash: "0x...", stealth_addr: "0x..."}}
        end
      end

  ## What the macro injects

  - `@behaviour Raxol.ACP.Offering.Handler`
  - `@behaviour Raxol.ACP.Offering` (for the schema callbacks)
  - Module attribute accessors:
    - `offering_name/0`
    - `price_usdc/0` (returns `Decimal`)
    - `sla_minutes/0`
    - `cluster/0`
  - `register/0` -- builds an `Offering.Registry.Spec` from the
    declared metadata + the `requirements_schema/0` and
    `deliverables_schema/0` callbacks, and submits it to the registry.
  - `spec/0` -- returns the `Spec` struct without registering.

  ## Required `use` options

  - `:name` -- offering name (binary). Becomes the registry key.

  ## Optional `use` options

  - `:price_usdc` -- price in USDC; binary, integer, or `Decimal`. Coerced
    to `Decimal`.
  - `:sla_minutes` -- service-level agreement (positive integer).
  - `:cluster` -- ACP cluster tag (e.g. `"on_chain"`, `"information"`).
  """

  @doc "Return the JSON Schema for the offering's request requirements."
  @callback requirements_schema() :: map()

  @doc "Return the JSON Schema for the offering's deliverable shape."
  @callback deliverables_schema() :: map()

  @optional_callbacks requirements_schema: 0, deliverables_schema: 0

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    price = Keyword.get(opts, :price_usdc)
    sla = Keyword.get(opts, :sla_minutes)
    cluster = Keyword.get(opts, :cluster)

    quote do
      @behaviour Raxol.ACP.Offering.Handler
      @behaviour Raxol.ACP.Offering

      @offering_name unquote(name)
      @offering_price unquote(__MODULE__).__coerce_price__(unquote(price))
      @offering_sla_minutes unquote(sla)
      @offering_cluster unquote(cluster)

      @doc "Return the offering's name (registry key)."
      @spec offering_name() :: String.t()
      def offering_name, do: @offering_name

      @doc "Return the offering's USDC price as a Decimal, or `nil`."
      @spec price_usdc() :: Decimal.t() | nil
      def price_usdc, do: @offering_price

      @doc "Return the offering's SLA in minutes, or `nil`."
      @spec sla_minutes() :: pos_integer() | nil
      def sla_minutes, do: @offering_sla_minutes

      @doc "Return the offering's ACP cluster tag, or `nil`."
      @spec cluster() :: String.t() | nil
      def cluster, do: @offering_cluster

      @doc """
      Build an `Offering.Registry.Spec` for this offering without
      submitting it to the registry.
      """
      @spec spec() :: Raxol.ACP.Offering.Registry.Spec.t()
      def spec do
        %Raxol.ACP.Offering.Registry.Spec{
          name: @offering_name,
          handler: __MODULE__,
          price_usdc: @offering_price,
          sla_minutes: @offering_sla_minutes,
          cluster: @offering_cluster,
          requirements_schema: maybe_call(:requirements_schema),
          deliverables_schema: maybe_call(:deliverables_schema)
        }
      end

      @doc """
      Register this offering with `Raxol.ACP.Offering.Registry`.
      Returns the same `{:ok, spec} | {:error, term}` as
      `Registry.register/1`.
      """
      @spec register() :: {:ok, Raxol.ACP.Offering.Registry.Spec.t()} | {:error, term()}
      def register, do: Raxol.ACP.Offering.Registry.register(spec())

      # Resolve an optional callback (`requirements_schema/0`,
      # `deliverables_schema/0`) tolerantly. `function_exported?/3` is
      # unreliable during the transient state of a module's first load,
      # so we just call and rescue.
      defp maybe_call(fun) do
        apply(__MODULE__, fun, [])
      rescue
        UndefinedFunctionError -> nil
      end
    end
  end

  @doc false
  def __coerce_price__(nil), do: nil
  def __coerce_price__(%Decimal{} = d), do: d
  def __coerce_price__(n) when is_integer(n), do: Decimal.new(n)
  def __coerce_price__(s) when is_binary(s), do: Decimal.new(s)
end
