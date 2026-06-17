defmodule Raxol.Core.Stores.Dets do
  @moduledoc """
  Shared DETS lifecycle for ETS-backed stores with optional disk persistence.

  An ETS-backed store keeps its working set in one or more `:named_table`
  ETS tables and, when configured, mirrors the canonical records to a DETS
  file so they survive a process restart. This module covers:

  - resolving the DETS path from start options or application config,
  - opening (or creating) the file and replaying its records back into the
    caller's live ETS tables on boot,
  - writing through to disk on each mutation,
  - flushing and closing the file on shutdown.

  The caller owns its ETS table topology and replay logic. The replay step
  is supplied as a function so a store with secondary indices can re-index
  every record as it is read back. A `nil` handle is a valid no-op
  throughout, so a store with persistence disabled can call these helpers
  unconditionally.

  Pure: depends only on `:dets`, `File`, and `Path`.
  """

  @typedoc "An open DETS handle, or `nil` when persistence is disabled."
  @type handle :: :dets.tab_name() | nil

  @doc """
  Resolve the configured DETS path, or `nil` when persistence is disabled.

  An explicit `:dets_path` in `opts` always wins; otherwise the value falls
  back to `Application.get_env(otp_app, config_key)`. Returns `nil` when
  neither is set, signalling in-memory-only operation.
  """
  @spec resolve_path(keyword(), atom(), atom()) :: binary() | nil
  def resolve_path(opts, otp_app, config_key)
      when is_list(opts) and is_atom(otp_app) and is_atom(config_key) do
    case Keyword.get(opts, :dets_path) do
      nil -> Application.get_env(otp_app, config_key)
      path -> path
    end
  end

  @doc """
  Open (or create) the DETS file at `path` under table name `dets_name`,
  replay every stored record through `replay_fun`, and return the handle.

  `replay_fun` is called once per `{key, value}` record for its side effect
  (re-inserting into the caller's ETS tables); its return value is ignored.

  Raises when the parent directory cannot be created or the file cannot be
  opened, so a misconfigured path surfaces at boot rather than degrading
  silently to an in-memory store.
  """
  @spec open!(atom(), binary(), ({term(), term()} -> any())) :: handle()
  def open!(dets_name, path, replay_fun)
      when is_atom(dets_name) and is_binary(path) and is_function(replay_fun, 1) do
    expanded = Path.expand(path)
    expanded |> Path.dirname() |> File.mkdir_p!()
    file_charlist = String.to_charlist(expanded)

    case :dets.open_file(dets_name, type: :set, file: file_charlist) do
      {:ok, table} ->
        :ok =
          :dets.foldl(
            fn record, _acc ->
              replay_fun.(record)
              :ok
            end,
            :ok,
            table
          )

        table

      {:error, reason} ->
        raise """
        Raxol.Core.Stores.Dets: failed to open DETS file at #{inspect(path)}
        (reason: #{inspect(reason)}).

        Either fix the path or disable DETS persistence to fall back to
        in-memory ETS only.
        """
    end
  end

  @doc "Write a record through to disk. No-op when persistence is disabled."
  @spec put(handle(), term(), term()) :: :ok
  def put(nil, _key, _value), do: :ok

  def put(dets, key, value) do
    :dets.insert(dets, {key, value})
    :ok
  end

  @doc "Delete a record from disk. No-op when persistence is disabled."
  @spec delete(handle(), term()) :: :ok
  def delete(nil, _key), do: :ok

  def delete(dets, key) do
    :dets.delete(dets, key)
    :ok
  end

  @doc "Wipe every persisted record. No-op when persistence is disabled."
  @spec clear(handle()) :: :ok
  def clear(nil), do: :ok

  def clear(dets) do
    :dets.delete_all_objects(dets)
    :ok
  end

  @doc """
  Flush and close the DETS file. No-op when persistence is disabled.

  Intended for a store's `terminate/2`. A `SIGKILL` can still lose the most
  recent write window; use a real database for stronger guarantees.
  """
  @spec close(handle()) :: :ok
  def close(nil), do: :ok

  def close(dets) do
    _ = :dets.sync(dets)
    _ = :dets.close(dets)
    :ok
  end
end
