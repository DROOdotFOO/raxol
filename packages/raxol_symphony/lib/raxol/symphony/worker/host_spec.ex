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

  `workspace_root` is the root that `Raxol.Symphony.Workspace` creates this
  host's per-issue workspaces under (issue #744). A spec that omits it falls
  back to the configured `workspace.root`, which assumes the host mirrors the
  orchestrator's layout.
  """

  @enforce_keys [:host]
  defstruct [
    :host,
    :user,
    :port,
    :identity_file,
    :workspace_root,
    known_hosts: nil,
    strict_host_key_checking: :accept_new
  ]

  @typedoc """
  `StrictHostKeyChecking` policy for the eventual `ssh` invocation. Defaults
  to `:accept_new` (trust-on-first-use, current behavior); `:yes` forces a
  pre-seeded `known_hosts`, `:no` disables the check entirely.
  """
  @type host_key_mode :: :yes | :accept_new | :no

  @type t :: %__MODULE__{
          host: binary(),
          user: binary() | nil,
          port: pos_integer() | nil,
          identity_file: binary() | nil,
          workspace_root: binary() | nil,
          known_hosts: binary() | nil,
          strict_host_key_checking: host_key_mode()
        }

  # Accepted `StrictHostKeyChecking` inputs -> canonical atom. Wire values
  # arrive as strings (YAML front matter) or atoms (directly-built config);
  # this whitelist maps them WITHOUT `String.to_atom/1`. Anything absent
  # resolves to the `:invalid` sentinel, which `validate/2` rejects.
  @host_key_modes %{
    "yes" => :yes,
    "accept_new" => :accept_new,
    "accept-new" => :accept_new,
    "no" => :no,
    :yes => :yes,
    :accept_new => :accept_new,
    :no => :no
  }

  @doc """
  Normalize a raw `ssh_hosts` entry into a `%HostSpec{}`.

  Accepts an already-built spec, a non-empty `"user@host"` / `"host"`
  string, or a map carrying at least a non-empty `:host`. Anything else is
  `{:error, {:invalid_ssh_host, raw}}`.
  """
  @spec normalize(term()) :: {:ok, t()} | {:error, {:invalid_ssh_host, term()}}
  def normalize(%__MODULE__{host: host} = spec)
      when is_binary(host) and host != "" do
    validate(spec, spec)
  end

  def normalize(raw) when is_binary(raw) do
    case split_user_host(String.trim(raw)) do
      {:ok, user, host} -> validate(%__MODULE__{host: host, user: user}, raw)
      :error -> {:error, {:invalid_ssh_host, raw}}
    end
  end

  def normalize(raw) when is_map(raw) do
    case fetch(raw, :host) do
      host when is_binary(host) and host != "" ->
        validate(
          %__MODULE__{
            host: host,
            user: string_or_nil(fetch(raw, :user)),
            port: positive_int_or_nil(fetch(raw, :port)),
            identity_file: string_or_nil(fetch(raw, :identity_file)),
            workspace_root: string_or_nil(fetch(raw, :workspace_root)),
            known_hosts: string_or_nil(fetch(raw, :known_hosts)),
            strict_host_key_checking: host_key_mode(fetch(raw, :strict_host_key_checking))
          },
          raw
        )

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

  # A hostname/username token: first char alphanumeric or `_` (so it can
  # never be read as an `ssh` flag like `-oProxyCommand=...`), the rest
  # alphanumeric / dot / dash / underscore. This rejects whitespace and
  # shell metacharacters (`;`, `$`, backtick, quotes, `|`, `&`, newlines)
  # BEFORE the value can reach an `ssh` invocation (transport, issue #743).
  @token_re ~r/\A[A-Za-z0-9_][A-Za-z0-9._-]*\z/

  # Optional path fields become `ssh -i <file>` / `-o UserKnownHostsFile=...`
  # / a remote workspace root. Allow ordinary path characters but forbid a
  # leading `-` (matching @token_re) so a path can never be read as an `ssh`
  # flag. Reject whitespace + shell metacharacters throughout.
  @path_re ~r/\A[A-Za-z0-9._\/~][A-Za-z0-9._\-\/~]*\z/

  # `workspace_root` is held to more than @path_re, because two other modules
  # each build their own model of this string and they have to agree.
  #
  # `Raxol.Symphony.PathSafety.remote_workspace_path/2` treats ANY `~`-leading
  # root as home-anchored and measures containment against that reading.
  # `Raxol.Symphony.Ssh.quote_path/1` expands only `~` and `~user`, and quotes
  # anything else whole so the remote shell cannot expand it. @path_re admits
  # the prefixes bash gives a meaning that is neither: `~-` is `$OLDPWD`, `~0`
  # and `~-1` are directory-stack entries. Those made the two models disagree --
  # containment computed against a home-relative path, while the shell operated
  # on a literal directory named `~-` under wherever the login shell started. It
  # stayed contained (create and remove quote identically), and it was still a
  # root nobody could point at.
  #
  # Requiring a rooted path also moves the refusal to config time. A relative
  # root resolves against whatever directory the remote login shell happens to
  # start in, which `normalize_remote/1` already rejects -- but it rejected it at
  # first dispatch, one issue at a time, rather than when the config was read.
  @workspace_root_re ~r{\A(/|~([A-Za-z_][A-Za-z0-9._-]*)?(/|\z))}

  # Reject any spec whose host/user/path fields carry characters that could
  # break out of a later `ssh` command. This is the single validation point
  # shared by config validation and pool construction, so a malformed target
  # can never be silently normalized and handed to the transport.
  defp validate(%__MODULE__{} = spec, raw) do
    cond do
      not safe_token?(spec.host) ->
        {:error, {:invalid_ssh_host, raw}}

      not safe_optional_token?(spec.user) ->
        {:error, {:invalid_ssh_host, raw}}

      not safe_optional_path?(spec.identity_file) ->
        {:error, {:invalid_ssh_host, raw}}

      not safe_optional_workspace_root?(spec.workspace_root) ->
        {:error, {:invalid_ssh_host, raw}}

      not safe_optional_path?(spec.known_hosts) ->
        {:error, {:invalid_ssh_host, raw}}

      not valid_host_key_mode?(spec.strict_host_key_checking) ->
        {:error, {:invalid_ssh_host, raw}}

      true ->
        {:ok, spec}
    end
  end

  defp host_key_mode(nil), do: :accept_new
  defp host_key_mode(value), do: Map.get(@host_key_modes, value, :invalid)

  defp valid_host_key_mode?(mode) when mode in [:yes, :accept_new, :no], do: true
  defp valid_host_key_mode?(_mode), do: false

  defp safe_token?(value) when is_binary(value),
    do: Regex.match?(@token_re, value)

  defp safe_token?(_value), do: false

  defp safe_optional_token?(nil), do: true
  defp safe_optional_token?(value), do: safe_token?(value)

  defp safe_optional_path?(nil), do: true
  defp safe_optional_path?(value), do: Regex.match?(@path_re, value)

  # @path_re first (no whitespace, no shell metacharacters, no leading `-`),
  # then rooted at `/` or at a tilde prefix the transport will actually expand.
  defp safe_optional_workspace_root?(nil), do: true

  defp safe_optional_workspace_root?(value) when is_binary(value) do
    safe_optional_path?(value) and Regex.match?(@workspace_root_re, value)
  end

  defp safe_optional_workspace_root?(_value), do: false

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

  defp positive_int_or_nil(value) when is_integer(value) and value > 0,
    do: value

  defp positive_int_or_nil(_value), do: nil

  defp user_prefix(nil), do: ""
  defp user_prefix(user), do: "#{user}@"

  defp port_suffix(nil), do: ""
  defp port_suffix(port), do: ":#{port}"
end
