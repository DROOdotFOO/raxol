defmodule Raxol.Agent.Authorization.Verdict do
  @moduledoc """
  The outcome a single authorization policy returns when it evaluates.

  One of three actions (the ALLOW/ASK/DENY trichotomy from omnigent's
  PolicyEngine), each optionally carrying `writes` -- label updates the policy
  wants applied:

    * `:allow` -- permit; `writes` are applied immediately.
    * `:ask`   -- require human approval; `writes` are held in escrow and applied
      only once approved. `prompt` is shown to the approver.
    * `:deny`  -- refuse; `reason` explains why. Short-circuits the engine.
  """

  @type action :: :allow | :ask | :deny

  @type t :: %__MODULE__{
          action: action(),
          writes: map(),
          reason: term(),
          prompt: binary() | nil
        }

  @enforce_keys [:action]
  defstruct action: :allow, writes: %{}, reason: nil, prompt: nil

  @doc "An allow verdict, optionally writing labels."
  @spec allow(map()) :: t()
  def allow(writes \\ %{}), do: %__MODULE__{action: :allow, writes: writes}

  @doc "An ask verdict with an approver `prompt`, optionally escrowing labels."
  @spec ask(binary(), map()) :: t()
  def ask(prompt, writes \\ %{}), do: %__MODULE__{action: :ask, prompt: prompt, writes: writes}

  @doc "A deny verdict with a `reason`."
  @spec deny(term()) :: t()
  def deny(reason), do: %__MODULE__{action: :deny, reason: reason}
end
