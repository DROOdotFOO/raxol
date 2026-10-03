defmodule Raxol.Broker.CredentialStore do
  @moduledoc """
  The brokerage credential at rest: one AES-256-GCM envelope in a file only
  this account can read, with the key held elsewhere
  (`Raxol.Broker.KeyProvider`).

  ## Envelope

  JSON `{"v": 1, "nonce": b64, "ct": b64, "tag": b64}`. The nonce is 96
  random bits drawn per write. The additional authenticated data binds the
  version and the file's purpose, so an envelope cannot be relabelled to
  another version or reused for another secret. The plaintext is
  `Raxol.Agent.Auth.Credential.dump/1` as JSON; it exists only in memory.

  ## File

  Default `~/.raxol/broker/robinhood.credential` (`$RAXOL_BROKER_CREDENTIAL`
  overrides; `:path` overrides both). The directory is created 0700 and must
  be owned by this account with no group or other write.

  A write creates an exclusive staging file in the same directory, sets it
  0600 while it is still empty, writes and fsyncs it, renames it over the
  target and fsyncs the directory. A symlink (or anything not a regular file)
  at the target is refused rather than followed or replaced.

  A read requires a regular file (checked with `lstat`, so a symlink is
  refused), owned by this account, with no group or other permission bits,
  at most #{64 * 1024} bytes, and the same inode once opened. A truncated,
  malformed or tampered file is `{:error, :corrupt_store}`; nothing here
  raises with file contents, and nothing deletes or rewrites a damaged file.
  """

  import Bitwise

  alias Raxol.Agent.Auth.Credential
  alias Raxol.Agent.OperatorFile
  alias Raxol.Broker.KeyProvider

  @version 1
  @purpose "raxol_broker:robinhood:credential"
  @max_bytes 64 * 1024
  @nonce_bytes 12
  @tag_bytes 16

  @doc "The credential file path for `opts`, or nil without a home or override."
  @spec path(keyword()) :: String.t() | nil
  def path(opts \\ []) do
    Keyword.get_lazy(opts, :path, fn ->
      OperatorFile.path("RAXOL_BROKER_CREDENTIAL", "broker/robinhood.credential")
    end)
  end

  @doc """
  Encrypt and atomically write `credential`. Options: `:path`,
  `:key_provider` (`{module, opts}`).
  """
  @spec put(Credential.t(), keyword()) :: :ok | {:error, term()}
  def put(%Credential{} = credential, opts \\ []) do
    with {:ok, file} <- require_path(opts),
         {:ok, key} <- write_key(opts),
         {:ok, plaintext} <- Jason.encode(Credential.dump(credential)),
         envelope = seal(plaintext, key),
         :ok <- ensure_dir(Path.dirname(file)),
         :ok <- refuse_unsafe_target(file) do
      publish(file, envelope)
    end
  end

  @doc """
  Read and decrypt the stored credential. `{:error, :not_found}` when there
  is none, `{:error, :key_missing}` when the key store holds no key.
  """
  @spec fetch(keyword()) :: {:ok, Credential.t()} | {:error, term()}
  def fetch(opts \\ []) do
    with {:ok, file} <- require_path(opts),
         {:ok, raw} <- read_trusted(file),
         {:ok, key} <- read_key(opts),
         {:ok, plaintext} <- open(raw, key) do
      decode_credential(plaintext)
    end
  end

  defp require_path(opts) do
    case path(opts) do
      nil -> {:error, :no_home}
      file -> {:ok, file}
    end
  end

  defp write_key(opts) do
    with {:ok, {module, provider_opts}} <- KeyProvider.resolve(opts) do
      case module.load_key(provider_opts) do
        {:ok, key} -> {:ok, key}
        :none -> module.create_key(provider_opts)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp read_key(opts) do
    with {:ok, {module, provider_opts}} <- KeyProvider.resolve(opts) do
      case module.load_key(provider_opts) do
        {:ok, key} -> {:ok, key}
        :none -> {:error, :key_missing}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # -- envelope ---------------------------------------------------------------

  defp aad(version), do: "raxol_broker.credential|v#{version}|" <> @purpose

  defp seal(plaintext, <<_::256>> = key) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ct, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        plaintext,
        aad(@version),
        @tag_bytes,
        true
      )

    Jason.encode!(%{
      "v" => @version,
      "nonce" => Base.encode64(nonce),
      "ct" => Base.encode64(ct),
      "tag" => Base.encode64(tag)
    })
  end

  # Every size is checked before `:crypto` sees it: a badarg from the NIF
  # would put the key in the stack frame of the exception.
  defp open(raw, <<_::256>> = key) do
    case Jason.decode(raw) do
      {:ok, %{"v" => @version, "nonce" => nonce, "ct" => ct, "tag" => tag}} ->
        decrypt(decode64(nonce), decode64(ct), decode64(tag), key)

      {:ok, %{"v" => version}} when is_integer(version) and version != @version ->
        {:error, {:unsupported_version, version}}

      _malformed ->
        {:error, :corrupt_store}
    end
  end

  defp decrypt({:ok, <<_::96>> = nonce}, {:ok, ct}, {:ok, <<_::128>> = tag}, key) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ct, aad(@version), tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :corrupt_store}
    end
  end

  defp decrypt(_nonce, _ct, _tag, _key), do: {:error, :corrupt_store}

  defp decode64(value) when is_binary(value), do: Base.decode64(value)
  defp decode64(_value), do: :error

  defp decode_credential(plaintext) do
    with {:ok, map} <- Jason.decode(plaintext),
         {:ok, credential} <- Credential.load(map) do
      {:ok, credential}
    else
      _invalid -> {:error, :corrupt_store}
    end
  end

  # -- reading ----------------------------------------------------------------

  defp read_trusted(file) do
    case File.lstat(file) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:untrusted_file, :symlink}}
      {:ok, %File.Stat{type: :regular} = stat} -> read_regular(file, stat)
      {:ok, %File.Stat{}} -> {:error, {:untrusted_file, :not_regular}}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp read_regular(file, lstat) do
    with :ok <- vet_file(lstat),
         {:ok, io} <- open_raw(file) do
      try do
        read_same_file(io, lstat)
      after
        :file.close(io)
      end
    end
  end

  # The open follows a symlink planted between lstat and open; comparing the
  # opened file's inode with the lstat'd one catches that swap.
  defp read_same_file(io, lstat) do
    with {:ok, opened} <- opened_stat(io),
         :ok <- same_file(opened, lstat),
         :ok <- vet_file(opened) do
      read_all(io, opened.size)
    end
  end

  defp opened_stat(io) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp same_file(%File.Stat{inode: inode, major_device: dev}, %File.Stat{
         inode: inode,
         major_device: dev
       }),
       do: :ok

  defp same_file(_opened, _lstat), do: {:error, {:untrusted_file, :replaced}}

  defp open_raw(file) do
    case :file.open(file, [:read, :raw, :binary]) do
      {:ok, io} -> {:ok, io}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp read_all(_io, 0), do: {:error, :corrupt_store}

  defp read_all(io, size) do
    case :file.read(io, size) do
      {:ok, data} when byte_size(data) == size -> {:ok, data}
      _short -> {:error, :corrupt_store}
    end
  end

  defp vet_file(%File.Stat{} = stat) do
    cond do
      not owned?(stat) -> {:error, {:untrusted_file, :owner}}
      (stat.mode &&& 0o077) != 0 -> {:error, {:untrusted_file, :mode}}
      stat.size > @max_bytes -> {:error, :corrupt_store}
      true -> :ok
    end
  end

  defp owned?(stat) do
    case OperatorFile.uid() do
      :unknown -> true
      uid -> stat.uid == uid
    end
  end

  # -- writing ----------------------------------------------------------------

  defp ensure_dir(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        vet_dir(stat)

      {:ok, %File.Stat{}} ->
        {:error, {:untrusted_dir, :not_directory}}

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(dir),
             :ok <- File.chmod(dir, 0o700),
             {:ok, stat} <- File.lstat(dir) do
          vet_dir(stat)
        end

      {:error, reason} ->
        {:error, {:untrusted_dir, reason}}
    end
  end

  defp vet_dir(stat) do
    cond do
      not owned?(stat) -> {:error, {:untrusted_dir, :owner}}
      (stat.mode &&& 0o022) != 0 -> {:error, {:untrusted_dir, :mode}}
      true -> :ok
    end
  end

  defp refuse_unsafe_target(file) do
    case File.lstat(file) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:untrusted_file, :symlink}}
      {:ok, %File.Stat{}} -> {:error, {:untrusted_file, :not_regular}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp publish(file, envelope) do
    dir = Path.dirname(file)
    staging = Path.join(dir, ".#{Path.basename(file)}.#{System.unique_integer([:positive])}.tmp")

    # `:exclusive` is O_EXCL: a pre-planted file or symlink at the staging
    # name fails the open instead of receiving the envelope.
    result =
      with {:ok, io} <- :file.open(staging, [:write, :exclusive, :binary, :raw]) do
        written =
          with :ok <- File.chmod(staging, 0o600),
               :ok <- :file.write(io, envelope),
               do: :file.sync(io)

        :file.close(io)

        with :ok <- written,
             :ok <- :file.rename(staging, file) do
          sync_dir(dir)
        end
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(staging)
        {:error, {:write_failed, reason}}
    end
  end

  defp sync_dir(dir) do
    case :file.open(dir, [:read, :raw]) do
      {:ok, io} ->
        _ = :file.sync(io)
        :file.close(io)

      {:error, _unsupported} ->
        :ok
    end
  end
end
