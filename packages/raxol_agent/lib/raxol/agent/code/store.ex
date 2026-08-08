defmodule Raxol.Agent.Code.Store do
  @moduledoc """
  On-disk persistence for `mix raxol.code` sessions — one JSON file per
  session under a base directory, so a conversation survives across runs
  and `--continue` / `--resume` can reattach it.

  A saved session is the LLM conversation (`messages`), the durable
  contract `events` (so `--resume` can rebuild the visual transcript, not
  just the model context), and a little metadata (`updated_at`, `cwd`).
  Only the three known roles (`:user`/`:assistant`/`:system`) round-trip;
  an unknown role on read is dropped rather than minting an atom from disk.
  Events are decoded back into projection shape by
  `Raxol.Agent.Code.EventCodec` (fixed vocabularies, no atom minting from
  disk). The session id is only ever used as a filename via
  `Path.basename/1`, so a crafted id can never escape the base directory.
  """

  @role_to_string %{user: "user", assistant: "assistant", system: "system"}
  @string_to_role %{
    "user" => :user,
    "assistant" => :assistant,
    "system" => :system
  }

  @type message :: %{role: :user | :assistant | :system, content: String.t()}
  @type session :: %{
          id: String.t(),
          updated_at: integer(),
          rev: String.t() | nil,
          cwd: String.t(),
          title: String.t(),
          parent: String.t() | nil,
          messages: [message()],
          events: [map()]
        }

  @doc "The default sessions directory (`$RAXOL_CODE_SESSIONS` or `~/.raxol/code_sessions`)."
  @spec default_dir() :: String.t()
  def default_dir do
    case System.get_env("RAXOL_CODE_SESSIONS") do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> Path.join(home_base(), ".raxol/code_sessions")
    end
  end

  defp home_base, do: System.user_home() || System.tmp_dir!()

  @doc """
  Persist a session's messages + metadata. Returns `:ok` or `{:error, reason}`.

  Options:

    * `:expect_rev` — optimistic concurrency. The save is refused with
      `{:error, :stale}` unless the on-disk `rev` still matches. Two surfaces
      share this store (the TUI and `Raxol.Agent.Harness.McpTools`), and a
      save rewrites the WHOLE file, so a blind write from one silently
      discards the other's turn. A caller that read the session first passes
      the `rev` it read and gets a refusal instead of a clobber.

      `rev` is a fresh random token per save, NOT `updated_at`: timestamps
      here have one-second resolution, and two surfaces writing within the
      same second is the common case rather than the rare one, so an
      `updated_at` comparison would miss exactly the race worth catching.

      Not every caller passes it, deliberately. A short read-modify-write
      (an MCP turn) can refuse and report; the TUI holds the session in
      memory across a whole run and has nowhere to put a refusal, so it
      saves unconditionally and wins. The asymmetry is the point: the
      surface that can still act on a refusal is the one that checks.

  The write itself is atomic: the JSON goes to a temp file in the same
  directory and is renamed over the target. A half-written session file
  decodes as damaged and `load/2` reports `:not_found`, which the surface
  reads as "starting fresh" — silently discarding the conversation, which
  lives ONLY here (the journal holds transcript events, not the messages).
  """
  @spec save(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def save(dir, session_key, attrs, opts \\ []) do
    with :ok <- File.mkdir_p(dir),
         :ok <- check_expected(dir, session_key, opts),
         {:ok, json} <- encode(session_key, attrs) do
      atomic_write(path(dir, session_key), json)
    end
  end

  defp check_expected(dir, session_key, opts) do
    case Keyword.fetch(opts, :expect_rev) do
      :error ->
        :ok

      {:ok, expected} ->
        case load(dir, session_key) do
          # No file yet: nothing to clobber, so any expectation is satisfiable.
          {:error, :not_found} -> :ok
          {:ok, %{rev: ^expected}} -> :ok
          {:ok, _moved_on} -> {:error, :stale}
        end
    end
  end

  # `Jason.encode/1`, not `encode!/1`: an event payload that is not
  # JSON-encodable must surface as the `{:error, _}` this function promises,
  # not raise through a caller written against that contract.
  defp encode(session_key, attrs) do
    data = %{
      "id" => session_key,
      "updated_at" => System.system_time(:second),
      # A fresh token per save: the version the next writer's `:expect_rev`
      # is checked against. Random rather than a counter so it needs no
      # read-modify-write, and differs across BEAM restarts.
      "rev" => Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      "cwd" => Map.get(attrs, :cwd, ""),
      "title" => Map.get(attrs, :title, ""),
      # A forked session records the id it was copied from.
      "parent" => Map.get(attrs, :parent),
      "messages" =>
        attrs |> Map.get(:messages, []) |> Enum.map(&encode_message/1),
      # Durable projection events, stored as-is (already JSON-encodable);
      # EventCodec decodes them back to projection shape on load.
      "events" => Map.get(attrs, :events, [])
    }

    case Jason.encode(data) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  # Write-then-rename in the SAME directory, so the rename is atomic on POSIX
  # and a reader sees either the previous session or the new one, never a
  # truncated prefix. The temp file is cleaned up on any failure.
  defp atomic_write(path, json) do
    tmp = path <> ".tmp." <> Integer.to_string(:erlang.unique_integer([:positive]))

    with :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  @doc "Load a session by id. Returns `{:ok, session}` or `{:error, :not_found}`."
  @spec load(String.t(), String.t()) :: {:ok, session()} | {:error, :not_found}
  def load(dir, session_key) do
    with {:ok, binary} <- File.read(path(dir, session_key)),
         {:ok, json} when is_map(json) <- Jason.decode(binary) do
      {:ok, build_session(json, session_key)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp build_session(json, session_key) do
    %{
      id: Map.get(json, "id", session_key),
      updated_at: Map.get(json, "updated_at", 0),
      # Sessions written before revisions existed carry none; `nil` is a
      # legitimate expectation, so they still round-trip through a CAS save.
      rev: string_or_nil(Map.get(json, "rev")),
      cwd: Map.get(json, "cwd", ""),
      title: string_or_empty(Map.get(json, "title")),
      parent: string_or_nil(Map.get(json, "parent")),
      messages:
        json
        |> Map.get("messages", [])
        |> Enum.map(&decode_message/1)
        |> Enum.reject(&is_nil/1),
      events:
        Raxol.Agent.Code.EventCodec.decode_all(Map.get(json, "events", []))
    }
  end

  @doc "The most recently updated session id, or `nil` if none exist."
  @spec latest(String.t()) :: String.t() | nil
  def latest(dir) do
    case list(dir) do
      [%{id: id} | _] -> id
      [] -> nil
    end
  end

  @doc """
  Saved sessions, most-recently-updated first:
  `%{id, updated_at, message_count, cwd, title}`.
  """
  @spec list(String.t()) :: [
          %{
            id: String.t(),
            updated_at: integer(),
            message_count: non_neg_integer(),
            cwd: String.t(),
            title: String.t()
          }
        ]
  def list(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&summarize(dir, String.replace_suffix(&1, ".json", "")))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.updated_at, :desc)

      {:error, _} ->
        []
    end
  end

  defp summarize(dir, id) do
    case load(dir, id) do
      {:ok, session} ->
        %{
          id: id,
          updated_at: session.updated_at,
          message_count: length(session.messages),
          cwd: session.cwd,
          title: session.title
        }

      {:error, _} ->
        nil
    end
  end

  defp string_or_empty(value) when is_binary(value), do: value
  defp string_or_empty(_other), do: ""

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_other), do: nil

  # `Path.basename/1` neutralizes any path separators / `..` in a caller- or
  # disk-supplied id, so a session key can never point outside `dir`.
  defp path(dir, session_key),
    do: Path.join(dir, Path.basename(session_key) <> ".json")

  defp encode_message(%{role: role, content: content}) do
    %{
      "role" => Map.get(@role_to_string, role, "user"),
      "content" => to_string(content)
    }
  end

  defp decode_message(%{"role" => role, "content" => content})
       when is_binary(content) do
    case Map.get(@string_to_role, role) do
      nil -> nil
      atom -> %{role: atom, content: content}
    end
  end

  defp decode_message(_other), do: nil
end
