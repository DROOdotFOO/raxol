defmodule Mix.Tasks.Raxol.Broker.Init do
  @moduledoc """
  Creates `broker.policy.exs` with explicit notional caps.

      mix raxol.broker.init --max-notional 1000 --daily-cap 5000

  When either flag is omitted, the task prompts only from an interactive
  terminal. It validates the complete restrictive policy, refuses an unsafe
  destination directory or existing destination, and publishes the file with
  mode 0600.
  """

  use Mix.Task

  alias Raxol.Agent.OperatorFile
  alias Raxol.Broker.PolicyFile

  @shortdoc "Creates a fail-closed broker.policy.exs"
  @switches [max_notional: :string, daily_cap: :string]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("usage: mix raxol.broker.init [--max-notional AMOUNT --daily-cap AMOUNT]")
    end

    max_notional = cap(opts, :max_notional, "Maximum notional per order")
    daily_cap = cap(opts, :daily_cap, "Daily notional cap")

    case PolicyFile.new(max_notional, daily_cap) do
      {:ok, policy} -> write_policy(policy)
      {:error, reason} -> Mix.raise("invalid broker policy: #{inspect(reason)}")
    end
  end

  defp cap(opts, key, prompt) do
    case Keyword.get(opts, key) do
      nil -> prompt_cap(key, prompt)
      value -> parse_cap(key, value)
    end
  end

  defp prompt_cap(key, prompt) do
    if interactive?() do
      case Mix.shell().prompt("#{prompt} (required):") do
        value when is_binary(value) ->
          parse_cap(key, String.trim(value))

        _other ->
          Mix.raise("#{flag(key)} prompt ended before an answer; no policy file was written")
      end
    else
      Mix.raise("#{flag(key)} is required; no policy file was written")
    end
  end

  defp interactive? do
    case Mix.shell() do
      Mix.Shell.Process -> true
      Mix.Shell.IO -> match?({:ok, _}, :io.columns())
      _other -> false
    end
  end

  defp parse_cap(key, value) do
    case Decimal.parse(value) do
      {%Decimal{} = amount, ""} -> amount
      _ -> Mix.raise("#{flag(key)} must be a positive decimal; no policy file was written")
    end
  end

  defp flag(:max_notional), do: "--max-notional"
  defp flag(:daily_cap), do: "--daily-cap"

  defp write_policy(policy) do
    path = PolicyFile.filename()
    ensure_destination_available!(path)

    contents =
      policy
      |> Enum.map_join(",\n", fn {key, value} -> "  #{key}: #{render(value)}" end)
      |> then(&"[\n#{&1}\n]\n")

    stage_and_publish!(path, contents)
    Mix.shell().info("Wrote #{path}")
  end

  defp ensure_destination_available!(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> Mix.raise("refusing to overwrite #{path}")
      {:error, reason} -> Mix.raise("could not inspect #{path}: #{:file.format_error(reason)}")
    end
  end

  defp stage_and_publish!(path, contents) do
    staging_path = staging_path(path)

    case File.open(staging_path, [:write, :binary, :exclusive]) do
      {:ok, device} ->
        try do
          try do
            secure_staging!(staging_path)
            write_and_sync!(device, staging_path, contents)
          after
            close_staging!(device, staging_path)
          end

          ensure_trusted_staging!(staging_path)

          publish!(staging_path, path)
        after
          remove_staging!(staging_path)
        end

      {:error, reason} ->
        Mix.raise("could not create staging file for #{path}: #{:file.format_error(reason)}")
    end
  end

  defp staging_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.#{suffix}.tmp")
  end

  defp secure_staging!(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("could not secure #{path}: #{:file.format_error(reason)}")
    end
  end

  defp ensure_trusted_staging!(path) do
    case OperatorFile.trusted?(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("refusing to publish untrusted staging file #{path}: #{inspect(reason)}")
    end
  end

  defp write_and_sync!(device, path, contents) do
    case :file.write(device, contents) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("could not write #{path}: #{:file.format_error(reason)}")
    end

    case :file.sync(device) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("could not sync #{path}: #{:file.format_error(reason)}")
    end
  end

  defp close_staging!(device, path) do
    case File.close(device) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("could not close #{path}: #{:file.format_error(reason)}")
    end
  end

  defp publish!(staging_path, path) do
    case File.ln(staging_path, path) do
      :ok -> :ok
      {:error, :eexist} -> Mix.raise("refusing to overwrite #{path}")
      {:error, reason} -> Mix.raise("could not publish #{path}: #{:file.format_error(reason)}")
    end
  end

  defp remove_staging!(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Mix.raise("could not remove #{path}: #{:file.format_error(reason)}")
    end
  end

  defp render(%Decimal{} = value), do: ~s|Decimal.new("#{Decimal.to_string(value)}")|
  defp render(value), do: inspect(value)
end
