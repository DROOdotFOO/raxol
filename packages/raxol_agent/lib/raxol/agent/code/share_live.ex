# Compile-gated: phoenix_live_view is an optional dependency, present in
# hosts that mount the share surface (and in this package's own dev/test
# env so the callbacks are exercised).
if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Raxol.Agent.Code.ShareLive do
    @moduledoc """
    Read-only live transcript of a shared coding-agent session.

    A host Phoenix app mounts it behind the token route:

        live "/share/:token", Raxol.Agent.Code.ShareLive

    The token comes from the TUI's `/share` (a signed, expiring
    `Raxol.Agent.Code.ShareToken`); the secret is
    `config :raxol_agent, :share_secret` or `RAXOL_SHARE_SECRET`. On a
    valid token the view replays the session's durable journal
    (rewind-marker aware, via `Raxol.Agent.Code.Replay`) and follows new
    records live through `Raxol.Agent.Reattach` — attached from the
    high-watermark so history and tail neither gap nor overlap.
    Transcript only: no input path exists on this surface.

    ## Scoped journal bases

    Session ids are unique within a journal base, and every multi-tenant
    tenant has its own (`<tenants_root>/<user>/sessions`). The token
    therefore carries the scope it was minted under, and the base is
    resolved FROM the signed scope — never guessed, and never the host
    default for a tenant's id. The tenants root comes from
    `config :raxol_agent, :share_tenants_root` or
    `RAXOL_SSH_CODE_TENANTS`, the same directory the SSH server serves
    from; without one, a scoped token has nowhere to resolve to and is
    refused rather than falling back to the host's own tree.

    ## Refresh coalescing

    A transcript is a fold over the whole record list (rewind markers
    retroactively drop earlier records, and blocks accumulate across
    events), so it cannot be appended to incrementally — it is recomputed.
    Recomputing per arriving record is quadratic over a session's lifetime,
    so live records are buffered and the fold runs at most once per
    refresh window (see `@refresh_ms`).
    """

    use Phoenix.LiveView

    alias Raxol.Agent.Code.Replay
    alias Raxol.Agent.Code.ShareToken
    alias Raxol.Agent.Journal.FileStore
    alias Raxol.Agent.Reattach

    # The transcript fold is O(records); recomputing it on every arriving
    # record makes a long session quadratic and re-pushes the whole <pre>
    # each time. Buffer arrivals and fold at most this often.
    @refresh_ms 150

    @impl true
    def mount(params, _session, socket) do
      token = Map.get(params, "token", "")

      # Every assign the live path reads exists from the first render, so a
      # record arriving before any refresh cannot hit a missing key.
      socket =
        assign(socket,
          session_id: nil,
          records: [],
          pending: [],
          refresh_armed?: false,
          transcript: "",
          error: nil
        )

      case verify(token) do
        {:ok, %{session_id: session_id, scope: scope}} ->
          {:ok, open_session(socket, session_id, scope)}

        {:error, :expired} ->
          {:ok, closed(socket, "this share link has expired")}

        {:error, _invalid} ->
          {:ok, closed(socket, "invalid share link")}
      end
    end

    # Records accumulate cheaply (prepend, reversed once at fold time) and a
    # single refresh is armed per window, so a burst of durable events costs
    # one fold rather than one per record.
    @impl true
    def handle_info({:reattach_live, _session_id, record}, socket) do
      {:noreply,
       socket
       |> assign(pending: [record | socket.assigns.pending])
       |> arm_refresh()}
    end

    def handle_info(:refresh_transcript, socket) do
      records =
        socket.assigns.records ++ Enum.reverse(socket.assigns.pending)

      {:noreply,
       assign(socket,
         records: records,
         pending: [],
         refresh_armed?: false,
         transcript: transcript(records)
       )}
    end

    def handle_info(_message, socket), do: {:noreply, socket}

    defp arm_refresh(%{assigns: %{refresh_armed?: true}} = socket), do: socket

    defp arm_refresh(socket) do
      Process.send_after(self(), :refresh_transcript, @refresh_ms)
      assign(socket, refresh_armed?: true)
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div class="raxol-share">
        <%= if @error do %>
          <p class="raxol-share-error"><%= @error %></p>
        <% else %>
          <h2 class="raxol-share-title">session <%= @session_id %> (read-only)</h2>
          <pre class="raxol-share-transcript"><%= @transcript %></pre>
        <% end %>
      </div>
      """
    end

    # -- internals (public test seams are the callbacks themselves) ----------

    defp open_session(socket, session_id, scope) do
      case journal_opts(scope) do
        {:ok, opts} -> open_scoped(socket, session_id, opts)
        {:error, message} -> closed(socket, message)
      end
    end

    defp open_scoped(socket, session_id, opts) do
      if session_exists?(session_id, opts) do
        socket = assign(socket, session_id: session_id, error: nil)

        # The tailer only starts on the CONNECTED mount; the static render
        # shows the replayed history without spawning a follower per crawl.
        if connected?(socket) do
          attach_live(socket, session_id, opts)
        else
          records = read_history(session_id, opts)
          assign(socket, records: records, transcript: transcript(records))
        end
      else
        # A valid token whose session is not in the base its scope resolves
        # to. Fail loud rather than render a blank transcript that reads as
        # an empty but healthy session.
        closed(socket, "session unavailable")
      end
    end

    # The signed scope decides the journal base: "" is this host's own,
    # anything else is a tenant under the configured tenants root. A scoped
    # token with no root configured has nowhere legitimate to resolve, so it
    # is refused — falling back to the host default would point a tenant's
    # session id at the host's tree.
    defp journal_opts(""), do: {:ok, []}

    defp journal_opts(scope) do
      case tenants_root() do
        nil ->
          {:error, "shared sessions are not served from this host"}

        root ->
          {:ok, [base_dir: Path.join([root, scope, "sessions"])]}
      end
    end

    defp tenants_root do
      blank_to_nil(Application.get_env(:raxol_agent, :share_tenants_root)) ||
        blank_to_nil(System.get_env("RAXOL_SSH_CODE_TENANTS"))
    end

    defp session_exists?(session_id, opts) do
      File.dir?(FileStore.session_dir(session_id, opts))
    end

    defp attach_live(socket, session_id, opts) do
      watermark = FileStore.high_watermark(session_id, opts)

      case Reattach.attach(session_id, watermark + 1, {:from_offset, 1}, opts) do
        {:ok, %{history: records}} ->
          assign(socket, records: records, transcript: transcript(records))

        {:error, reason} ->
          closed(socket, "session unavailable (#{inspect(reason)})")
      end
    end

    defp read_history(session_id, opts) do
      case FileStore.read_records(session_id, opts) do
        {:ok, records} -> records
        {:error, _damaged} -> []
      end
    end

    defp transcript(records) do
      records
      |> Replay.decode_records()
      |> Replay.transcript_text()
    end

    defp closed(socket, message) do
      assign(socket,
        session_id: nil,
        records: [],
        pending: [],
        refresh_armed?: false,
        transcript: "",
        error: message
      )
    end

    defp verify(token) do
      case share_secret() do
        nil -> {:error, :invalid}
        secret -> ShareToken.verify(token, secret)
      end
    end

    defp share_secret do
      blank_to_nil(Application.get_env(:raxol_agent, :share_secret)) ||
        blank_to_nil(System.get_env("RAXOL_SHARE_SECRET"))
    end

    # A declared-but-empty RAXOL_SHARE_SECRET is "" (truthy), which would sign
    # and verify with an empty HMAC key anyone can compute. Treat blank (and
    # whitespace-only) as unconfigured so verify/1 fails closed on nil.
    defp blank_to_nil(value) when is_binary(value) do
      case String.trim(value) do
        "" -> nil
        _ -> value
      end
    end

    defp blank_to_nil(_value), do: nil
  end
end
