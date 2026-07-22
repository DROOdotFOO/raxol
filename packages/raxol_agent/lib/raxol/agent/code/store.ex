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
  @string_to_role %{"user" => :user, "assistant" => :assistant, "system" => :system}

  @type message :: %{role: :user | :assistant | :system, content: String.t()}
  @type session :: %{
          id: String.t(),
          updated_at: integer(),
          cwd: String.t(),
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

  @doc "Persist a session's messages + metadata. Returns `:ok` or `{:error, reason}`."
  @spec save(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def save(dir, session_key, attrs) do
    with :ok <- File.mkdir_p(dir) do
      data =
        %{
          "id" => session_key,
          "updated_at" => System.system_time(:second),
          "cwd" => Map.get(attrs, :cwd, ""),
          "messages" => attrs |> Map.get(:messages, []) |> Enum.map(&encode_message/1),
          # Durable projection events, stored as-is (already JSON-encodable);
          # EventCodec decodes them back to projection shape on load.
          "events" => Map.get(attrs, :events, [])
        }

      File.write(path(dir, session_key), Jason.encode!(data))
    end
  end

  @doc "Load a session by id. Returns `{:ok, session}` or `{:error, :not_found}`."
  @spec load(String.t(), String.t()) :: {:ok, session()} | {:error, :not_found}
  def load(dir, session_key) do
    with {:ok, binary} <- File.read(path(dir, session_key)),
         {:ok, json} when is_map(json) <- Jason.decode(binary) do
      {:ok,
       %{
         id: Map.get(json, "id", session_key),
         updated_at: Map.get(json, "updated_at", 0),
         cwd: Map.get(json, "cwd", ""),
         messages:
           json
           |> Map.get("messages", [])
           |> Enum.map(&decode_message/1)
           |> Enum.reject(&is_nil/1),
         events: Raxol.Agent.Code.EventCodec.decode_all(Map.get(json, "events", []))
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "The most recently updated session id, or `nil` if none exist."
  @spec latest(String.t()) :: String.t() | nil
  def latest(dir) do
    case list(dir) do
      [%{id: id} | _] -> id
      [] -> nil
    end
  end

  @doc "Saved sessions, most-recently-updated first: `%{id, updated_at, message_count}`."
  @spec list(String.t()) :: [%{id: String.t(), updated_at: integer(), message_count: non_neg_integer()}]
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
        %{id: id, updated_at: session.updated_at, message_count: length(session.messages)}

      {:error, _} ->
        nil
    end
  end

  # `Path.basename/1` neutralizes any path separators / `..` in a caller- or
  # disk-supplied id, so a session key can never point outside `dir`.
  defp path(dir, session_key), do: Path.join(dir, Path.basename(session_key) <> ".json")

  defp encode_message(%{role: role, content: content}) do
    %{"role" => Map.get(@role_to_string, role, "user"), "content" => to_string(content)}
  end

  defp decode_message(%{"role" => role, "content" => content}) when is_binary(content) do
    case Map.get(@string_to_role, role) do
      nil -> nil
      atom -> %{role: atom, content: content}
    end
  end

  defp decode_message(_other), do: nil
end
