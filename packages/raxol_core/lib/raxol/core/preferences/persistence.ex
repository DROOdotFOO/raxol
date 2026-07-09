defmodule Raxol.Core.Preferences.Persistence do
  @moduledoc """
  Handles persistence (loading/saving) of user preferences to a file.
  """


  @default_filename "user_preferences.bin"

  @doc """
  Returns the full path to the user preferences file.
  Uses an application-specific directory.
  """
  def preferences_path do
    # Using :user_config dir for user-specific, potentially hidden config
    config_dir = :filename.basedir(:user_config, "raxol")
    # Ensure the directory exists
    File.mkdir_p!(config_dir)
    Path.join(config_dir, @default_filename)
  end

  @doc """
  Loads user preferences from the designated file.

  Returns:
    - `{:ok, preferences_map}` if successful.
    - `{:error, :file_not_found}` if the file doesn't exist.
    - `{:error, reason}` for other file or decoding errors.
  """
  def load do
    path = preferences_path()

    case File.read(path) do
      {:ok, binary_data} ->
        case Raxol.Core.ErrorHandling.safe_deserialize(binary_data) do
          {:ok, preferences} when is_map(preferences) ->
            {:ok, preferences}

          {:ok, _} ->
            Raxol.Core.Runtime.Log.error("Preferences file content is not a map: #{path}")

            {:error, :invalid_format}

          {:error, _} ->
            Raxol.Core.Runtime.Log.error("Failed to decode preferences file #{path}")

            {:error, :decoding_failed}
        end

      {:error, :enoent} ->
        {:error, :file_not_found}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error("Failed to read preferences file #{path}: #{reason}")

        {:error, reason}
    end
  end

  @doc """
  Saves the given preferences map to the designated file.

  Serializes the map using `:erlang.term_to_binary`.

  Returns:
    - `:ok` on success.
    - `{:error, reason}` on failure.
  """
  def save(preferences) when is_map(preferences) do
    path = preferences_path()

    case Raxol.Core.ErrorHandling.safe_write_term(path, preferences) do
      {:ok, :ok} ->
        :ok

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error("Failed to save preferences to #{path}: #{inspect(reason)}")

        {:error, reason}
    end
  end
end
