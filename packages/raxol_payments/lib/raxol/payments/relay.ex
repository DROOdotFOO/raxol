defmodule Raxol.Payments.Relay do
  @moduledoc """
  High-level facade over `Raxol.Payments.Relay.Client` for the Tron rail.

  Relay is deposit-address based: the quote returns a Riddler-managed deposit
  address, the caller's wallet sends funds to it on-chain, and status is polled
  until terminal. There is no client signature. Riddler is the single solver.
  """

  alias Raxol.Payments.Poll
  alias Raxol.Payments.Relay.Client
  alias Raxol.Payments.Relay.Schemas.{QuoteRequest, ExecuteRequest, StatusResponse}

  @doc "Request a Tron cross-chain quote (with a deposit address)."
  @spec get_quote(Client.config(), QuoteRequest.t()) ::
          {:ok, Raxol.Payments.Relay.Schemas.QuoteResponse.t()} | {:error, term()}
  def get_quote(config, %QuoteRequest{} = request), do: Client.get_quote(config, request)

  @doc "Initiate execution of a quoted transfer. Returns the initial status."
  @spec execute(Client.config(), String.t(), String.t()) ::
          {:ok, StatusResponse.t()} | {:error, term()}
  def execute(config, transfer_id, quote_id) do
    Client.execute(config, %ExecuteRequest{transfer_id: transfer_id, quote_id: quote_id})
  end

  @doc """
  Poll transfer status until terminal (completed/failed) or timeout.

  Fast-polls inside the settlement budget window, then backs off. See
  `Raxol.Payments.Poll` for the timing options.
  """
  @spec poll_status(Client.config(), String.t(), keyword()) ::
          {:ok, StatusResponse.t()} | {:error, term()}
  def poll_status(config, transfer_id, opts \\ []) do
    case poll_status_timed(config, transfer_id, opts) do
      {:ok, status, _elapsed_ms} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Like `poll_status/3` but also returns the elapsed milliseconds to the terminal
  status, so the caller can report whether settlement landed within budget.
  """
  @spec poll_status_timed(Client.config(), String.t(), keyword()) ::
          {:ok, StatusResponse.t(), non_neg_integer()} | {:error, term()}
  def poll_status_timed(config, transfer_id, opts \\ []) do
    Poll.run(
      fn -> Client.get_status(config, transfer_id) end,
      &StatusResponse.terminal?/1,
      opts
    )
  end
end
