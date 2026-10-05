defmodule Raxol.Broker.Tools.Catalog do
  @moduledoc """
  What each Robinhood tool is allowed to be, decided from the frozen capture
  in `priv/robinhood/tools_list.json` (see its `"provenance"`), never from
  what a server says at runtime.

  ## Classes

    * `:review` - `review_*_order` and `preview_*_order`.
    * `:write` - an explicit allowlist of shapes: `place_*_order`,
      `cancel_*_order`, `replace_*_order` (advanced-order placement is
      `place_advanced_order`), and alert create/update
      (`create_*alert*`, `update_*alert*`).
    * `:read` - annotated `readOnlyHint: true` and not write-shaped.
    * `:unknown` - everything else: a tool absent from the capture, a
      write-shaped tool outside the allowlist (`exercise_option`,
      `create_watchlist`, ...), or one without the read-only hint. The
      executor and the read-only session refuse it.

  ## Against a live server

  `reconcile/1` diffs a live `tools/list` against the capture and returns the
  classes in force for that session. A tool whose `inputSchema` or
  `annotations` changed keeps `:read` (logged at `:warning`) but loses
  `:review` or `:write` (`:unknown`, logged at `:error`); a tool the capture
  lacks is `:unknown` (logged at `:error` when it is write- or
  review-shaped, else `:warning`); a captured tool the server no longer
  lists is logged at `:warning`.
  """

  require Logger

  @path Path.expand("../../../../priv/robinhood/tools_list.json", __DIR__)
  @external_resource @path
  @capture @path |> File.read!() |> Jason.decode!()
  @tools @capture |> Map.fetch!("tools") |> Enum.sort_by(& &1["name"])
  @by_name Map.new(@tools, &{&1["name"], &1})

  @review_shape ~r/\A(?:review|preview)_\w+_order\z/
  @write_allowlist [
    ~r/\A(?:place|cancel|replace)_\w+_order\z/,
    ~r/\A(?:create|update)_\w*alert\w*\z/
  ]
  # Verbs that change state. A tool of this shape the allowlist does not name
  # is never `:read`, whatever its annotations say.
  @mutating ~r/\A(?:place|cancel|replace|create|update|delete|add|remove|exercise|set|edit|submit|transfer|close|enable|disable)_/

  @type class :: :read | :review | :write | :unknown
  @type session :: %{String.t() => class()}

  @doc "The capture's provenance record."
  @spec provenance() :: map()
  def provenance, do: Map.get(@capture, "provenance", %{})

  @doc "The captured tools, sorted by name, in `tools/list` wire form."
  @spec recorded_tools() :: [map()]
  def recorded_tools, do: @tools

  @doc "The captured `inputSchema` of `name`, or nil."
  @spec schema(String.t()) :: map() | nil
  def schema(name) when is_binary(name) do
    case Map.fetch(@by_name, name) do
      {:ok, tool} -> map_field(tool, "inputSchema", :input_schema)
      :error -> nil
    end
  end

  @doc "The class of `name` in the capture."
  @spec classify(String.t()) :: class()
  def classify(name) when is_binary(name) do
    case Map.fetch(@by_name, name) do
      {:ok, tool} -> shape_class(name, tool)
      :error -> :unknown
    end
  end

  @doc """
  The class a tool definition (wire form) gets by its name and annotations
  alone, as if it were captured. For reviewing a new capture; at runtime
  only `classify/1` and `reconcile/1` decide.
  """
  @spec classify(String.t(), map()) :: class()
  def classify(name, tool) when is_binary(name) and is_map(tool), do: shape_class(name, tool)

  @doc "Every captured tool's class: the session to use when there is no live list."
  @spec static() :: session()
  def static, do: Map.new(@tools, &{&1["name"], classify(&1["name"])})

  @doc """
  The review tool for a captured `place_*` tool: `review_<rest>` or
  `preview_<rest>`, whichever the capture classifies `:review`.
  """
  @spec review_for(String.t()) :: {:ok, String.t()} | {:error, :no_review}
  def review_for("place_" <> rest = name) do
    with :write <- classify(name),
         review when is_binary(review) <-
           Enum.find(["review_" <> rest, "preview_" <> rest], &(classify(&1) == :review)) do
      {:ok, review}
    else
      _ -> {:error, :no_review}
    end
  end

  def review_for(name) when is_binary(name), do: {:error, :no_review}

  @doc "The class of `name` in `session`; anything it does not list is `:unknown`."
  @spec class(session(), String.t()) :: class()
  def class(session, name) when is_map(session), do: Map.get(session, name, :unknown)

  @doc "`:ok` when `name` is `expected` in `session`, else the refusal."
  @spec permit(session(), String.t(), class()) ::
          :ok | {:error, {:tool_refused, String.t(), class()}}
  def permit(session, name, expected) do
    case class(session, name) do
      ^expected -> :ok
      other -> {:error, {:tool_refused, name, other}}
    end
  end

  @doc """
  Diff a live `tools/list` (`Raxol.MCP.Client` tool maps or wire maps)
  against the capture, log the drift, and return the classes in force.
  """
  @spec reconcile([map()]) :: session()
  def reconcile(live) when is_list(live) do
    live = Map.new(live, &{name_of(&1), &1})

    for {name, _tool} <- @by_name, not Map.has_key?(live, name) do
      Logger.warning("[Broker.Tools] captured tool #{name} is not served")
    end

    Map.new(live, fn {name, tool} -> {name, live_class(name, tool)} end)
  end

  defp live_class(name, tool) do
    case Map.fetch(@by_name, name) do
      :error ->
        level = if risky_shape?(name), do: :error, else: :warning
        Logger.log(level, "[Broker.Tools] #{name} is not in the capture; refused as :unknown")
        :unknown

      {:ok, captured} ->
        if same?(captured, tool), do: classify(name), else: drifted(name)
    end
  end

  defp drifted(name) do
    case classify(name) do
      :read ->
        Logger.warning("[Broker.Tools] read tool #{name} changed since the capture")
        :read

      class when class in [:review, :write] ->
        Logger.error("[Broker.Tools] #{class} tool #{name} changed since the capture; refused")
        :unknown

      :unknown ->
        :unknown
    end
  end

  # `inputSchema` and `annotations` compared as `Raxol.MCP.Client` keeps them:
  # anything that is not a map (absent, `null`) is `%{}`.
  defp same?(captured, tool) do
    map_field(tool, "inputSchema", :input_schema) ==
      map_field(captured, "inputSchema", :input_schema) and
      map_field(tool, "annotations", :annotations) ==
        map_field(captured, "annotations", :annotations)
  end

  defp map_field(tool, string_key, atom_key) do
    case Map.get(tool, string_key, Map.get(tool, atom_key)) do
      value when is_map(value) -> value
      _absent -> %{}
    end
  end

  defp name_of(tool), do: Map.get(tool, "name", Map.get(tool, :name))

  defp shape_class(name, tool) do
    cond do
      Regex.match?(@review_shape, name) -> :review
      Enum.any?(@write_allowlist, &Regex.match?(&1, name)) -> :write
      Regex.match?(@mutating, name) -> :unknown
      get_in(tool, ["annotations", "readOnlyHint"]) == true -> :read
      true -> :unknown
    end
  end

  defp risky_shape?(name),
    do:
      Regex.match?(@review_shape, name) or Regex.match?(@mutating, name) or
        Enum.any?(@write_allowlist, &Regex.match?(&1, name))
end
