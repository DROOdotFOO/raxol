defmodule Raxol.Earn.Console.Spec do
  @moduledoc """
  Validation + normalization of a `custom_console_agent` buyer requirement.

  `handle_request/2` runs `validate/1` so a malformed or out-of-policy request
  is rejected *before escrow* with a typed reason (mirroring the launch gate in
  the Xochi offerings), and `handle_deliver/2` re-runs it so delivery is
  stateless across restarts/resync — the accepted request map is the only
  carried state.

  Rejection reasons are `{:invalid_requirement, field, detail}`,
  `{:denied_purpose, term}`, or (from the offering) `{:bench_unavailable, _}` /
  `:at_bench_capacity`.

  A light content policy checks `purpose`/`persona` against
  `config :raxol_earn, :console_deny_terms` (list of downcased substrings,
  default `[]`).
  """

  alias Raxol.Earn.Console.Cron

  # String enum <-> atom maps. The atom literals here are interned at compile
  # time, so the string->atom conversion below never depends on the atom having
  # been created elsewhere first (a bare `String.to_existing_atom/1` on
  # "openclaw" would raise if no other module happened to reference it yet).
  @runtime_atom %{
    "hermes" => :hermes,
    "openclaw" => :openclaw,
    "raxol" => :raxol,
    "either" => :either
  }
  @validation_atom %{"bench_validated" => :bench_validated, "package_only" => :package_only}
  @runtimes ~w(hermes openclaw raxol either)
  @validations ~w(bench_validated package_only)
  @agent_name ~r/^[a-z][a-z0-9_-]{2,29}$/

  defstruct purpose: nil,
            runtime: :either,
            agent_name: nil,
            persona: nil,
            scheduled_tasks: [],
            skills: [],
            constraints: %{},
            validation: :bench_validated

  @type cadence :: {:cron, String.t()} | {:nl, String.t()}
  @type t :: %__MODULE__{
          purpose: String.t(),
          runtime: :hermes | :openclaw | :raxol | :either,
          agent_name: String.t() | nil,
          persona: String.t() | nil,
          scheduled_tasks: [%{description: String.t(), cadence: cadence()}],
          skills: [String.t()],
          constraints: map(),
          validation: :bench_validated | :package_only
        }

  @doc "Validate and normalize a raw requirement map (string or atom keys)."
  @spec validate(map()) :: {:ok, t()} | {:error, term()}
  def validate(req) when is_map(req) do
    with {:ok, purpose} <- str(req, "purpose", 1, 2000, :required),
         {:ok, runtime} <- enum(req, "runtime", @runtimes, :required),
         {:ok, agent_name} <- agent_name(req),
         {:ok, persona} <- str(req, "persona", 1, 2000, :optional),
         {:ok, tasks} <- tasks(req),
         {:ok, skills} <- skills(req),
         {:ok, constraints} <- constraints(req),
         {:ok, validation} <- enum(req, "validation", @validations, {:default, "bench_validated"}),
         :ok <- policy(purpose, persona) do
      {:ok,
       %__MODULE__{
         purpose: purpose,
         runtime: Map.fetch!(@runtime_atom, runtime),
         agent_name: agent_name,
         persona: persona,
         scheduled_tasks: tasks,
         skills: skills,
         constraints: constraints,
         validation: Map.fetch!(@validation_atom, validation)
       }}
    end
  end

  def validate(other), do: {:error, {:invalid_requirement, :root, {:not_a_map, other}}}

  @doc "The offering's `requirement` JSON Schema (draft-07, string keys)."
  @spec requirement_schema() :: map()
  def requirement_schema do
    %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["purpose", "runtime"],
      "properties" => %{
        "purpose" => %{"type" => "string", "minLength" => 1, "maxLength" => 2000},
        "runtime" => %{"type" => "string", "enum" => @runtimes},
        "agent_name" => %{"type" => "string", "pattern" => "^[a-z][a-z0-9_-]{2,29}$"},
        "persona" => %{"type" => "string", "maxLength" => 2000},
        "scheduled_tasks" => %{
          "type" => "array",
          "maxItems" => 5,
          "items" => %{
            "type" => "object",
            "required" => ["description", "cadence"],
            "additionalProperties" => false,
            "properties" => %{
              "description" => %{"type" => "string", "minLength" => 1, "maxLength" => 500},
              "cadence" => %{
                "type" => "string",
                "maxLength" => 100,
                "description" => "5-field cron, or natural language (canonicalized to cron)"
              }
            }
          }
        },
        "skills" => %{
          "type" => "array",
          "maxItems" => 10,
          "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 200}
        },
        "constraints" => %{"type" => "object"},
        "validation" => %{"type" => "string", "enum" => @validations}
      }
    }
  end

  # -- field validators ------------------------------------------------------

  defp get(req, key), do: Map.get(req, key) || Map.get(req, String.to_existing_atom(key))

  defp str(req, key, min, max, mode) do
    case {get(req, key), mode} do
      {nil, :required} -> {:error, {:invalid_requirement, key, :missing}}
      {nil, :optional} -> {:ok, nil}
      {v, _} when is_binary(v) and byte_size(v) >= min and byte_size(v) <= max -> {:ok, v}
      {v, _} -> {:error, {:invalid_requirement, key, {:bad_string, v}}}
    end
  end

  defp enum(req, key, allowed, mode) do
    case {get(req, key), mode} do
      {nil, :required} -> {:error, {:invalid_requirement, key, :missing}}
      {nil, {:default, d}} -> {:ok, d}
      {v, _} when is_binary(v) -> if v in allowed, do: {:ok, v}, else: bad_enum(key, v)
      {v, _} -> bad_enum(key, v)
    end
  end

  defp bad_enum(key, v), do: {:error, {:invalid_requirement, key, {:not_in_enum, v}}}

  defp agent_name(req) do
    case get(req, "agent_name") do
      nil -> {:ok, nil}
      v when is_binary(v) -> if v =~ @agent_name, do: {:ok, v}, else: bad(:agent_name, v)
      v -> bad(:agent_name, v)
    end
  end

  defp tasks(req) do
    case get(req, "scheduled_tasks") do
      nil ->
        {:ok, []}

      list when is_list(list) and length(list) <= 5 ->
        list
        |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
          case task(item) do
            {:ok, t} -> {:cont, {:ok, [t | acc]}}
            {:error, _} = e -> {:halt, e}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          e -> e
        end

      v ->
        bad(:scheduled_tasks, v)
    end
  end

  defp task(%{} = item) do
    with {:ok, desc} <- str(item, "description", 1, 500, :required),
         {:ok, cad} <- str(item, "cadence", 1, 100, :required) do
      cadence = if Cron.valid?(cad), do: {:cron, cad}, else: {:nl, cad}
      {:ok, %{description: desc, cadence: cadence}}
    end
  end

  defp task(other), do: bad(:scheduled_tasks, other)

  defp skills(req) do
    case get(req, "skills") do
      nil ->
        {:ok, []}

      list when is_list(list) and length(list) <= 10 ->
        if Enum.all?(list, &(is_binary(&1) and byte_size(&1) in 1..200)),
          do: {:ok, list},
          else: bad(:skills, list)

      v ->
        bad(:skills, v)
    end
  end

  defp constraints(req) do
    case get(req, "constraints") do
      nil -> {:ok, %{}}
      %{} = m -> {:ok, m}
      v -> bad(:constraints, v)
    end
  end

  defp policy(purpose, persona) do
    deny = Application.get_env(:raxol_earn, :console_deny_terms, [])
    haystack = String.downcase("#{purpose} #{persona}")

    case Enum.find(deny, &String.contains?(haystack, String.downcase(&1))) do
      nil -> :ok
      term -> {:error, {:denied_purpose, term}}
    end
  end

  defp bad(field, v), do: {:error, {:invalid_requirement, field, {:invalid, v}}}
end
