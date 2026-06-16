defmodule Raxol.Agent.Sandbox.SendAgent do
  @moduledoc """
  Inter-agent messaging isolation dimension for
  `Raxol.Agent.Sandbox`.

  Gates `Raxol.Agent.Directive.SendAgent` directives by matching the
  target agent's id.

  ## Constructors

      Sandbox.SendAgent.none()
        # abstain; any target allowed

      Sandbox.SendAgent.deny_all()
        # block every inter-agent message

      Sandbox.SendAgent.allow_only([:worker_a, :worker_b])
        # allow only those target ids

      Sandbox.SendAgent.allow_only(fn id -> is_atom(id) end)
        # arbitrary predicate

      Sandbox.SendAgent.deny([:dangerous_agent])
        # block those target ids; allow others

  Target ids are arbitrary terms (atoms in practice, but the
  framework does not constrain). List matching uses `in/2`;
  predicate matching uses `fun.(id)` and coerces with `!!`.
  """

  @type mode ::
          :none
          | :deny_all
          | {:allow_only, [term()] | (term() -> boolean())}
          | {:deny, [term()] | (term() -> boolean())}

  @type t :: %__MODULE__{mode: mode()}

  @enforce_keys [:mode]
  defstruct [:mode]

  @doc "Construct a no-op send-agent sandbox (abstain)."
  @spec none() :: t()
  def none, do: %__MODULE__{mode: :none}

  @doc "Construct a deny-all send-agent sandbox."
  @spec deny_all() :: t()
  def deny_all, do: %__MODULE__{mode: :deny_all}

  @doc """
  Construct an allow-only sandbox. Accepts a list of target ids or
  a 1-arity predicate.
  """
  @spec allow_only([term()] | (term() -> boolean())) :: t()
  def allow_only(list_or_fun)
      when is_list(list_or_fun) or is_function(list_or_fun, 1),
      do: %__MODULE__{mode: {:allow_only, list_or_fun}}

  @doc """
  Construct a deny sandbox. Accepts a list of target ids or a
  1-arity predicate.
  """
  @spec deny([term()] | (term() -> boolean())) :: t()
  def deny(list_or_fun)
      when is_list(list_or_fun) or is_function(list_or_fun, 1),
      do: %__MODULE__{mode: {:deny, list_or_fun}}

  @doc "Whether the target id is permitted by this sandbox."
  @spec allowed?(t(), term()) :: boolean()
  def allowed?(%__MODULE__{mode: :none}, _target_id), do: true
  def allowed?(%__MODULE__{mode: :deny_all}, _target_id), do: false

  def allowed?(%__MODULE__{mode: {:allow_only, list}}, target_id)
      when is_list(list),
      do: target_id in list

  def allowed?(%__MODULE__{mode: {:allow_only, fun}}, target_id)
      when is_function(fun, 1),
      do: !!fun.(target_id)

  def allowed?(%__MODULE__{mode: {:deny, list}}, target_id) when is_list(list),
    do: target_id not in list

  def allowed?(%__MODULE__{mode: {:deny, fun}}, target_id)
      when is_function(fun, 1),
      do: !fun.(target_id)
end

defimpl Raxol.Agent.Sandbox, for: Raxol.Agent.Sandbox.SendAgent do
  alias Raxol.Agent.Sandbox.SendAgent

  def authorize(_sandbox, action, _payload, _ctx) when action != :send_agent,
    do: :ok

  def authorize(sandbox, :send_agent, %{target_id: target_id}, _ctx) do
    if SendAgent.allowed?(sandbox, target_id) do
      :ok
    else
      {:deny, {:send_agent_denied, sandbox.mode, target_id}}
    end
  end

  def authorize(_sandbox, :send_agent, payload, _ctx),
    do: {:deny, {:send_agent_malformed_payload, payload}}
end
