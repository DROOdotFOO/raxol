defmodule Raxol.Agent.OMP.RPC.Codec do
  @moduledoc """
  Pure codec for the `omp --mode rpc` JSON-lines protocol (ADR-0042).

  OMP prints one JSON object per line: a ready frame first, then command
  responses `{id, type: "response", command, success, data?, error?, code?}`
  and every other frame (session events, `extension_ui_request`,
  `prompt_result`, `session_settled`, ...). After `negotiate_protocol` v2 a
  frame over `maxFrameBytes` arrives as an uninterrupted run of `rpc_chunk`
  lines, each a base64 segment of the frame's UTF-8 JSON; `decode_line/2`
  reassembles them.

  Errors name a reason or OMP's machine-readable `code`, never a frame's
  text: OMP error messages quote paths and request content.
  """

  # OMP's ceiling for a reassembled frame (`maxReassembledFrameBytes`).
  @max_reassembled_bytes 67_108_864
  # The most this client buffers for one physical line, whatever the ready
  # frame claims: 8x the 1 MiB `maxFrameBytes` that omp 18.13.0 sends.
  @max_frame_bytes 8_388_608
  # OMP's machine-readable error codes (`session_busy`, `stale_cursor`, ...).
  @code ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @protocol 2

  # Inbound frames that are not commands: OMP never answers them, so a
  # request for one would only wait out its deadline.
  @not_commands ~w(extension_ui_response host_tool_update host_tool_result host_uri_result)

  # `extension_ui_request` methods that wait for an answer. Everything else
  # (`notify`, `setStatus`, `setWidget`, `setTitle`, `set_editor_text`,
  # `open_url`, `cancel`) is fire-and-forget.
  @dialogs ~w(select confirm input editor ask)

  @typedoc "Transport limits from the ready frame."
  @type limits :: %{max_frame_bytes: pos_integer(), max_reassembled_bytes: pos_integer()}

  @typedoc "A command from `encode_command/1`, without its `id` and leading brace."
  @type encoded :: binary()

  @typedoc "Chunk reassembly state; start one with `decoder/1`."
  @type decoder :: %{limit: pos_integer(), chunk: nil | map()}

  @typedoc "Why a line or chunk run was dropped."
  @type decode_error ::
          :invalid_frame
          | :invalid_chunk
          | :chunk_interrupted
          | :chunk_too_large
          | :chunk_length_mismatch
          | :chunk_not_utf8

  @typedoc "What an `extension_ui_request` needs: an approval, any other dialog, or nothing."
  @type ui_request :: {:approval, String.t(), [String.t()]} | {:dialog, String.t()} | :none

  @doc "The protocol version this client negotiates."
  @spec protocol() :: pos_integer()
  def protocol, do: @protocol

  @doc """
  Check the ready frame: `{:ok, limits}` when it offers protocol v2, else
  `{:error, :unsupported_protocol}` or `{:error, :invalid_ready_frame}`. The
  physical frame limit is capped at 8 MiB (omp 18.13.0 sends 1 MiB) and the
  reassembly limit at OMP's own 64 MiB, so a ready frame cannot make the
  client buffer more.
  """
  @spec ready(map()) :: {:ok, limits()} | {:error, :invalid_ready_frame | :unsupported_protocol}
  def ready(%{
        "type" => "ready",
        "supportedProtocolVersions" => versions,
        "maxFrameBytes" => max_frame,
        "maxReassembledFrameBytes" => max_reassembled
      })
      when is_list(versions) and is_integer(max_frame) and max_frame > 0 and
             is_integer(max_reassembled) and max_reassembled > 0 do
    if @protocol in versions do
      {:ok,
       %{
         max_frame_bytes: min(max_frame, @max_frame_bytes),
         max_reassembled_bytes: min(max_reassembled, @max_reassembled_bytes)
       }}
    else
      {:error, :unsupported_protocol}
    end
  end

  def ready(_frame), do: {:error, :invalid_ready_frame}

  @doc """
  Encode a command, all but its `id`: `{:ok, type, encoded}` for `frame/2`.

  `command` is a map with a string `type` (string or atom keys). Refused,
  naming only the reason: no usable `type` (`:type`), a caller-supplied `id`
  (`:id`; the client assigns ids), a frame OMP never answers
  (`:not_a_command`), or a value that cannot be JSON (the exception
  module). The caller encodes, so a command OMP can never receive fails its
  own request and never the process every request shares.
  """
  @spec encode_command(term()) ::
          {:ok, String.t(), encoded()} | {:error, {:invalid_request, atom()}}
  def encode_command(command) when is_map(command) do
    with {:ok, type} <- command_type(command),
         :ok <- refuse_id(command) do
      case Jason.encode(command) do
        {:ok, "{" <> encoded} -> {:ok, type, encoded}
        {:error, %module{}} -> {:error, {:invalid_request, module}}
      end
    end
  end

  def encode_command(_command), do: {:error, {:invalid_request, :command}}

  defp command_type(command) do
    case {Map.fetch(command, "type"), Map.fetch(command, :type)} do
      {{:ok, type}, :error} -> check_type(type)
      {:error, {:ok, type}} -> check_type(type)
      _ -> {:error, {:invalid_request, :type}}
    end
  end

  defp check_type(type) when type in @not_commands,
    do: {:error, {:invalid_request, :not_a_command}}

  defp check_type(type) when is_binary(type) and type != "", do: {:ok, type}
  defp check_type(_type), do: {:error, {:invalid_request, :type}}

  defp refuse_id(command) do
    if Map.has_key?(command, "id") or Map.has_key?(command, :id),
      do: {:error, {:invalid_request, :id}},
      else: :ok
  end

  @doc "The newline-terminated line for an encoded command, with its string `id` spliced in."
  @spec frame(String.t(), encoded()) :: iodata()
  def frame(id, encoded) when is_binary(id), do: [~s({"id":), Jason.encode!(id), ?,, encoded, ?\n]

  @doc "The `negotiate_protocol` command for `protocol/0`, encoded."
  @spec negotiate() :: encoded()
  def negotiate do
    {:ok, _type, encoded} =
      encode_command(%{"type" => "negotiate_protocol", "protocolVersion" => @protocol})

    encoded
  end

  @doc """
  A response as a call result: `{:ok, data}` (nil when OMP sent none), or
  `{:error, {:rpc_error, code}}` with OMP's machine-readable `code` (nil when
  absent or not a lowercase snake_case token), never its error text or any
  other field of the response.
  """
  @spec result(map()) :: {:ok, term()} | {:error, {:rpc_error, String.t() | nil}}
  def result(%{"success" => true} = response), do: {:ok, Map.get(response, "data")}

  def result(response) do
    code = response["code"]
    {:error, {:rpc_error, if(is_binary(code) and Regex.match?(@code, code), do: code)}}
  end

  @doc """
  Classify an `extension_ui_request`: `{:approval, id, options}` for a tool
  approval select, `{:dialog, id}` for any other dialog that waits for an
  answer, `:none` for presentation frames and anything else.

  OMP marks no approval as such on the wire. Its approval select always
  offers `"Approve"` (`"Approve Once"` when grants are listed) and ends with
  `"Deny"`, optionally with `"Approve <tool> for this session"` between.

  `options` are the ones a principal may pick. A grant OMP would persist
  beyond this session (its `alwaysLabel`: `"Always Approve"`, `"Always
  Approve File"`, `"Always Approve Directory: <dir>"`) is withheld, so no
  answer can grant it.
  """
  @spec ui_request(map()) :: ui_request()
  def ui_request(%{
        "type" => "extension_ui_request",
        "id" => id,
        "method" => "select",
        "options" => options
      })
      when is_binary(id) and is_list(options) do
    if approval_options?(options),
      do: {:approval, id, Enum.reject(options, &persistent_grant?/1)},
      else: {:dialog, id}
  end

  def ui_request(%{"type" => "extension_ui_request", "id" => id, "method" => method})
      when is_binary(id) and method in @dialogs,
      do: {:dialog, id}

  def ui_request(_frame), do: :none

  defp approval_options?(options) do
    List.last(options) == "Deny" and Enum.any?(options, &(&1 in ["Approve", "Approve Once"]))
  end

  defp persistent_grant?(option),
    do: is_binary(option) and String.starts_with?(option, "Always Approve")

  @doc "The answer that denies an approval."
  @spec deny() :: String.t()
  def deny, do: "Deny"

  @doc "The line answering dialog `id` with the option `value`."
  @spec ui_answer(String.t(), String.t()) :: iodata()
  def ui_answer(id, value),
    do: [Jason.encode!(%{"type" => "extension_ui_response", "id" => id, "value" => value}), ?\n]

  @doc "The line cancelling dialog `id`."
  @spec ui_cancel(String.t()) :: iodata()
  def ui_cancel(id),
    do: [
      Jason.encode!(%{"type" => "extension_ui_response", "id" => id, "cancelled" => true}),
      ?\n
    ]

  @doc "A decoder that reassembles chunk runs of at most `limit` bytes."
  @spec decoder(pos_integer()) :: decoder()
  def decoder(limit), do: %{limit: limit, chunk: nil}

  @doc """
  Decode one stdout line: `{:ok, frame, decoder}` for a whole frame (a
  plain line, or the last chunk of a run), `{:more, decoder}` inside a chunk
  run, or `{:error, reason, decoder}`.

  A line that is not a JSON object is `:invalid_frame`. A chunk run must
  start at index 0 and continue with the same `chunkId`, `count` and
  `byteLength` at the next index; any other line in between drops the run
  and itself (`:chunk_interrupted`). A run may not claim more chunks than
  `byteLength + 1` (`:invalid_chunk`), so empty chunks cannot grow it
  without bound. The run's bytes must equal `byteLength`
  (`:chunk_length_mismatch`), stay within the limit (`:chunk_too_large`),
  be valid base64 (`:invalid_chunk`), strict UTF-8 (`:chunk_not_utf8`) and
  one JSON object (`:invalid_frame`).
  """
  @spec decode_line(decoder(), binary()) ::
          {:ok, map(), decoder()} | {:more, decoder()} | {:error, decode_error(), decoder()}
  def decode_line(decoder, line) do
    case {Jason.decode(line), decoder.chunk} do
      {{:ok, %{"type" => "rpc_chunk"} = chunk}, run} -> chunk(decoder, run, chunk)
      {{:ok, %{}}, %{}} -> {:error, :chunk_interrupted, reset(decoder)}
      {{:ok, %{} = frame}, nil} -> {:ok, frame, decoder}
      {_other, _run} -> {:error, :invalid_frame, reset(decoder)}
    end
  end

  defp reset(decoder), do: %{decoder | chunk: nil}

  defp chunk(decoder, nil, %{"index" => 0} = chunk) do
    with {:ok, run} <- start_run(chunk, decoder.limit),
         {:ok, data} <- chunk_data(chunk) do
      append(decoder, run, data)
    else
      {:error, reason} -> {:error, reason, reset(decoder)}
    end
  end

  defp chunk(decoder, nil, _chunk), do: {:error, :chunk_interrupted, decoder}

  defp chunk(decoder, run, chunk) do
    if same_run?(run, chunk) do
      case chunk_data(chunk) do
        {:ok, data} -> append(decoder, run, data)
        {:error, reason} -> {:error, reason, reset(decoder)}
      end
    else
      {:error, :chunk_interrupted, reset(decoder)}
    end
  end

  defp start_run(
         %{"chunkId" => id, "count" => count, "byteLength" => length},
         limit
       )
       when is_binary(id) and id != "" and is_integer(count) and count > 0 and
              is_integer(length) and length >= 0 and count <= length + 1 do
    if length > limit,
      do: {:error, :chunk_too_large},
      else: {:ok, %{id: id, count: count, length: length, next: 0, parts: [], size: 0}}
  end

  defp start_run(_chunk, _limit), do: {:error, :invalid_chunk}

  defp same_run?(run, chunk) do
    chunk["chunkId"] == run.id and chunk["index"] == run.next and chunk["count"] == run.count and
      chunk["byteLength"] == run.length
  end

  defp chunk_data(%{"data" => data}) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_chunk}
    end
  end

  defp chunk_data(_chunk), do: {:error, :invalid_chunk}

  defp append(decoder, run, data) do
    size = run.size + byte_size(data)
    run = %{run | parts: [run.parts | data], size: size, next: run.next + 1}

    cond do
      size > run.length -> {:error, :chunk_length_mismatch, reset(decoder)}
      run.next < run.count -> {:more, %{decoder | chunk: run}}
      size != run.length -> {:error, :chunk_length_mismatch, reset(decoder)}
      true -> finish(reset(decoder), IO.iodata_to_binary(run.parts))
    end
  end

  defp finish(decoder, bytes) do
    with true <- String.valid?(bytes),
         {:ok, %{} = frame} <- Jason.decode(bytes) do
      {:ok, frame, decoder}
    else
      false -> {:error, :chunk_not_utf8, decoder}
      _ -> {:error, :invalid_frame, decoder}
    end
  end
end
