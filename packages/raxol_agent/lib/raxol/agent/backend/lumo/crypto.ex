defmodule Raxol.Agent.Backend.Lumo.Crypto do
  @moduledoc """
  Cryptographic operations for Proton Lumo's U2L (User-to-LLM) encryption.

  Handles:
  - AES-256-GCM encryption/decryption with Associated Data (AEAD)
  - PGP encryption of the per-request AES key to Lumo's public key (via gpg)

  The protocol: each request generates a fresh AES-256-GCM key. Message turns
  are encrypted with this key using AD string `lumo.request.{id}.turn`.
  The key itself is PGP-encrypted to Lumo's ECDH public key. Response chunks
  arrive encrypted and are decrypted with the same key using AD string
  `lumo.response.{id}.chunk`.
  """

  @aes_key_length 32
  @iv_length 12
  @tag_length 16

  # Proton Lumo production PGP public key (ECDH Curve25519)
  # Fingerprint: F032A1169DDFF8EDA728E59A9A74C3EF61514A2A
  # Subkey (encryption): DA656791F790D0A297C79CCEE7DF128A8FC5DE04
  @lumo_pub_key """
  -----BEGIN PGP PUBLIC KEY BLOCK-----

  xjMEaA9k7RYJKwYBBAHaRw8BAQdABaPA24xROahXs66iuekwPmdOpJbPE1a8A69r
  siWP8rfNL1Byb3RvbiBMdW1vIChQcm9kIEtleSAwMDAyKSA8c3VwcG9ydEBwcm90
  b24ubWU+wpkEExYKAEEWIQTwMqEWnd/47aco5ZqadMPvYVFKKgUCaA9k7QIbAwUJ
  B4TOAAULCQgHAgIiAgYVCgkICwIEFgIDAQIeBwIXgAAKCRCadMPvYVFKKqiVAQD7
  JNeudEXTaNMoQMkYjcutNwNAalwbLr5qe6N5rPogDQD/bA5KBWmDlvxVz7If6SBS
  7Xzcvk8VMHYkBLKfh+bfUQzOOARoD2TtEgorBgEEAZdVAQUBAQdAnBIJoFt6Pxnp
  RAJMHwhdCXaE+lwQFbKgwb6LCUFWvHYDAQgHwn4EGBYKACYWIQTwMqEWnd/47aco
  5ZqadMPvYVFKKgUCaA9k7QIbDAUJB4TOAAAKCRCadMPvYVFKKkuRAQChUthLyAcc
  UD6UrJkroc6exHIMSR5Vlk4d4L8OeFUWWAEA3ugyE/b/pSQ4WO+fiTkHN2ZeKlyj
  dZMbxO6yWPA5uQk=
  =h/mc
  -----END PGP PUBLIC KEY BLOCK-----
  """

  @doc "Returns Lumo's production PGP public key."
  @spec lumo_pub_key() :: String.t()
  def lumo_pub_key, do: @lumo_pub_key

  @doc "Generate a random 32-byte AES-256-GCM key."
  @spec generate_request_key() :: binary()
  def generate_request_key do
    :crypto.strong_rand_bytes(@aes_key_length)
  end

  @doc "Generate a UUID v4 request ID."
  @spec generate_request_id() :: String.t()
  def generate_request_id do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<g1::binary-8, g2::binary-4, g3::binary-4, g4::binary-4, g5::binary-12>> =
        hex

      "#{g1}-#{g2}-#{g3}-#{g4}-#{g5}"
    end)
  end

  @doc """
  Encrypt plaintext with AES-256-GCM.

  Returns the concatenation of IV (12 bytes) + ciphertext + tag (16 bytes),
  base64-encoded.
  """
  @spec encrypt(binary(), <<_::256>>, binary() | nil) :: binary()
  def encrypt(plaintext, key, ad \\ nil)

  def encrypt(_plaintext, key, _ad) when byte_size(key) != @aes_key_length do
    raise ArgumentError,
          "expected 32-byte AES key, got #{byte_size(key)} bytes"
  end

  def encrypt(plaintext, key, ad) when byte_size(key) == @aes_key_length do
    iv = :crypto.strong_rand_bytes(@iv_length)
    aad = if ad, do: ad, else: <<>>

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        iv,
        plaintext,
        aad,
        @tag_length,
        true
      )

    Base.encode64(iv <> ciphertext <> tag)
  end

  @doc """
  Decrypt base64-encoded AES-256-GCM ciphertext.

  Expects the format: base64(IV || ciphertext || tag).
  """
  @spec decrypt(binary(), <<_::256>>, binary() | nil) ::
          {:ok, binary()} | {:error, :decryption_failed | :invalid_base64}
  def decrypt(encrypted_b64, key, ad \\ nil)

  def decrypt(_encrypted_b64, key, _ad)
      when byte_size(key) != @aes_key_length do
    raise ArgumentError,
          "expected 32-byte AES key, got #{byte_size(key)} bytes"
  end

  def decrypt(encrypted_b64, key, ad) when byte_size(key) == @aes_key_length do
    case Base.decode64(encrypted_b64) do
      {:ok, raw} ->
        <<iv::binary-size(@iv_length), rest::binary>> = raw
        ct_len = byte_size(rest) - @tag_length

        <<ciphertext::binary-size(^ct_len), tag::binary-size(@tag_length)>> =
          rest

        aad = if ad, do: ad, else: <<>>

        case :crypto.crypto_one_time_aead(
               :aes_256_gcm,
               key,
               iv,
               ciphertext,
               aad,
               tag,
               false
             ) do
          :error -> {:error, :decryption_failed}
          plaintext -> {:ok, plaintext}
        end

      :error ->
        {:error, :invalid_base64}
    end
  end

  @doc """
  Encrypt a turn's content for Lumo U2L.

  Uses AD string `lumo.request.{request_id}.turn`.
  """
  @spec encrypt_turn_content(binary(), binary(), String.t()) :: binary()
  def encrypt_turn_content(content, key, request_id) do
    ad = "lumo.request.#{request_id}.turn"
    encrypt(content, key, ad)
  end

  @doc """
  Decrypt a response chunk from Lumo.

  Uses AD string `lumo.response.{request_id}.chunk`.
  """
  @spec decrypt_chunk(binary(), binary(), String.t()) ::
          {:ok, binary()} | {:error, :decryption_failed}
  def decrypt_chunk(encrypted_b64, key, request_id) do
    ad = "lumo.response.#{request_id}.chunk"
    decrypt(encrypted_b64, key, ad)
  end

  @doc """
  Encrypt the AES request key to Lumo's PGP public key using gpg.

  Returns `{:ok, base64_encrypted_key}` or `{:error, reason}`.

  Requires `gpg` (GnuPG) to be installed. Uses a temporary homedir
  to avoid polluting the user's keyring.
  """
  @spec encrypt_request_key(binary()) :: {:ok, binary()} | {:error, String.t()}
  def encrypt_request_key(raw_key) when byte_size(raw_key) == @aes_key_length do
    tmpdir =
      Path.join(
        System.tmp_dir!(),
        "raxol-lumo-gpg-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(tmpdir)
      File.chmod!(tmpdir, 0o700)

      pubkey_path = Path.join(tmpdir, "lumo.pub")
      input_path = Path.join(tmpdir, "key.bin")
      output_path = Path.join(tmpdir, "key.bin.gpg")

      File.write!(pubkey_path, @lumo_pub_key)
      File.write!(input_path, raw_key)
      File.chmod!(input_path, 0o600)

      # Import the key
      {_, 0} =
        System.cmd(
          "gpg",
          [
            "--homedir",
            tmpdir,
            "--batch",
            "--quiet",
            "--import",
            pubkey_path
          ],
          stderr_to_stdout: true
        )

      # Encrypt the raw key bytes to the Lumo subkey
      {_, 0} =
        System.cmd(
          "gpg",
          [
            "--homedir",
            tmpdir,
            "--batch",
            "--quiet",
            "--yes",
            "--trust-model",
            "always",
            "--encrypt",
            "--recipient",
            "F032A1169DDFF8EDA728E59A9A74C3EF61514A2A",
            "--output",
            output_path,
            input_path
          ],
          stderr_to_stdout: true
        )

      encrypted = File.read!(output_path)
      {:ok, Base.encode64(encrypted)}
    rescue
      e -> {:error, Exception.message(e)}
    after
      File.rm_rf(tmpdir)
    end
  end

  @doc """
  Check if gpg is available on the system.
  """
  @spec gpg_available?() :: boolean()
  def gpg_available? do
    case System.cmd("gpg", ["--version"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    ErlangError -> false
  end
end
