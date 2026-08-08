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
    """

    use Phoenix.LiveView

    alias Raxol.Agent.Code.Replay
    alias Raxol.Agent.Code.ShareToken
    alias Raxol.Agent.Journal.FileStore
    alias Raxol.Agent.Reattach

    @impl true
    def mount(params, _session, socket) do
      token = Map.get(params, "token", "")

      case verify(token) do
        {:ok, session_id} ->
          {:ok, open_session(socket, session_id)}

        {:error, :expired} ->
          {:ok, closed(socket, "this share link has expired")}

        {:error, _invalid} ->
          {:ok, closed(socket, "invalid share link")}
      end
    end

    @impl true
    def handle_info({:reattach_live, _session_id, record}, socket) do
      records = socket.assigns.records ++ [record]

      {:noreply,
       assign(socket, records: records, transcript: transcript(records))}
    end

    def handle_info(_message, socket), do: {:noreply, socket}

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

    defp open_session(socket, session_id) do
      if session_exists?(session_id) do
        socket = assign(socket, session_id: session_id, error: nil)

        # The tailer only starts on the CONNECTED mount; the static render
        # shows the replayed history without spawning a follower per crawl.
        if connected?(socket) do
          attach_live(socket, session_id)
        else
          records = read_history(session_id)
          assign(socket, records: records, transcript: transcript(records))
        end
      else
        # A valid token whose session this host cannot resolve (e.g. a tenant
        # journal under a per-tenant base ShareLive does not address). Fail
        # loud rather than render a blank transcript that reads as an empty
        # but healthy session.
        closed(socket, "session unavailable")
      end
    end

    defp session_exists?(session_id) do
      File.dir?(FileStore.session_dir(session_id))
    end

    defp attach_live(socket, session_id) do
      watermark = FileStore.high_watermark(session_id)

      case Reattach.attach(session_id, watermark + 1, {:from_offset, 1}) do
        {:ok, %{history: records}} ->
          assign(socket, records: records, transcript: transcript(records))

        {:error, reason} ->
          closed(socket, "session unavailable (#{inspect(reason)})")
      end
    end

    defp read_history(session_id) do
      case FileStore.read_records(session_id) do
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
