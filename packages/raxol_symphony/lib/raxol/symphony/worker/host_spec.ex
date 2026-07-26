defmodule Raxol.Symphony.Worker.HostSpec do
  @moduledoc """
  A canonical SSH host spec for a remote Symphony worker (issue #742).

  A `worker.ssh_hosts` entry in `WORKFLOW.md` is either a bare
  `"user@host"` string or a map:

      worker:
        ssh_hosts:
          - build-1.internal            # host only
          - ci@build-2.internal         # user@host
          - host: build-3.internal
            user: ci
            port: 2222
            identity_file: ~/.ssh/id_ci
            workspace_root: /var/lib/symphony

  `normalize/1` turns any accepted form into a `%HostSpec{}`. This is the
  single normalization point, shared by config validation
  (`Raxol.Symphony.Config.Schema`) and pool construction
  (`Raxol.Symphony.Worker.HostPool`). Only the transport (issue #743) turns
  a spec into an actual `ssh` invocation; this module is pure data.
  """

  @enforce_keys [:host]
  defstruct [:host, :user, :port, :identity_file, :workspace_root]

  @type t :: %__MODULE__{
          host: binary(),
          user: binary() | nil,
          port: pos_integer() | nil,
          identity_file: binary() | nil,
          workspace_root: binary() | nil
        }

  @doc """
  Normalize a raw `ssh_hosts` entry into a `%HostSpec{}`.

  Accepts an already-built spec, a non-empty `"user@host"` / `"host"`
  string, or a map carrying at least a non-empty `:host`. Anything else is
  `{:error, {:invalid_ssh_host, raw}}`.
  """
  @spec normalize(term()) :: {:ok, t()} | {:error, {:invalid_ssh_host, term()}}
  def normalize(%__MODULE__{host: host} = spec) when is_binary(host) and host != "" do
    {:ok, spec}
  end

  def normalize(raw) when is_binary(raw) do
    case split_user_host(String.trim(raw)) do
      {:ok, user, host} -> {:ok, %__MODULE__{host: host, user: user}}
      :error -> {:error, {:invalid_ssh_host, raw}}
    end
  end

  def normalize(raw) when is_map(raw) do
    case fetch(raw, :host) do
      host when is_binary(host) and host != "" ->
        {:ok,
         %__MODULE__{
           host: host,
           user: string_or_nil(fetch(raw, :user)),
           port: positive_int_or_nil(fetch(raw, :port)),
           identity_file: string_or_nil(fetch(raw, :identity_file)),
           workspace_root: string_or_nil(fetch(raw, :workspace_root))
         }}

      _absent_or_blank ->
        {:error, {:invalid_ssh_host, raw}}
    end
  end

  def normalize(raw), do: {:error, {:invalid_ssh_host, raw}}

  @doc """
  A stable identity for pool slotting and release: `user@host:port`
  (user/port omitted when absent). Two entries that resolve the same SSH
  target share an id.
  """
  @spec id(t()) :: binary()
  def id(%__MODULE__{host: host, user: user, port: port}) do
    "#{user_prefix(user)}#{host}#{port_suffix(port)}"
  end

  # -- Internals --------------------------------------------------------------

  # Config front matter is atomized (trusted WORKFLOW.md), but tolerate
  # string keys too so a directly-built config still normalizes.
  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp split_user_host(""), do: :error

  defp split_user_host(str) do
    case String.split(str, "@", parts: 2) do
      [host] -> {:ok, nil, host}
      [user, host] when user != "" and host != "" -> {:ok, user, host}
      _malformed -> :error
    end
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  defp positive_int_or_nil(value) when is_integer(value) and value > 0, do: value
  defp positive_int_or_nil(_value), do: nil

  defp user_prefix(nil), do: ""
  defp user_prefix(user), do: "#{user}@"

  defp port_suffix(nil), do: ""
  defp port_suffix(port), do: ":#{port}"
end
