defmodule Raxol.Agent.Conversation.Store do
  @moduledoc """
  Behaviour for `Raxol.Agent.Conversation.Item` persistence.

  Mirrors `Raxol.Agent.ThreadLog`'s pluggable-adapter shape, but for the
  conversation item log: the store owns durability and assigns each item a stable
  `seq`/`id`; live fan-out and the snapshot/tail partition live in
  `Raxol.Agent.Conversation.Log`.

  One adapter ships today: `Raxol.Agent.Conversation.Store.ETS` (in-process,
  ordered_set on `{conversation_id, seq}`). A durable adapter (DETS/Postgrex) is a
  deliberate follow-up, matching ThreadLog's `Ets`/`Postgrex` split.

  ## Append is the only writer

  `append/3` assigns consecutive `seq` values atomically per conversation and
  returns the materialized items. Items are never updated or deleted; the log is
  append-only.

  ## Cursor pagination

  `list_items/3` accepts `:after`/`:before` sequence cursors (both exclusive),
  `:limit`, `:order`, and a `:type` filter. A reconnecting client pages forward by
  passing the last `seq` it has as `:after`.
  """

  alias Raxol.Agent.Conversation.Item

  @type config :: map()
  @type conversation_id :: binary()

  @typedoc "A new item to append; the store assigns id/seq/created_at."
  @type new_item :: %{
          required(:type) => Item.type(),
          optional(:data) => map(),
          optional(:status) => Item.status(),
          optional(:response_id) => binary() | nil,
          optional(:created_by) => term()
        }

  @typedoc """
  Options for `list_items/3`:

    * `:after` -- return items with `seq >` this value (exclusive cursor).
    * `:before` -- return items with `seq <` this value (exclusive).
    * `:limit` -- max items, or `:all`. Default 1000.
    * `:order` -- `:asc` (default) or `:desc`.
    * `:type` -- a type atom or list of types to filter by.
  """
  @type list_opts :: keyword()

  @callback append(config(), conversation_id(), [new_item()]) :: {:ok, [Item.t()]}
  @callback list_items(config(), conversation_id(), list_opts()) :: {:ok, [Item.t()]}
  @callback get_conversation(config(), conversation_id()) ::
              {:ok, map()} | {:error, :not_found}
  @callback list_conversations(config()) :: {:ok, [conversation_id()]}

  # --- Module-level dispatcher ---------------------------------------------

  @doc "Normalize a store opt into `{module, config}` form."
  @spec normalize(module() | {module(), config()}) :: {module(), config()}
  def normalize({module, config}) when is_atom(module) and is_map(config),
    do: {module, config}

  def normalize(module) when is_atom(module), do: {module, %{}}

  @doc "Dispatch `append` to the adapter."
  @spec append({module(), config()}, conversation_id(), [new_item()]) :: {:ok, [Item.t()]}
  def append({module, config}, conversation_id, items)
      when is_atom(module) and is_binary(conversation_id) and is_list(items),
      do: module.append(config, conversation_id, items)

  @doc "Dispatch `list_items` to the adapter."
  @spec list_items({module(), config()}, conversation_id(), list_opts()) :: {:ok, [Item.t()]}
  def list_items({module, config}, conversation_id, opts \\ [])
      when is_atom(module),
      do: module.list_items(config, conversation_id, opts)

  @doc "Dispatch `get_conversation` to the adapter."
  @spec get_conversation({module(), config()}, conversation_id()) ::
          {:ok, map()} | {:error, :not_found}
  def get_conversation({module, config}, conversation_id) when is_atom(module),
    do: module.get_conversation(config, conversation_id)

  @doc "Dispatch `list_conversations` to the adapter."
  @spec list_conversations({module(), config()}) :: {:ok, [conversation_id()]}
  def list_conversations({module, config}) when is_atom(module),
    do: module.list_conversations(config)
end
