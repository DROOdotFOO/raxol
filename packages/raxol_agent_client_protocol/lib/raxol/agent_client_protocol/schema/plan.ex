defmodule Raxol.AgentClientProtocol.Schema.PlanEntry do
  @moduledoc """
  A single entry in the execution plan. `content`, `priority`, and `status`
  are all required per the ACP schema (no `x-deserialize-default-on-error`
  leniency for this struct's own fields) -- a malformed value for any of
  them fails the whole entry's decode; the caller (`Plan.from_json/1`) skips
  entries that fail to decode rather than failing the whole plan.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type priority :: :high | :medium | :low
  @type status :: :pending | :in_progress | :completed

  @type t :: %__MODULE__{
          content: String.t(),
          priority: priority(),
          status: status(),
          _meta: map()
        }

  @enforce_keys [:content, :priority, :status]
  defstruct [:content, :priority, :status, _meta: %{}]

  @known_wire_keys ~w(content priority status)

  @spec new(String.t(), priority(), status()) :: t()
  def new(content, priority, status) when is_binary(content) do
    %__MODULE__{content: content, priority: priority, status: status}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = entry) do
    %{
      "content" => entry.content,
      "priority" => encode_priority(entry.priority),
      "status" => encode_status(entry.status)
    }
    |> WireFields.emit_meta(entry._meta)
  end

  @spec encode_priority(priority()) :: String.t()
  defp encode_priority(:high), do: "high"
  defp encode_priority(:medium), do: "medium"
  defp encode_priority(:low), do: "low"

  @spec decode_priority(term()) :: {:ok, priority()} | {:error, {:invalid_priority, term()}}
  defp decode_priority("high"), do: {:ok, :high}
  defp decode_priority("medium"), do: {:ok, :medium}
  defp decode_priority("low"), do: {:ok, :low}
  defp decode_priority(other), do: {:error, {:invalid_priority, other}}

  @spec encode_status(status()) :: String.t()
  defp encode_status(:pending), do: "pending"
  defp encode_status(:in_progress), do: "in_progress"
  defp encode_status(:completed), do: "completed"

  @spec decode_status(term()) :: {:ok, status()} | {:error, {:invalid_status, term()}}
  defp decode_status("pending"), do: {:ok, :pending}
  defp decode_status("in_progress"), do: {:ok, :in_progress}
  defp decode_status("completed"), do: {:ok, :completed}
  defp decode_status(other), do: {:error, {:invalid_status, other}}

  @doc """
  Total: never raises. Missing/wrong-typed `content`, or an unrecognized
  `priority`/`status` value, fails the whole entry -- these three fields are
  required with no schema-documented default.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"priority" => priority, "status" => status} = map) do
    with {:ok, content} <- WireFields.require(map, "content", &is_binary/1),
         {:ok, decoded_priority} <- decode_priority(priority),
         {:ok, decoded_status} <- decode_status(status) do
      {:ok,
       %__MODULE__{
         content: content,
         priority: decoded_priority,
         status: decoded_status,
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(map) when is_map(map) do
    missing = Enum.find(["priority", "status"], &(not Map.has_key?(map, &1)))
    {:error, {:missing_field, missing || "priority"}}
  end

  def from_json(other), do: {:error, {:invalid_plan_entry, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.PlanEntry do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.PlanEntry.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Plan do
  @moduledoc """
  An execution plan for accomplishing complex tasks: an ordered list of
  `PlanEntry` structs. Per the ACP schema, `entries` is decode-lenient
  at both levels: a missing/wrong-typed `entries` field defaults to `[]`
  (never fails the whole plan), and entries that individually fail to
  decode are skipped rather than aborting the list
  (`x-deserialize-skip-invalid-items`).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.PlanEntry
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          entries: [PlanEntry.t()],
          _meta: map()
        }

  @enforce_keys [:entries]
  defstruct [:entries, _meta: %{}]

  @known_wire_keys ~w(entries)

  @spec new([PlanEntry.t()]) :: t()
  def new(entries) when is_list(entries), do: %__MODULE__{entries: entries}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = plan) do
    %{"entries" => Enum.map(plan.entries, &PlanEntry.to_json/1)}
    |> WireFields.emit_meta(plan._meta)
  end

  @doc """
  Total: never raises, even for a non-map argument -- a value that isn't a
  wire object decodes as an empty plan with no `_meta`, since `entries`
  alone already tolerates every other malformed shape.
  """
  @spec from_json(term()) :: {:ok, t()}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       entries: WireFields.list_lenient(Map.get(map, "entries"), &PlanEntry.from_json/1, []),
       _meta: WireFields.fold_meta(map, @known_wire_keys)
     }}
  end

  def from_json(_other), do: {:ok, %__MODULE__{entries: []}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.Plan do
  def encode(val, opts) do
    val |> Raxol.AgentClientProtocol.Schema.Plan.to_json() |> Jason.Encoder.encode(opts)
  end
end
