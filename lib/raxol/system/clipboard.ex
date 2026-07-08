defmodule Raxol.System.Clipboard do
  @moduledoc """
  Provides consolidated access to the system clipboard across different operating systems.

  Handles interactions with platform-specific clipboard utilities like `pbcopy`/`pbpaste` (macOS),
  `xclip` (Linux/X11), and `clip`/`powershell Get-Clipboard` (Windows).

  Requires `xclip` to be installed on Linux systems using X11.
  Wayland clipboard access might require different utilities not currently handled.
  """

  @behaviour Raxol.Core.Clipboard.Behaviour

  alias Raxol.System.PortCommand

  @doc """
  Copies the given text to the system clipboard.
  """
  @impl Raxol.Core.Clipboard.Behaviour
  @spec copy(String.t()) ::
          :ok | {:error, :command_not_found | {atom(), String.t()}}
  def copy(text) when is_binary(text) do
    case :os.type() do
      {:unix, :darwin} -> copy_macos(text)
      {:unix, _} -> copy_linux(text)
      {:win32, _} -> copy_windows(text)
    end
  end

  @spec copy_macos(String.t()) :: :ok | {:error, {:pbcopy_failed, String.t()}}
  defp copy_macos(text) do
    case PortCommand.run("pbcopy", [], text) do
      {:ok, _output} ->
        :ok

      {:error, output} ->
        Raxol.Core.Runtime.Log.error("Failed to copy using pbcopy: #{output}")
        {:error, {:pbcopy_failed, output}}
    end
  end

  @spec copy_linux(String.t()) ::
          :ok | {:error, :command_not_found | {:xclip_failed, String.t()}}
  defp copy_linux(text) do
    case System.find_executable("xclip") do
      nil ->
        Raxol.Core.Runtime.Log.error(
          "Clipboard error: `xclip` command not found. Please install it for clipboard support."
        )

        {:error, :command_not_found}

      _ ->
        copy_with_xclip(text)
    end
  end

  @spec copy_with_xclip(String.t()) ::
          :ok | {:error, {:xclip_failed, String.t()}}
  defp copy_with_xclip(text) do
    case PortCommand.run("xclip", ["-selection", "clipboard"], text) do
      {:ok, _output} ->
        :ok

      {:error, output} ->
        Raxol.Core.Runtime.Log.error("Failed to copy using xclip: #{output}")
        {:error, {:xclip_failed, output}}
    end
  end

  @spec copy_windows(String.t()) :: :ok | {:error, {:clip_failed, String.t()}}
  defp copy_windows(text) do
    case PortCommand.run("clip", [], text) do
      {:ok, _output} ->
        :ok

      {:error, output} ->
        Raxol.Core.Runtime.Log.error("Failed to copy using clip: #{output}")
        {:error, {:clip_failed, output}}
    end
  end

  @doc """
  Retrieves text from the system clipboard.

  Returns `{:ok, text}` on success, or `{:error, reason}` on failure.
  An empty clipboard is considered success and returns `{:ok, ""}`.
  """
  @impl Raxol.Core.Clipboard.Behaviour
  @spec paste() ::
          {:ok, String.t()}
          | {:error, :command_not_found | {atom(), String.t()}}
  def paste do
    case :os.type() do
      {:unix, :darwin} -> paste_macos()
      {:unix, _} -> paste_linux()
      {:win32, _} -> paste_windows()
    end
  end

  @spec paste_macos() ::
          {:ok, String.t()} | {:error, {:pbpaste_failed, String.t()}}
  defp paste_macos do
    case System.cmd("pbpaste", [], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, exit_code} ->
        Raxol.Core.Runtime.Log.error(
          "Failed to paste using pbpaste. Exit code: #{exit_code}, Output: #{output}"
        )

        {:error, {:pbpaste_failed, output}}
    end
  end

  @spec paste_linux() ::
          {:ok, String.t()}
          | {:error, :command_not_found | {:xclip_failed, String.t()}}
  defp paste_linux do
    case System.find_executable("xclip") do
      nil ->
        Raxol.Core.Runtime.Log.error(
          "Clipboard error: `xclip` command not found. Please install it for clipboard support."
        )

        {:error, :command_not_found}

      _ ->
        paste_with_xclip()
    end
  end

  @spec paste_with_xclip() ::
          {:ok, String.t()} | {:error, {:xclip_failed, String.t()}}
  defp paste_with_xclip do
    case System.cmd("xclip", ["-selection", "clipboard", "-o"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, output}

      {output, exit_code} ->
        case {exit_code, String.trim(output)} do
          {1, ""} ->
            {:ok, ""}

          _ ->
            Raxol.Core.Runtime.Log.error(
              "Failed to paste using xclip. Exit code: #{exit_code}, Output: #{output}"
            )

            {:error, {:xclip_failed, output}}
        end
    end
  end

  @spec paste_windows() ::
          {:ok, String.t()}
          | {:error, {:powershell_get_clipboard_failed, String.t()}}
  defp paste_windows do
    case System.cmd("powershell", ["-noprofile", "-command", "Get-Clipboard"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, String.trim_trailing(output, "\r\n")}

      {output, exit_code} ->
        case String.contains?(output, [
               "Cannot retrieve the Clipboard.",
               "Get-Clipboard: Failed to get clipboard content"
             ]) do
          true ->
            Raxol.Core.Runtime.Log.debug(
              "Clipboard appears empty or inaccessible via PowerShell."
            )

            {:ok, ""}

          false ->
            Raxol.Core.Runtime.Log.error(
              "Failed to paste using PowerShell. Exit code: #{exit_code}, Output: #{output}"
            )

            {:error, {:powershell_get_clipboard_failed, output}}
        end
    end
  end
end
