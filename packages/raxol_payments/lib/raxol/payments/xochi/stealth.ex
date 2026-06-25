defmodule Raxol.Payments.Xochi.Stealth do
  @moduledoc """
  ERC-5564/ERC-6538 stealth address derivation and scanning.

  Implements the secp256k1 stealth address scheme: a sender generates an
  ephemeral keypair, computes a shared secret with the recipient's viewing
  key via ECDH, and derives a one-time stealth address. The recipient
  scans announcements using their viewing key and view tag optimization
  (256x speedup).

  ## Flow

  **Sender (generate):**
  1. Parse recipient's meta-address (spending pubkey + viewing pubkey)
  2. Generate ephemeral keypair (r, R = r*G)
  3. Compute shared secret: S = r * V (ECDH with viewing pubkey)
  4. Hash: h = keccak256(compress(S))
  5. View tag: first byte of h
  6. Stealth pubkey: P' = P + h*G
  7. Stealth address: last 20 bytes of keccak256(P'_uncompressed[1:])

  **Recipient (scan):**
  1. For each announcement, check view tag (fast filter, 1:256 false positive)
  2. Compute S = v * R (ECDH with ephemeral pubkey)
  3. Derive expected stealth address
  4. If match: stealth privkey = (p + h) mod n

  ## Standards

  - ERC-5564: Stealth Addresses (announce format)
  - ERC-6538: Stealth Meta-Address Registry
  - Scheme ID 1: secp256k1 with view tags
  """

  alias Raxol.Payments.Secret

  @erc5564_announcer "0x55649E01B5Df198D18D95b5cc5051630cfD45564"
  @erc6538_registry "0x6538E6bf4B0eBd30A8Ea093027Ac2422ce5d6538"
  @stealth_scheme_id 1

  @curve_order 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  @type meta_address :: %{
          spending_pub_key: binary(),
          viewing_pub_key: binary(),
          chain_id: pos_integer()
        }

  @type settlement :: %{
          stealth_address: String.t(),
          ephemeral_pub_key: binary(),
          view_tag: 0..255
        }

  @type announcement :: %{
          scheme_id: pos_integer(),
          stealth_address: String.t(),
          caller: String.t(),
          ephemeral_pub_key: binary(),
          metadata: binary(),
          block_number: non_neg_integer(),
          tx_hash: String.t(),
          log_index: non_neg_integer()
        }

  @type stealth_payment :: %{
          announcement: announcement(),
          # The recipient's one-time spend key, wrapped so it cannot leak via
          # logs/inspect; `Secret.reveal/1` to sign a claim with it.
          stealth_priv_key: Secret.t()
        }

  # -- Public API --

  @doc "ERC-5564 Announcer contract address (Ethereum mainnet)."
  @spec announcer_address() :: String.t()
  def announcer_address, do: @erc5564_announcer

  @doc "ERC-6538 Registry contract address (Ethereum mainnet)."
  @spec registry_address() :: String.t()
  def registry_address, do: @erc6538_registry

  @doc "Scheme ID for secp256k1 with view tags."
  @spec scheme_id() :: pos_integer()
  def scheme_id, do: @stealth_scheme_id

  @doc """
  Generate a stealth address from a recipient's meta-address.

  Returns the stealth address, ephemeral public key, and view tag for
  use in an ERC-5564 announcement.
  """
  @spec generate(meta_address()) :: {:ok, settlement()} | {:error, term()}
  def generate(meta), do: generate(meta, :crypto.strong_rand_bytes(32))

  @doc """
  Generate a stealth address using a caller-supplied ephemeral private key.

  Identical to `generate/1` but deterministic: the same meta-address and
  ephemeral key always yield the same stealth address, ephemeral public key,
  and view tag. Used for reproducible cross-implementation conformance checks.
  """
  @spec generate(meta_address(), <<_::256>>) :: {:ok, settlement()} | {:error, term()}
  def generate(
        %{spending_pub_key: spending_pub, viewing_pub_key: viewing_pub},
        ephemeral_priv
      )
      when is_binary(ephemeral_priv) and byte_size(ephemeral_priv) == 32 do
    with {:ok, spending_pub} <- normalize_pubkey(spending_pub),
         {:ok, viewing_pub} <- normalize_pubkey(viewing_pub),
         {:ok, ephemeral_pub} <- derive_pubkey(ephemeral_priv),
         {:ok, shared_point} <- ec_mult(viewing_pub, ephemeral_priv) do
      build_settlement(spending_pub, ephemeral_pub, shared_point)
    end
  end

  def generate(_, _), do: {:error, :invalid_meta_address}

  defp build_settlement(spending_pub, ephemeral_pub, shared_point) do
    hash = shared_point |> compress_pubkey() |> keccak256()
    <<view_tag::8, _rest::binary>> = hash

    case derive_stealth_address(spending_pub, hash) do
      {:ok, stealth_address} ->
        {:ok,
         %{
           stealth_address: stealth_address,
           ephemeral_pub_key: ephemeral_pub,
           view_tag: view_tag
         }}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Scan announcements for payments to our stealth addresses.

  Uses view tag optimization: only performs full ECDH for announcements
  where the view tag matches (1:256 false positive rate).

  Returns a list of discovered payments with their stealth private keys.
  """
  @spec scan(binary(), binary(), [announcement()]) ::
          {:ok, [stealth_payment()]} | {:error, term()}
  def scan(spending_priv_key, viewing_priv_key, announcements) when is_list(announcements) do
    payments =
      announcements
      |> Enum.filter(&(&1.scheme_id == @stealth_scheme_id))
      |> Enum.reduce([], fn ann, acc ->
        case check_announcement(spending_priv_key, viewing_priv_key, ann) do
          {:ok, payment} -> [payment | acc]
          :skip -> acc
        end
      end)
      |> Enum.reverse()

    {:ok, payments}
  end

  @doc """
  Extract view tag from announcement metadata.

  The view tag is the first byte of the metadata field.
  """
  @spec extract_view_tag(binary() | String.t()) :: {:ok, 0..255} | {:error, term()}
  def extract_view_tag("0x" <> hex), do: extract_view_tag_hex(hex)

  def extract_view_tag(<<>>), do: {:ok, 0}

  def extract_view_tag(bin) when is_binary(bin) do
    # Distinguish hex strings from raw binary:
    # if all bytes are printable hex chars, treat as hex string
    if hex_string?(bin) do
      extract_view_tag_hex(bin)
    else
      <<tag::8, _rest::binary>> = bin
      {:ok, tag}
    end
  end

  defp extract_view_tag_hex(""), do: {:ok, 0}

  defp extract_view_tag_hex(<<byte_hex::binary-size(2), _rest::binary>>) do
    case Integer.parse(byte_hex, 16) do
      {val, ""} when val >= 0 and val <= 255 -> {:ok, val}
      _ -> {:error, :invalid_view_tag_hex}
    end
  end

  defp extract_view_tag_hex(_), do: {:error, :invalid_view_tag_hex}

  defp hex_string?(<<c, rest::binary>>)
       when c in ?0..?9 or c in ?a..?f or c in ?A..?F do
    hex_string?(rest)
  end

  defp hex_string?(<<>>), do: true
  defp hex_string?(_), do: false

  @doc """
  Create metadata bytes with view tag as first byte.

  Optionally appends extra data (token address, amount, etc).
  """
  @spec create_metadata(0..255, binary()) :: binary()
  def create_metadata(view_tag, extra \\ <<>>) when view_tag >= 0 and view_tag <= 255 do
    <<view_tag::8>> <> extra
  end

  @doc """
  Encode a meta-address in ERC-6538 st:eth:0x format.
  """
  @spec encode_meta_address(meta_address()) :: String.t()
  def encode_meta_address(%{spending_pub_key: spending, viewing_pub_key: viewing}) do
    spending_hex = strip_0x(Base.encode16(spending, case: :lower))
    viewing_hex = strip_0x(Base.encode16(viewing, case: :lower))
    "st:eth:0x" <> spending_hex <> viewing_hex
  end

  @doc """
  Decode a meta-address from ERC-6538 st:eth:0x format.
  """
  @spec decode_meta_address(String.t(), pos_integer()) :: {:ok, meta_address()} | {:error, term()}
  def decode_meta_address("st:eth:0x" <> hex, chain_id) when byte_size(hex) == 132 do
    <<spending_hex::binary-size(66), viewing_hex::binary-size(66)>> = hex

    with {:ok, spending} <- decode_hex(spending_hex),
         {:ok, viewing} <- decode_hex(viewing_hex),
         true <- valid_compressed_prefix?(spending),
         true <- valid_compressed_prefix?(viewing) do
      {:ok,
       %{
         spending_pub_key: spending,
         viewing_pub_key: viewing,
         chain_id: chain_id
       }}
    else
      _ -> {:error, :invalid_meta_address}
    end
  end

  def decode_meta_address(_, _), do: {:error, :invalid_format}

  @doc """
  Validate a compressed secp256k1 public key (33 bytes, 02/03 prefix).
  """
  @spec valid_compressed_pubkey?(binary()) :: boolean()
  def valid_compressed_pubkey?(<<prefix, _rest::binary-size(32)>>)
      when prefix in [0x02, 0x03],
      do: true

  def valid_compressed_pubkey?(_), do: false

  @doc "Validate a view tag (0-255 integer)."
  @spec valid_view_tag?(term()) :: boolean()
  def valid_view_tag?(tag) when is_integer(tag) and tag >= 0 and tag <= 255, do: true
  def valid_view_tag?(_), do: false

  @doc """
  Derive stealth keys from an EVM signature (domain-separated).
  """
  @spec derive_keys(String.t()) ::
          {:ok, %{spending: {binary(), binary()}, viewing: {binary(), binary()}}}
          | {:error, term()}
  def derive_keys(signature) do
    clean_sig = strip_0x(signature)

    spending_priv = keccak256("stealth:spending:" <> clean_sig)
    viewing_priv = keccak256("stealth:viewing:" <> clean_sig)

    with {:ok, spending_pub} <- derive_pubkey(spending_priv),
         {:ok, viewing_pub} <- derive_pubkey(viewing_priv) do
      {:ok,
       %{
         spending: {spending_priv, spending_pub},
         viewing: {viewing_priv, viewing_pub}
       }}
    end
  end

  # -- Private --

  defp check_announcement(spending_priv, viewing_priv, ann) do
    with {:ok, ann_view_tag} <- extract_announcement_view_tag(ann),
         {:ok, ephemeral_pub} <- normalize_pubkey(ann.ephemeral_pub_key),
         {:ok, shared_point} <- ec_mult(ephemeral_pub, viewing_priv) do
      shared_compressed = compress_pubkey(shared_point)
      hash = keccak256(shared_compressed)
      <<computed_view_tag::8, _rest::binary>> = hash

      if computed_view_tag != ann_view_tag do
        :skip
      else
        verify_and_derive_key(spending_priv, hash, ann)
      end
    else
      _ -> :skip
    end
  end

  defp extract_announcement_view_tag(%{metadata: <<tag::8, _rest::binary>>}) do
    {:ok, tag}
  end

  defp extract_announcement_view_tag(%{metadata: <<>>}), do: {:ok, 0}
  defp extract_announcement_view_tag(_), do: {:ok, 0}

  defp verify_and_derive_key(spending_priv, hash, ann) do
    stealth_priv = mod_add(spending_priv, hash, @curve_order)

    case derive_pubkey(stealth_priv) do
      {:ok, stealth_pub} ->
        derived_address = pubkey_to_address(stealth_pub)

        if String.downcase(derived_address) == String.downcase(ann.stealth_address) do
          {:ok, %{announcement: ann, stealth_priv_key: Secret.new(stealth_priv)}}
        else
          :skip
        end

      _ ->
        :skip
    end
  end

  defp derive_stealth_address(spending_pub, hash) do
    # P' = P + hash*G (stealth pubkey = spending pubkey + tweak*generator)
    with {:ok, stealth_pub} <- ec_point_add_scalar(spending_pub, hash) do
      {:ok, pubkey_to_address(stealth_pub)}
    end
  end

  defp pubkey_to_address(compressed_pub) do
    {:ok, uncompressed} = decompress_pubkey(compressed_pub)
    # Drop the 0x04 prefix byte
    <<_prefix::8, xy::binary>> = uncompressed
    <<_first_12::binary-size(12), address::binary-size(20)>> = keccak256(xy)
    "0x" <> Base.encode16(address, case: :lower)
  end

  # -- Crypto wrappers --

  # ExSecp256k1's NIFs are specced `{:ok, binary()} | atom()`, but at runtime they
  # return `{:ok, binary}` or `{:error, atom}` (the spec is loose). A catch-all
  # `error ->` clause covers both: it matches the spec's residual `atom()` so
  # dialyzer is satisfied, and it captures the real `{:error, _}` tuple at runtime.
  defp derive_pubkey(priv_key) when byte_size(priv_key) == 32 do
    case ExSecp256k1.create_public_key(priv_key) do
      {:ok, pub} ->
        {:ok, compressed} = ExSecp256k1.public_key_compress(pub)
        {:ok, compressed}

      error ->
        {:error, {:derive_pubkey, error}}
    end
  end

  defp ec_mult(pubkey, scalar) when byte_size(scalar) == 32 do
    with {:ok, uncompressed} <- decompress_pubkey(pubkey) do
      case ExSecp256k1.public_key_tweak_mult(uncompressed, scalar) do
        {:ok, result} ->
          {:ok, compressed} = ExSecp256k1.public_key_compress(result)
          {:ok, compressed}

        error ->
          {:error, {:ec_mult, error}}
      end
    end
  end

  # Computes P + scalar*G (EC point addition via tweak)
  defp ec_point_add_scalar(pubkey, scalar) when byte_size(scalar) == 32 do
    with {:ok, uncompressed} <- decompress_pubkey(pubkey) do
      case ExSecp256k1.public_key_tweak_add(uncompressed, scalar) do
        {:ok, result} ->
          {:ok, compressed} = ExSecp256k1.public_key_compress(result)
          {:ok, compressed}

        error ->
          {:error, {:ec_add, error}}
      end
    end
  end

  defp decompress_pubkey(<<prefix, _::binary-size(32)>> = compressed)
       when prefix in [0x02, 0x03] do
    ExSecp256k1.public_key_decompress(compressed)
  end

  defp decompress_pubkey(<<0x04, _::binary-size(64)>> = uncompressed) do
    {:ok, uncompressed}
  end

  defp decompress_pubkey(_), do: {:error, :invalid_pubkey}

  defp compress_pubkey(<<prefix, _::binary-size(32)>> = compressed)
       when prefix in [0x02, 0x03] do
    compressed
  end

  defp compress_pubkey(<<0x04, _::binary-size(64)>> = uncompressed) do
    {:ok, compressed} = ExSecp256k1.public_key_compress(uncompressed)
    compressed
  end

  defp normalize_pubkey(key) when is_binary(key) and byte_size(key) in [33, 65] do
    case key do
      <<prefix, _::binary-size(32)>> when prefix in [0x02, 0x03] ->
        {:ok, key}

      <<0x04, _::binary-size(64)>> ->
        {:ok, compressed} = ExSecp256k1.public_key_compress(key)
        {:ok, compressed}

      _ ->
        {:error, :invalid_pubkey}
    end
  end

  defp normalize_pubkey(_), do: {:error, :invalid_pubkey}

  defp keccak256(data) when is_binary(data) do
    ExKeccak.hash_256(data)
  end

  defp mod_add(a, b, modulus) when is_binary(a) and is_binary(b) do
    a_int = :binary.decode_unsigned(a, :big)
    b_int = :binary.decode_unsigned(b, :big)
    result = rem(a_int + b_int, modulus)
    <<result::unsigned-big-integer-size(256)>>
  end

  defp strip_0x("0x" <> rest), do: rest
  defp strip_0x(str), do: str

  defp valid_compressed_prefix?(<<prefix, _::binary-size(32)>>) when prefix in [0x02, 0x03],
    do: true

  defp valid_compressed_prefix?(_), do: false

  defp decode_hex(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, _} = ok -> ok
      :error -> {:error, :invalid_hex}
    end
  end
end
