defmodule Raxol.Agent.Sandbox.Async do
  @moduledoc """
  Async-task isolation dimension for `Raxol.Agent.Sandbox`.

  Gates `Raxol.Agent.Directive.Async` directives wholesale: the
  async function's body is opaque (a closure) so there's no
  payload-based matching. The sandbox is either `allow` (abstain)
  or `deny`.

  ## Constructors

      Sandbox.Async.allow()
        # abstain; any async task allowed

      Sandbox.Async.deny()
        # block every async task

  When an agent wants finer-grained async controls (rate limiting,
  per-task timeout, cancellation), it should use the
  `Raxol.Agent.Policy` structs around the operation that *creates*
  the async task, not the Sandbox dimension. The Sandbox is the
  binary "are async tasks permitted at all" check.
  """

  @type mode :: :allow | :deny

  @type t :: %__MODULE__{mode: mode()}

  @enforce_keys [:mode]
  defstruct [:mode]

  @doc "Construct an allow-all async sandbox (abstain)."
  @spec allow() :: t()
  def allow, do: %__MODULE__{mode: :allow}

  @doc "Construct a deny-all async sandbox."
  @spec deny() :: t()
  def deny, do: %__MODULE__{mode: :deny}

  @doc "Whether async tasks are permitted by this sandbox."
  @spec allowed?(t()) :: boolean()
  def allowed?(%__MODULE__{mode: :allow}), do: true
  def allowed?(%__MODULE__{mode: :deny}), do: false
end

defimpl Raxol.Agent.Sandbox, for: Raxol.Agent.Sandbox.Async do
  alias Raxol.Agent.Sandbox.Async

  def authorize(_sandbox, action, _payload, _ctx) when action != :async, do: :ok

  def authorize(sandbox, :async, _payload, _ctx) do
    if Async.allowed?(sandbox) do
      :ok
    else
      {:deny, :async_denied}
    end
  end
end
