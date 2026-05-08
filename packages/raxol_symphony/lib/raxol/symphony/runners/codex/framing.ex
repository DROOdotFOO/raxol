defmodule Raxol.Symphony.Runners.Codex.Framing do
  @moduledoc """
  Stdio framing helpers for the Codex app-server JSON-RPC stream.

  Codex emits newline-delimited JSON over stdout. Ports opened with
  `line: <bytes>` deliver stdout as `{:data, {:eol, chunk}}` /
  `{:data, {:noeol, chunk}}` messages. This module is the pure helper that
  turns those into complete decoded JSON payloads.
  """

  @type chunk :: {:eol, binary()} | {:noeol, binary()}

  @doc """
  Pushes a port chunk into a pending buffer.

  Returns `{:line, completed_line, new_buffer}` when a line completes (the
  buffer resets to empty), or `{:partial, new_buffer}` when more bytes are
  required.
  """
  @spec push(binary(), chunk()) :: {:line, binary(), binary()} | {:partial, binary()}
  def push(buffer, {:eol, chunk}) when is_binary(buffer) and is_binary(chunk),
    do: {:line, buffer <> chunk, ""}

  def push(buffer, {:noeol, chunk}) when is_binary(buffer) and is_binary(chunk),
    do: {:partial, buffer <> chunk}

  @doc """
  Decodes a single JSON line.

  Returns `{:ok, payload}` on success, `{:ok, :empty}` for whitespace-only
  lines (callers should skip these), or `{:error, reason}` on JSON failure.
  """
  @spec decode(binary()) :: {:ok, map() | list() | :empty} | {:error, term()}
  def decode(line) when is_binary(line) do
    case String.trim(line) do
      "" -> {:ok, :empty}
      trimmed -> Jason.decode(trimmed)
    end
  end

  @doc """
  Encodes a payload as JSON terminated with a newline, suitable for
  `Port.command/2`.
  """
  @spec encode!(term()) :: binary()
  def encode!(payload), do: Jason.encode!(payload) <> "\n"
end
