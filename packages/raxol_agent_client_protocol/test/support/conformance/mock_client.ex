defmodule Raxol.AgentClientProtocol.Test.Conformance.MockClient do
  @moduledoc """
  ACP client fixture for the acpx (openclaw/acpx, MIT) v1 conformance corpus
  (see `Raxol.AgentClientProtocol.Test.Conformance.CaseRunner`).

  Ports `test/mock-agent.ts`'s companion runner client
  (`conformance/runner/run.ts`'s `RunnerClient`, upstream MIT): `fs/read_text_file`
  / `fs/write_text_file` resolve against the calling session's registered cwd
  (`register_session_cwd/3` -- a case-runner convenience, not a protocol
  message, mirroring the upstream harness's own `registerSessionCwd` call)
  and fail closed with a "Permission denied" message when the case's
  `permission_mode` is `:deny_all` -- there is no `session/request_permission`
  round-trip in either fixture; permission is baked into whether the fs call
  itself succeeds, exactly like upstream. `handler_arg` IS the accumulator
  process (an `Agent`, started by the case runner itself) rather than a
  `handler_arg` this module wraps in `c:init/1` -- so the case runner holds
  the same pid it hands to `Raxol.AgentClientProtocol.Client.start_link/2`
  and can read `updates/1` / call `register_session_cwd/3` on it directly
  from outside the connection.
  """

  use Raxol.AgentClientProtocol.Client

  alias Raxol.AgentClientProtocol.Client.FsSandbox
  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.{ReadTextFileResponse, WriteTextFileResponse}

  @permission_denied_message "Permission denied by conformance runner"

  # -- Client callbacks --------------------------------------------------------

  @impl true
  def session_update(notification, ctx) do
    Elixir.Agent.update(ctx.handler_state, fn state ->
      %{state | updates: [notification | state.updates]}
    end)

    :ok
  end

  @impl true
  def read_text_file(req, ctx) do
    state = Elixir.Agent.get(ctx.handler_state, & &1)

    if state.permission_mode == :deny_all do
      {:error, Error.new(Error.auth_required_code(), @permission_denied_message)}
    else
      with {:ok, real} <- resolve(state, req.session_id, req.path),
           {:ok, content} <- File.read(real) do
        {:ok, ReadTextFileResponse.new(content)}
      else
        {:error, %Error{}} = err ->
          err

        {:error, reason} ->
          {:error, Error.with_data(Error.resource_not_found(req.path), inspect(reason))}
      end
    end
  end

  @impl true
  def write_text_file(req, ctx) do
    state = Elixir.Agent.get(ctx.handler_state, & &1)

    if state.permission_mode == :deny_all do
      {:error, Error.new(Error.auth_required_code(), @permission_denied_message)}
    else
      with {:ok, real} <- resolve(state, req.session_id, req.path),
           :ok <- File.mkdir_p(Path.dirname(real)),
           :ok <- File.write(real, req.content) do
        {:ok, WriteTextFileResponse.new()}
      else
        {:error, %Error{}} = err -> err
        {:error, reason} -> {:error, Error.with_data(Error.internal_error(), inspect(reason))}
      end
    end
  end

  defp resolve(state, session_id, path) do
    cwd = Map.get(state.session_cwds, session_id, System.tmp_dir!())
    FsSandbox.resolve(cwd, path)
  end

  # -- Case-runner-only helpers (not protocol callbacks) -----------------------

  @doc "Fresh accumulator state for one case: `permission_mode` is `:approve_all` or `:deny_all`."
  @spec new_state(:approve_all | :deny_all) :: pid()
  def new_state(permission_mode) when permission_mode in [:approve_all, :deny_all] do
    {:ok, pid} =
      Elixir.Agent.start_link(fn ->
        %{updates: [], session_cwds: %{}, permission_mode: permission_mode}
      end)

    pid
  end

  @doc "Register the cwd a session was created with, for later fs path resolution -- runner-side only, mirrors the upstream harness's own bookkeeping."
  @spec register_session_cwd(pid(), String.t(), String.t()) :: :ok
  def register_session_cwd(state_pid, session_id, cwd) do
    Elixir.Agent.update(state_pid, fn state ->
      %{state | session_cwds: Map.put(state.session_cwds, session_id, cwd)}
    end)
  end

  @doc "Every `session/update` notification observed so far, oldest first."
  @spec updates(pid()) :: [struct()]
  def updates(state_pid) do
    state_pid |> Elixir.Agent.get(& &1.updates) |> Enum.reverse()
  end
end
