defmodule Raxol.System.Updater.Provenance.TrustedRoot do
  @moduledoc """
  The pinned Sigstore trust material: Fulcio certificate chains, Rekor
  transparency-log keys and certificate-transparency log keys, each with
  the window it is trusted for.

  `default/0` is `priv/sigstore/trusted_root.json`, the Sigstore public-good
  instance's `trusted_root.json`, compiled into this module. Nothing is
  fetched at verification time, so a newer root only arrives with a
  release; `priv/sigstore/README.md` records where the snapshot came from
  and how to refresh it.
  """

  alias Raxol.System.Updater.Provenance.Crypto

  @path Path.expand("../../../../../priv/sigstore/trusted_root.json", __DIR__)
  @external_resource @path
  @json File.read!(@path)

  @media_type "application/vnd.dev.sigstore.trustedroot+json;version=0.1"

  # Key types a Sigstore trusted root names, and the digest each signs with.
  @key_digests %{
    "PKIX_ECDSA_P256_SHA_256" => :sha256,
    "PKIX_ECDSA_P384_SHA_384" => :sha384,
    "PKIX_ECDSA_P521_SHA_512" => :sha512,
    "PKIX_ED25519" => :none
  }

  @type window :: {integer(), integer() | nil}
  @type certificate_authority :: %{chain: [binary()], valid_for: window()}
  @type log :: %{
          log_id: binary(),
          key: term(),
          digest: atom(),
          valid_for: window()
        }

  @type t :: %__MODULE__{
          certificate_authorities: [certificate_authority()],
          tlogs: [log()],
          ctlogs: [log()]
        }

  defstruct certificate_authorities: [], tlogs: [], ctlogs: []

  @doc "The trusted root compiled in from `priv/sigstore/trusted_root.json`."
  @spec default() :: {:ok, t()} | {:error, term()}
  def default, do: parse(@json)

  @doc """
  Parses a `trusted_root.json`. A log whose key type is unknown is left
  out rather than guessed at; anything else malformed refuses the root.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(json) do
    case Jason.decode(json) do
      {:ok, %{"mediaType" => @media_type} = root} -> build(root)
      {:ok, _other} -> {:error, {:invalid_trusted_root, :media_type}}
      {:error, _reason} -> {:error, {:invalid_trusted_root, :json}}
    end
  end

  defp build(root) do
    with {:ok, cas} <-
           map_all(Map.get(root, "certificateAuthorities", []), &ca/1),
         {:ok, tlogs} <- logs(root, "tlogs"),
         {:ok, ctlogs} <- logs(root, "ctlogs") do
      {:ok,
       %__MODULE__{certificate_authorities: cas, tlogs: tlogs, ctlogs: ctlogs}}
    end
  end

  defp logs(root, key) do
    with {:ok, logs} <- map_all(Map.get(root, key, []), &log/1),
         do: {:ok, Enum.reject(logs, &is_nil/1)}
  end

  @doc "Whether unix time `time` falls in a trust window (an open end is `nil`)."
  @spec valid_at?(window(), integer()) :: boolean()
  def valid_at?({from, until}, time),
    do: from <= time and (is_nil(until) or time <= until)

  @doc "The log with raw id `log_id` whose key is trusted at unix time `time`."
  @spec find_log([log()], binary(), integer()) :: {:ok, log()} | :error
  def find_log(logs, log_id, time) do
    case Enum.find(
           logs,
           &(&1.log_id == log_id and valid_at?(&1.valid_for, time))
         ) do
      nil -> :error
      log -> {:ok, log}
    end
  end

  defp map_all(items, fun) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end)
  end

  defp map_all(_items, _fun), do: {:error, {:invalid_trusted_root, :list}}

  defp ca(%{
         "certChain" => %{"certificates" => [_ | _] = certs},
         "validFor" => valid_for
       }) do
    with {:ok, chain} <- map_all(certs, &raw_bytes/1),
         {:ok, window} <- window(valid_for) do
      {:ok, %{chain: chain, valid_for: window}}
    end
  end

  defp ca(_ca), do: {:error, {:invalid_trusted_root, :certificate_authority}}

  defp log(%{
         "logId" => %{"keyId" => key_id},
         "publicKey" => %{
           "rawBytes" => raw,
           "keyDetails" => details,
           "validFor" => valid_for
         }
       }) do
    with {:ok, log_id} <- bytes(key_id),
         {:ok, spki} <- bytes(raw),
         {:ok, window} <- window(valid_for) do
      log_key(log_id, spki, Map.get(@key_digests, details), window)
    end
  end

  defp log(_log), do: {:error, {:invalid_trusted_root, :log}}

  defp log_key(_log_id, _spki, nil = _unknown_key_type, _window), do: {:ok, nil}

  defp log_key(log_id, spki, digest, window) do
    case Crypto.decode_spki(spki) do
      {:ok, key} ->
        {:ok, %{log_id: log_id, key: key, digest: digest, valid_for: window}}

      :error ->
        {:error, {:invalid_trusted_root, :public_key}}
    end
  end

  defp raw_bytes(%{"rawBytes" => raw}), do: bytes(raw)
  defp raw_bytes(_cert), do: {:error, {:invalid_trusted_root, :certificate}}

  defp bytes(value) do
    case Crypto.decode64(value) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:invalid_trusted_root, :base64}}
    end
  end

  defp window(%{"start" => start} = valid_for) do
    with {:ok, from} <- unix(start),
         {:ok, until} <- optional_unix(Map.get(valid_for, "end")) do
      {:ok, {from, until}}
    end
  end

  defp window(_valid_for), do: {:error, {:invalid_trusted_root, :valid_for}}

  defp optional_unix(nil), do: {:ok, nil}
  defp optional_unix(value), do: unix(value)

  defp unix(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_unix(datetime)}
      {:error, _reason} -> {:error, {:invalid_trusted_root, :timestamp}}
    end
  end

  defp unix(_value), do: {:error, {:invalid_trusted_root, :timestamp}}
end
