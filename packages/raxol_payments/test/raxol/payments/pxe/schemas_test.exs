defmodule Raxol.Payments.Pxe.SchemasTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Pxe.Schemas.{CreateNoteParams, CreateNoteResult, HealthStatus}

  describe "CreateNoteParams.validate/1" do
    @valid_params %CreateNoteParams{
      recipient: "0x" <> String.duplicate("ab", 32),
      token: "0x" <> String.duplicate("cd", 32),
      amount: "1000000",
      chain_id: 1
    }

    test "accepts valid params" do
      assert :ok = CreateNoteParams.validate(@valid_params)
    end

    test "rejects short recipient address" do
      params = %{@valid_params | recipient: "0xabc"}
      assert {:error, {:invalid_recipient, _}} = CreateNoteParams.validate(params)
    end

    test "rejects recipient without 0x prefix" do
      params = %{@valid_params | recipient: String.duplicate("ab", 32)}
      assert {:error, {:invalid_recipient, _}} = CreateNoteParams.validate(params)
    end

    test "rejects short token address" do
      params = %{@valid_params | token: "0xabc"}
      assert {:error, {:invalid_token, _}} = CreateNoteParams.validate(params)
    end

    test "rejects negative amount" do
      params = %{@valid_params | amount: "-1"}
      assert {:error, {:invalid_amount, _}} = CreateNoteParams.validate(params)
    end

    test "rejects amount with leading zeros" do
      params = %{@valid_params | amount: "01"}
      assert {:error, {:invalid_amount, _}} = CreateNoteParams.validate(params)
    end

    test "rejects zero amount, which the bridge refuses" do
      params = %{@valid_params | amount: "0"}
      assert {:error, {:invalid_amount, _}} = CreateNoteParams.validate(params)
    end

    test "rejects an amount over 78 digits" do
      params = %{@valid_params | amount: "1" <> String.duplicate("0", 78)}
      assert {:error, {:invalid_amount, _}} = CreateNoteParams.validate(params)
    end

    test "rejects the zero recipient address" do
      params = %{@valid_params | recipient: "0x" <> String.duplicate("0", 64)}
      assert {:error, {:invalid_recipient, _}} = CreateNoteParams.validate(params)
    end

    test "accepts a complete trade context" do
      params = %{
        @valid_params
        | trade_id: "0x" <> String.duplicate("ee", 32),
          sub_trade_index: 1,
          total_sub_trades: 2
      }

      assert :ok = CreateNoteParams.validate(params)
    end

    test "rejects a partial or out-of-range trade context" do
      trade_id = "0x" <> String.duplicate("ee", 32)

      for {id, index, total} <- [
            {trade_id, nil, nil},
            {nil, 0, 2},
            {trade_id, 0, 1},
            {trade_id, 0, 101},
            {trade_id, 2, 2},
            {trade_id, -1, 2},
            {"0xshort", 0, 2}
          ] do
        params = %{@valid_params | trade_id: id, sub_trade_index: index, total_sub_trades: total}

        assert {:error, {:invalid_trade_context, _}} = CreateNoteParams.validate(params),
               "#{inspect({id, index, total})} was accepted"
      end
    end

    test "rejects non-positive chain_id" do
      params = %{@valid_params | chain_id: 0}
      assert {:error, {:invalid_chain_id, _}} = CreateNoteParams.validate(params)
    end
  end

  describe "CreateNoteParams.to_json/1" do
    test "serializes to camelCase JSON map" do
      params = %CreateNoteParams{
        recipient: "0xrecipient",
        token: "0xtoken",
        amount: "500",
        chain_id: 42_161
      }

      json = CreateNoteParams.to_json(params)

      assert json["recipient"] == "0xrecipient"
      assert json["token"] == "0xtoken"
      assert json["amount"] == "500"
      assert json["chainId"] == 42_161
      refute Map.has_key?(json, "tradeId")
    end

    test "includes the trade context only when set" do
      params = %CreateNoteParams{
        recipient: "0xrecipient",
        token: "0xtoken",
        amount: "500",
        chain_id: 1,
        trade_id: "0xtrade",
        sub_trade_index: 0,
        total_sub_trades: 3
      }

      json = CreateNoteParams.to_json(params)

      assert json["tradeId"] == "0xtrade"
      assert json["subTradeIndex"] == 0
      assert json["totalSubTrades"] == 3
    end
  end

  describe "CreateNoteResult.from_json/1" do
    test "reads the note-hash and nullifier lists" do
      json = %{
        "noteHashes" => ["0xa", "0xb"],
        "nullifiers" => ["0xn0", "0xn1", "0xn2"],
        "l2TxHash" => "0xl2tx",
        "noteCommitment" => "0xa",
        "nullifierHash" => "0xn0"
      }

      assert {:ok, result} = CreateNoteResult.from_json(json)
      assert result.note_hashes == ["0xa", "0xb"]
      assert result.nullifiers == ["0xn0", "0xn1", "0xn2"]
      assert result.l2_tx_hash == "0xl2tx"
    end

    test "refuses a result without the lists" do
      json = %{"noteCommitment" => "0xa", "nullifierHash" => "0xn0", "l2TxHash" => "0xl2tx"}
      assert {:error, {:unexpected_result, ^json}} = CreateNoteResult.from_json(json)
    end

    test "refuses lists holding non-strings" do
      json = %{"noteHashes" => [1], "nullifiers" => [], "l2TxHash" => "0xl2tx"}
      assert {:error, {:unexpected_result, _}} = CreateNoteResult.from_json(json)
    end
  end

  describe "HealthStatus.from_json/1" do
    test "parses ok status with version" do
      json = %{"status" => "ok", "version" => "4.1.3"}
      status = HealthStatus.from_json(json)

      assert status.status == :ok
      assert status.version == "4.1.3"
    end

    test "parses starting status without version" do
      json = %{"status" => "starting"}
      status = HealthStatus.from_json(json)

      assert status.status == :starting
      assert status.version == nil
    end

    test "unknown status maps to error" do
      json = %{"status" => "borked"}
      status = HealthStatus.from_json(json)

      assert status.status == :error
    end
  end
end
