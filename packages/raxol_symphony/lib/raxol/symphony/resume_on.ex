defmodule Raxol.Symphony.ResumeOn do
  @moduledoc """
  Ergonomic helpers for building `:resume_on` tokens consumed by
  `Raxol.Symphony.Resumer`.

  A Symphony runner pauses with a resume_token that may carry a
  `:resume_on` spec describing the external event the run is waiting
  for. Without this module, runners hand-roll the map:

      {:pause, :awaiting_buyer_payment,
       %{resume_on: %{
           telemetry: [:raxol, :acp, :job, :transition],
           match: %{job_id: "j-1", to: :transaction}
         }}}

  With it:

      acp_pause("j-1", waiting_for: :transaction, reason: :awaiting_buyer_payment)

  ## ACP-specific helpers

  `acp_transition/2` covers the common "wait for ACP job X to advance
  to state Y" case. It always targets the
  `[:raxol, :acp, :job, :transition]` telemetry event emitted by
  `Raxol.ACP.Job.Server` on every successful transition (see
  `raxol_acp` Job.Server moduledoc, "Telemetry" section).

  Compose `acp_pause/2` with `Orchestrator.resume_run/3` like so:

      # in a runner's run/3:
      Raxol.Symphony.ResumeOn.acp_pause("j-1",
        waiting_for: :transaction,
        reason: :awaiting_buyer_payment
      )

  On the orchestrator side, attach a `Resumer`:

      Raxol.Symphony.Resumer.start_link(
        orchestrator: Raxol.Symphony.Orchestrator,
        telemetry_event: [:raxol, :acp, :job, :transition]
      )

  When the ACP Job.Server fires `:transition` with metadata
  `%{job_id: "j-1", to: :transaction, ...}` the Resumer calls
  `Orchestrator.resume_run/3` with the event metadata as the
  resume value.
  """

  @acp_transition_event [:raxol, :acp, :job, :transition]

  @type resume_on :: %{
          telemetry: [atom(), ...],
          match: map()
        }

  @typedoc """
  Shape of a pause tuple emitted by a runner. The third element is the
  resume_token; the wrapping `%{resume_on: ...}` map is what the
  Resumer reads.
  """
  @type pause_tuple ::
          {:pause, atom(),
           %{
             optional(:resume_on) => resume_on(),
             optional(atom()) => term()
           }}

  @doc """
  Build a `resume_on` map for "wait until ACP job `job_id` transitions
  to state `to`".

  The `:to` state is a `Raxol.ACP.Job.StateMachine.state/0` atom: one of
  `:negotiation`, `:transaction`, `:evaluation`, `:completed`,
  `:rejected`, `:expired`.

  Pass `:from` to additionally constrain the matching transition's
  source state.

  Returns the bare `resume_on` map; wrap it in your own resume_token
  if you want to carry extra metadata, or use `acp_pause/2` to get a
  full pause tuple.

  ## Examples

      iex> Raxol.Symphony.ResumeOn.acp_transition("j-1", to: :transaction)
      %{
        telemetry: [:raxol, :acp, :job, :transition],
        match: %{job_id: "j-1", to: :transaction}
      }

      iex> Raxol.Symphony.ResumeOn.acp_transition("j-2", to: :completed, from: :evaluation)
      %{
        telemetry: [:raxol, :acp, :job, :transition],
        match: %{job_id: "j-2", to: :completed, from: :evaluation}
      }
  """
  @spec acp_transition(binary() | integer(), keyword()) :: resume_on()
  def acp_transition(job_id, opts) do
    to = Keyword.fetch!(opts, :to)
    from = Keyword.get(opts, :from)

    match =
      %{job_id: job_id, to: to}
      |> maybe_put(:from, from)

    %{telemetry: @acp_transition_event, match: match}
  end

  @doc """
  Build a full pause tuple for "wait until ACP job `job_id` transitions
  to `waiting_for` state, then resume" -- the convenience wrapper a
  runner returns from `run/3`.

  Required opts:

    * `:waiting_for` -- target ACP state to watch for.
    * `:reason` -- interrupt reason atom surfaced on the paused entry.

  Optional opts:

    * `:from` -- constrain the source state of the watched transition.
    * `:meta` -- extra map merged into the resume_token alongside
      `:resume_on`. Useful for stashing handler-specific context the
      runner needs on resume (e.g. a request id, partial deliverable).

  ## Example

      def run(issue, _config, _opts) do
        # ... do some work ...
        Raxol.Symphony.ResumeOn.acp_pause("j-1",
          waiting_for: :transaction,
          reason: :awaiting_buyer_payment,
          meta: %{step: "after-negotiation"}
        )
      end

      # ==> {:pause, :awaiting_buyer_payment,
      #      %{step: "after-negotiation",
      #        resume_on: %{telemetry: [...], match: %{job_id: "j-1", to: :transaction}}}}
  """
  @spec acp_pause(binary() | integer(), keyword()) :: pause_tuple()
  def acp_pause(job_id, opts) do
    waiting_for = Keyword.fetch!(opts, :waiting_for)
    reason = Keyword.fetch!(opts, :reason)
    from = Keyword.get(opts, :from)
    meta = Keyword.get(opts, :meta, %{})

    resume_on =
      acp_transition(job_id, [to: waiting_for] |> maybe_kw(:from, from))

    token = Map.put(meta, :resume_on, resume_on)
    {:pause, reason, token}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_kw(kw, _key, nil), do: kw
  defp maybe_kw(kw, key, value), do: Keyword.put(kw, key, value)
end
