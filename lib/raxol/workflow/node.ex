defmodule Raxol.Workflow.Node do
  @moduledoc """
  Node descriptors for `Raxol.Workflow.Graph`.

  A node is one of three shapes:

    * `FunctionNode` -- a 1-arity function `(state -> result)`
    * `BehaviourNode` -- a module implementing this module's behaviour
    * `TypedNode` -- a struct with a `Raxol.Workflow.Node.Executor`
      protocol implementation. Mirrors the `Raxol.Core.Runtime.Directive`
      pattern: lets external packages register typed nodes
      (e.g. `%Raxol.ACP.Workflow.Node.CreateMemo{...}`) with custom
      telemetry and validation.

  Node functions return one of:

    * `{:ok, state}` -- proceed with the new state
    * `{:effects, [directive], state}` -- emit Phase 24 directives and proceed
    * `{:interrupt, value}` -- pause the run for human-in-the-loop resume
    * `{:error, reason}` -- fail (handled by the workflow's failure policy)

  The runtime is added in a follow-up PR; this module only defines the
  descriptor shapes and behaviour so the `Graph` builder can carry them.
  """

  @type id :: atom() | binary()
  @type state :: any()
  @type result ::
          {:ok, state()}
          | {:effects, [struct()], state()}
          | {:interrupt, any()}
          | {:error, any()}

  @doc """
  Called once at run start to set up node-private state.

  Optional. Default returns the run's initial state unchanged.
  """
  @callback init(opts :: keyword()) :: state()

  @doc """
  Called once per visit to the node. Returns the next state, an
  interrupt, an error, or a state plus a list of `Raxol.Core.Runtime.Directive`
  structs to dispatch through the runtime's existing effect pipeline.
  """
  @callback run(state :: state(), opts :: keyword()) :: result()

  @doc """
  Called by the runtime's failure policy when `failure_policy: :compensate`
  is set and the run errors after this node already succeeded. Receives
  the current state (potentially modified by later compensations) and
  returns either an updated state via `{:ok, new_state}` or an error
  via `{:error, reason}`. Compensation errors are surfaced through
  `node.compensated` telemetry but do not displace the run's original
  failure reason. Default is a no-op that leaves the state untouched.
  """
  @callback compensate(state :: state(), opts :: keyword()) ::
              {:ok, state()} | {:error, any()}

  @optional_callbacks init: 1, compensate: 2

  defmodule FunctionNode do
    @moduledoc """
    A node backed by a 1-arity function.

    The optional `:compensate_fun` is invoked when the run fails under
    `failure_policy: :compensate` and this node had already succeeded.
    It receives the current state and returns
    `{:ok, new_state} | {:error, reason}`.
    """

    @type t :: %__MODULE__{
            id: Raxol.Workflow.Node.id(),
            fun: (any() -> any()),
            compensate_fun: (any() -> {:ok, any()} | {:error, any()}) | nil
          }

    @enforce_keys [:id, :fun]
    defstruct [:id, :fun, compensate_fun: nil]
  end

  defmodule BehaviourNode do
    @moduledoc """
    A node backed by a module implementing `Raxol.Workflow.Node`.
    """

    @type t :: %__MODULE__{
            id: Raxol.Workflow.Node.id(),
            module: module(),
            opts: keyword()
          }

    @enforce_keys [:id, :module]
    defstruct [:id, :module, opts: []]
  end

  defmodule TypedNode do
    @moduledoc """
    A node backed by a struct implementing
    `Raxol.Workflow.Node.Executor`. Used by external packages to
    register semantically-named nodes with custom telemetry.
    """

    @type t :: %__MODULE__{id: Raxol.Workflow.Node.id(), struct: struct()}

    @enforce_keys [:id, :struct]
    defstruct [:id, :struct]
  end

  @type t :: FunctionNode.t() | BehaviourNode.t() | TypedNode.t()

  @doc "Construct a `FunctionNode`."
  @spec function(id(), (state() -> result())) :: FunctionNode.t()
  def function(id, fun) when is_function(fun, 1),
    do: %FunctionNode{id: id, fun: fun}

  @doc """
  Construct a `FunctionNode` with an optional compensation function.

  The compensation runs in reverse order under
  `failure_policy: :compensate` when the run fails after this node
  succeeded. It must be a 1-arity function returning
  `{:ok, new_state} | {:error, reason}`.
  """
  @spec function(
          id(),
          (state() -> result()),
          (state() -> {:ok, state()} | {:error, any()})
        ) :: FunctionNode.t()
  def function(id, fun, compensate_fun)
      when is_function(fun, 1) and is_function(compensate_fun, 1),
      do: %FunctionNode{id: id, fun: fun, compensate_fun: compensate_fun}

  @doc "Construct a `BehaviourNode`."
  @spec behaviour(id(), module(), keyword()) :: BehaviourNode.t()
  def behaviour(id, module, opts \\ [])
      when is_atom(module) and is_list(opts) do
    %BehaviourNode{id: id, module: module, opts: opts}
  end

  @doc "Construct a `TypedNode`."
  @spec typed(id(), struct()) :: TypedNode.t()
  def typed(id, %_{} = struct), do: %TypedNode{id: id, struct: struct}

  @doc "Return the node's id."
  @spec id(t()) :: id()
  def id(%FunctionNode{id: id}), do: id
  def id(%BehaviourNode{id: id}), do: id
  def id(%TypedNode{id: id}), do: id
end

defprotocol Raxol.Workflow.Node.Executor do
  @moduledoc """
  Protocol for executing `Raxol.Workflow.Node.TypedNode` structs.

  External packages register typed nodes by defining a struct and
  implementing this protocol. Mirrors the
  `Raxol.Core.Runtime.Directive.Executor` shape: same callback name,
  same result tuple, same telemetry surface.

  The runtime is added in a follow-up PR; this protocol is declared
  now so the `Graph` builder can carry typed-node references.
  """

  @spec execute(t(), state :: any(), opts :: keyword()) ::
          Raxol.Workflow.Node.result()
  def execute(node_struct, state, opts)
end
