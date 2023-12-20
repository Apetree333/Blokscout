defmodule Indexer.Fetcher.ZkSync.BatchesStatusTracker do
  @moduledoc """
  Fills zkevm_transaction_batches DB table.
  """

  use GenServer
  use Indexer.Fetcher

  require Logger

  import EthereumJSONRPC, only: [json_rpc: 2, quantity_to_integer: 1]

  alias Explorer.Chain
  # alias Explorer.Chain.Events.Publisher
  alias Explorer.Chain.ZkSync.Reader

  alias ABI.{
    FunctionSelector,
    TypeDecoder
  }

  @zero_hash "0000000000000000000000000000000000000000000000000000000000000000"
  @zero_hash_binary <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>

  # keccak256("BlockCommit(uint256,bytes32,bytes32)")
  @block_commit_event "0x8f2916b2f2d78cc5890ead36c06c0f6d5d112c7e103589947e8e2f0d6eddb763"

  # keccak256("BlockExecution(uint256,bytes32,bytes32)")
  @block_execution_event "0x2402307311a4d6604e4e7b4c8a15a7e1213edb39c16a31efa70afb06030d3165"

  def child_spec(start_link_arguments) do
    spec = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, start_link_arguments},
      restart: :transient,
      type: :worker
    }

    Supervisor.child_spec(spec, [])
  end

  def start_link(args, gen_server_options \\ []) do
    GenServer.start_link(__MODULE__, args, Keyword.put_new(gen_server_options, :name, __MODULE__))
  end

  @impl GenServer
  def init(args) do
    Logger.metadata(fetcher: :zksync_batches_tracker)

    config = Application.get_all_env(:indexer)[Indexer.Fetcher.ZkSync.BatchesStatusTracker]
    l1_rpc = config[:zksync_l1_rpc]
    recheck_interval = config[:recheck_interval]

    Process.send(self(), :continue, [])

    {:ok,
     %{
       json_l2_rpc_named_arguments: args[:json_rpc_named_arguments],
       json_l1_rpc_named_arguments: [
         transport: EthereumJSONRPC.HTTP,
         transport_options: [
           http: EthereumJSONRPC.HTTP.HTTPoison,
           url: l1_rpc,
           http_options: [
             recv_timeout: :timer.minutes(10),
             timeout: :timer.minutes(10),
             hackney: [pool: :ethereum_jsonrpc]
           ]
         ]
       ],
       recheck_interval: recheck_interval
     }}
  end

  @impl GenServer
  def handle_info(
        :continue,
        %{
          json_l2_rpc_named_arguments: json_l2_rpc_named_arguments,
          json_l1_rpc_named_arguments: json_l1_rpc_named_arguments,
          recheck_interval: recheck_interval
        } = state
      ) do
    {handle_duration, _} =
      :timer.tc(fn ->
        track_batches_statuses(%{
          json_l2_rpc_named_arguments: json_l2_rpc_named_arguments,
          json_l1_rpc_named_arguments: json_l1_rpc_named_arguments
        })
      end)

    Process.send_after(self(), :continue, max(:timer.seconds(recheck_interval) - div(handle_duration, 1000), 0))

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({ref, _result}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  defp track_batches_statuses(config) do
    {committed_batches, l1_txs} = look_for_committed_batches_and_update(%{}, config)

    {proven_batches, l1_txs} = look_for_proven_batches_and_update(l1_txs, config)

    batches_to_import =
      committed_batches
      |> Map.merge(proven_batches, fn _key, committed_batch, proven_batch ->
        Map.put(committed_batch, :prove_id, proven_batch.prove_id)
      end)

    {executed_batches, l1_txs} = look_for_executed_batches_and_update(l1_txs, config)

    batches_to_import =
      batches_to_import
      |> Map.merge(executed_batches, fn _key, updated_batch, executed_batch ->
        Map.put(updated_batch, :execute_id, executed_batch.execute_id)
      end)

    {:ok, _} =
      Chain.import(%{
        zksync_lifecycle_transactions: %{params: Map.values(l1_txs)},
        zksync_transaction_batches: %{params: Map.values(batches_to_import)},
        timeout: :infinity
      })
  end

  defp look_for_committed_batches_and_update(current_l1_txs, config) do
    expected_committed_batch_number = get_earliest_sealed_batch_number()
    if not is_nil(expected_committed_batch_number) do
      log_info("Checking if the batch #{expected_committed_batch_number} was committed")
      batch_from_rpc = fetch_batches_details_by_batch_number(expected_committed_batch_number, config.json_l2_rpc_named_arguments)

      {:ok, batch_from_db} = Reader.batch(
        expected_committed_batch_number,
        necessity_by_association: %{
          :commit_transaction => :optional
        }
      )

      # TODO: handle the case when there is no batch in DB

      if is_transactions_of_batch_changed(batch_from_db, batch_from_rpc, :commit_tx) do
        log_info("The batch #{expected_committed_batch_number} looks like committed")
        l1_transaction = batch_from_rpc.commit_tx_hash
        l1_txs =
          %{
            l1_transaction => %{
              hash: l1_transaction,
              timestamp: batch_from_rpc.commit_timestamp
            }
          }
          |> get_indices_for_l1_transactions(current_l1_txs)
        hash = "0x" <> Base.encode16(l1_transaction)
        log_info("Commitment transaction #{hash}")
        commit_tx_receipt = fetch_tx_receipt_by_hash(hash, config.json_l1_rpc_named_arguments)
        committed_batches =
          get_committed_batches_from_logs(commit_tx_receipt["logs"])
          |> Reader.batches([])
          |> Enum.reduce(%{}, fn batch, committed_batches ->
            Map.put(
              committed_batches,
              batch.number,
              transform_transaction_batch_to_map(batch)
                |> Map.put(:commit_id, l1_txs[l1_transaction][:id])
            )
          end)
        { committed_batches, l1_txs }
      else
        { %{}, current_l1_txs }
      end
    else
      { %{}, current_l1_txs }
    end
  end

  defp look_for_proven_batches_and_update(current_l1_txs, config) do
    expected_proven_batch_number = get_earliest_unproven_batch_number()
    if not is_nil(expected_proven_batch_number) do
      log_info("Checking if the batch #{expected_proven_batch_number} was proven")
      batch_from_rpc = fetch_batches_details_by_batch_number(expected_proven_batch_number, config.json_l2_rpc_named_arguments)

      {:ok, batch_from_db} = Reader.batch(
        expected_proven_batch_number,
        necessity_by_association: %{
          :prove_transaction => :optional
        }
      )

      # TODO: handle the case when there is no batch in DB

      if is_transactions_of_batch_changed(batch_from_db, batch_from_rpc, :prove_tx) do
        log_info("The batch #{expected_proven_batch_number} looks like proven")
        l1_transaction = batch_from_rpc.prove_tx_hash
        l1_txs =
          %{
            l1_transaction => %{
              hash: l1_transaction,
              timestamp: batch_from_rpc.prove_timestamp
            }
          }
          |> get_indices_for_l1_transactions(current_l1_txs)
        hash = "0x" <> Base.encode16(l1_transaction)
        log_info("Proving transaction #{hash}")
        prove_tx = fetch_tx_by_hash(hash, config.json_l1_rpc_named_arguments)
        proven_batches =
          get_proven_batches_from_calldata(prove_tx["input"])
          |> Enum.map(fn batch_info -> elem(batch_info, 0) end)
          |> Reader.batches([])
          |> Enum.reduce(%{}, fn batch, proven_batches ->
            Map.put(
              proven_batches,
              batch.number,
              transform_transaction_batch_to_map(batch)
                |> Map.put(:prove_id, l1_txs[l1_transaction][:id])
            )
          end)
        { proven_batches, l1_txs }
      else
        { %{}, current_l1_txs }
      end
    else
      { %{}, current_l1_txs }
    end
  end

  defp look_for_executed_batches_and_update(current_l1_txs, config) do
    expected_executed_batch_number = get_earliest_unexecuted_batch_number()
    if not is_nil(expected_executed_batch_number) do
      log_info("Checking if the batch #{expected_executed_batch_number} was executed")
      batch_from_rpc = fetch_batches_details_by_batch_number(expected_executed_batch_number, config.json_l2_rpc_named_arguments)

      {:ok, batch_from_db} = Reader.batch(
        expected_executed_batch_number,
        necessity_by_association: %{
          :execute_transaction => :optional
        }
      )

      # TODO: handle the case when there is no batch in DB

      if is_transactions_of_batch_changed(batch_from_db, batch_from_rpc, :execute_tx) do
        log_info("The batch #{expected_executed_batch_number} looks like executed")
        l1_transaction = batch_from_rpc.executed_tx_hash
        l1_txs =
          %{
            l1_transaction => %{
              hash: l1_transaction,
              timestamp: batch_from_rpc.executed_timestamp
            }
          }
          |> get_indices_for_l1_transactions(current_l1_txs)
        hash = "0x" <> Base.encode16(l1_transaction)
        log_info("Executing transaction #{hash}")
        execute_tx_receipt = fetch_tx_receipt_by_hash(hash, config.json_l1_rpc_named_arguments)
        executed_batches =
          get_executed_batches_from_logs(execute_tx_receipt["logs"])
          |> Reader.batches([])
          |> Enum.reduce(%{}, fn batch, executed_batches ->
            Map.put(
              executed_batches,
              batch.number,
              transform_transaction_batch_to_map(batch)
                |> Map.put(:execute_id, l1_txs[l1_transaction][:id])
            )
          end)
        { executed_batches, l1_txs }
      else
        { %{}, current_l1_txs }
      end
    else
      { %{}, current_l1_txs }
    end
  end

  # batches_to_import =
  #   Reader.batches(
  #     start_batch_number,
  #     end_batch_number,
  #     necessity_by_association: %{
  #       :commit_transaction => :optional,
  #       :prove_transaction => :optional,
  #       :execute_transaction => :optional
  #     }
  #   )
  #   |> Enum.reduce(batches_details, fn batch_from_db, changed_batches ->
  #     received_batch = Map.get(batches_details, batch_from_db.number)
  #     if is_transactions_of_batch_changed(batch_from_db, received_batch, :commit_tx) &&
  #        is_transactions_of_batch_changed(batch_from_db, received_batch, :prove_tx) &&
  #        is_transactions_of_batch_changed(batch_from_db, received_batch, :execute_tx) do
  #       Map.delete(changed_batches, batch_from_db.number)
  #     else
  #       received_batch =
  #         Map.merge(
  #           received_batch,
  #           %{
  #             start_block: batch_from_db.start_block,
  #             end_block: batch_from_db.end_block
  #           }
  #         )
  #       Map.put(changed_batches, batch_from_db.number, received_batch)
  #     end
  #   end)
  # IO.inspect(batches_to_import)

  defp get_indices_for_l1_transactions(new_l1_txs, current_l1_txs) do
    # Get indices for l1 transactions previously handled
    l1_txs =
      Map.keys(new_l1_txs)
      |> Reader.lifecycle_transactions()
      |> Enum.reduce(new_l1_txs, fn {hash, id}, txs ->
        {_, txs} = Map.get_and_update!(txs, hash.bytes, fn l1_tx ->
          {l1_tx, Map.put(l1_tx, :id, id)}
        end)
        txs
      end)

    # Provide indices for new L1 transactions
    l1_tx_next_id =
      Map.values(current_l1_txs)
      |> Enum.reduce(Reader.next_id(), fn tx, next_id ->
        max(next_id, tx.id + 1)
      end)

    { l1_txs, _ } =
      Map.keys(l1_txs)
      |> Enum.reduce({l1_txs, l1_tx_next_id}, fn hash, {txs, next_id} = _acc ->
        tx = txs[hash]
        id = Map.get(tx, :id)
        if is_nil(id) do
          {Map.put(txs, hash, Map.put(tx, :id, next_id)), next_id + 1}
        else
          {txs, next_id}
        end
      end)

    current_l1_txs
    |> Map.merge(l1_txs)
  end

  defp get_earliest_batch_number do
    with value <- Reader.oldest_available_batch_number(),
         false <- is_nil(value) do
      value
    else
      true ->
        log_info("No batches found in DB")
        nil
    end
  end

  defp get_earliest_sealed_batch_number do
    with value <- Reader.earliest_sealed_batch_number(),
         false <- is_nil(value) do
      value
    else
      true ->
        log_info("No committed batches found in DB")
        get_earliest_batch_number()
    end
  end

  defp get_earliest_unproven_batch_number do
    with value <- Reader.earliest_unproven_batch_number(),
         false <- is_nil(value) do
      value
    else
      true ->
        log_info("No proven batches found in DB")
        get_earliest_batch_number()
    end
  end

  defp get_earliest_unexecuted_batch_number do
    with value <- Reader.earliest_unexecuted_batch_number(),
         false <- is_nil(value) do
      value
    else
      true ->
        log_info("No executed batches found in DB")
        get_earliest_batch_number()
    end
  end

  defp is_transactions_of_batch_changed(batch_db, batch_json, tx_type) do
    tx_hash_json =
      case tx_type do
        :commit_tx -> batch_json.commit_tx_hash
        :prove_tx -> batch_json.prove_tx_hash
        :execute_tx -> batch_json.executed_tx_hash
      end
    tx_hash_db =
      case tx_type do
        :commit_tx -> batch_db.commit_transaction
        :prove_tx -> batch_db.prove_transaction
        :execute_tx -> batch_db.execute_transaction
      end
    tx_hash_db =
      if is_nil(tx_hash_db) do
        @zero_hash_binary
      else
        tx_hash_db.hash.bytes
      end
    tx_hash_json != tx_hash_db
  end

  defp fetch_batches_details_by_batch_number(batch_number, json_rpc_named_arguments) do
    req = EthereumJSONRPC.request(%{
      id: batch_number,
      method: "zks_getL1BatchDetails",
      params: [batch_number]
    })

    error_message = &"Cannot call zks_getL1BatchDetails. Error: #{inspect(&1)}"

    {:ok, resp} = repeated_call(&json_rpc/2, [req, json_rpc_named_arguments], error_message, 3)

    transform_batch_details_to_map(resp)
  end

  defp fetch_tx_by_hash(hash, json_rpc_named_arguments) do
    req = EthereumJSONRPC.request(%{
      id: 0,
      method: "eth_getTransactionByHash",
      params: [hash]
    })

    error_message = &"Cannot call eth_getTransactionByHash for hash #{hash}. Error: #{inspect(&1)}"

    {:ok, resp} = repeated_call(&json_rpc/2, [req, json_rpc_named_arguments], error_message, 3)

    resp
  end

  defp fetch_tx_receipt_by_hash(hash, json_rpc_named_arguments) do
    req = EthereumJSONRPC.request(%{
      id: 0,
      method: "eth_getTransactionReceipt",
      params: [hash]
    })

    error_message = &"Cannot call eth_getTransactionReceipt for hash #{hash}. Error: #{inspect(&1)}"

    {:ok, resp} = repeated_call(&json_rpc/2, [req, json_rpc_named_arguments], error_message, 3)

    resp
  end

  defp repeated_call(func, args, error_message, retries_left) do
    case apply(func, args) do
      {:ok, _} = res ->
        res

      {:error, message} = err ->
        retries_left = retries_left - 1

        if retries_left <= 0 do
          Logger.error(error_message.(message))
          err
        else
          Logger.error("#{error_message.(message)} Retrying...")
          :timer.sleep(3000)
          repeated_call(func, args, error_message, retries_left)
        end
    end
  end

  defp from_ts_to_datetime(time_ts) do
    {_, unix_epoch_starts} = DateTime.from_unix(0)
    case is_nil(time_ts) or time_ts == 0 do
      true ->
        unix_epoch_starts
      false ->
        case  DateTime.from_unix(time_ts) do
          {:ok, datetime} ->
            datetime
          {:error, _} ->
            unix_epoch_starts
        end
    end
  end

  defp from_iso8601_to_datetime(time_string) do
    case is_nil(time_string) do
      true ->
        from_ts_to_datetime(0)
      false ->
        case DateTime.from_iso8601(time_string) do
          {:ok, datetime, _} ->
            datetime
          {:error, _} ->
            from_ts_to_datetime(0)
        end
    end
  end

  defp json_txid_to_hash(hash) do
    case hash do
      "0x" <> tx_hash -> tx_hash
      nil -> @zero_hash
    end
  end

  defp strhash_to_byteshash(hash) do
    hash
    |> json_txid_to_hash()
    |> Base.decode16!(case: :mixed)
  end

  defp transform_batch_details_to_map(json_response) do
    %{
      "number" => {:number, :ok},
      "timestamp" => {:timestamp, :ts_to_datetime},
      "l1TxCount" => {:l1_tx_count, :ok},
      "l2TxCount" => {:l2_tx_count, :ok},
      "rootHash" => {:root_hash, :str_to_byteshash},
      "commitTxHash" => {:commit_tx_hash, :str_to_byteshash},
      "committedAt" => {:commit_timestamp, :iso8601_to_datetime},
      "proveTxHash" => {:prove_tx_hash, :str_to_byteshash},
      "provenAt" => {:prove_timestamp, :iso8601_to_datetime} ,
      "executeTxHash" => {:executed_tx_hash, :str_to_byteshash},
      "executedAt" => {:executed_timestamp, :iso8601_to_datetime},
      "l1GasPrice" => {:l1_gas_price, :ok},
      "l2FairGasPrice" => {:l2_fair_gas_price, :ok}
      # :start_block added by request_block_ranges_by_rpc
      # :end_block added by request_block_ranges_by_rpc
    }
    |> Enum.reduce(%{start_block: nil, end_block: nil}, fn {key, {key_atom, transform_type}}, batch_details_map ->
      value_in_json_response = Map.get(json_response, key)
      Map.put(
        batch_details_map,
        key_atom,
        case transform_type do
          :iso8601_to_datetime -> from_iso8601_to_datetime(value_in_json_response)
          :ts_to_datetime -> from_ts_to_datetime(value_in_json_response)
          :str_to_txhash -> json_txid_to_hash(value_in_json_response)
          :str_to_byteshash -> strhash_to_byteshash(value_in_json_response)
          _ -> value_in_json_response
        end
      )
    end)
  end

  defp transform_transaction_batch_to_map(batch) do
    %{
      number: batch.number,
      timestamp: batch.timestamp,
      l1_tx_count: batch.l1_tx_count,
      l2_tx_count: batch.l2_tx_count,
      root_hash: batch.root_hash.bytes,
      l1_gas_price: batch.l1_gas_price,
      l2_fair_gas_price: batch.l2_fair_gas_price,
      start_block: batch.start_block,
      end_block: batch.end_block,
      commit_id: batch.commit_id,
      prove_id: batch.prove_id,
      execute_id: batch.execute_id
    }
  end

  defp get_proven_batches_from_calldata(calldata) do
    "0x7f61885c" <> encoded_params = calldata

    # /// @param batchNumber Rollup batch number
    # /// @param batchHash Hash of L2 batch
    # /// @param indexRepeatedStorageChanges The serial number of the shortcut index that's used as a unique identifier for storage keys that were used twice or more
    # /// @param numberOfLayer1Txs Number of priority operations to be processed
    # /// @param priorityOperationsHash Hash of all priority operations from this batch
    # /// @param l2LogsTreeRoot Root hash of tree that contains L2 -> L1 messages from this batch
    # /// @param timestamp Rollup batch timestamp, have the same format as Ethereum batch constant
    # /// @param commitment Verified input for the zkSync circuit
    # struct StoredBatchInfo {
    #     uint64 batchNumber;
    #     bytes32 batchHash;
    #     uint64 indexRepeatedStorageChanges;
    #     uint256 numberOfLayer1Txs;
    #     bytes32 priorityOperationsHash;
    #     bytes32 l2LogsTreeRoot;
    #     uint256 timestamp;
    #     bytes32 commitment;
    # }
    # /// @notice Recursive proof input data (individual commitments are constructed onchain)
    # struct ProofInput {
    #     uint256[] recursiveAggregationInput;
    #     uint256[] serializedProof;
    # }
    # proveBatches(StoredBatchInfo calldata _prevBatch, StoredBatchInfo[] calldata _committedBatches, ProofInput calldata _proof)

    # IO.inspect(FunctionSelector.decode("proveBatches((uint64,bytes32,uint64,uint256,bytes32,bytes32,uint256,bytes32),(uint64,bytes32,uint64,uint256,bytes32,bytes32,uint256,bytes32)[],(uint256[],uint256[]))"))
    [_prevBatch, committed_batches, _proof] = TypeDecoder.decode(
      Base.decode16!(encoded_params, case: :lower),
      %FunctionSelector{
        function: "proveBatches",
        types: [
          tuple: [
            uint: 64,
            bytes: 32,
            uint: 64,
            uint: 256,
            bytes: 32,
            bytes: 32,
            uint: 256,
            bytes: 32
          ],
          array: {:tuple,
           [
             uint: 64,
             bytes: 32,
             uint: 64,
             uint: 256,
             bytes: 32,
             bytes: 32,
             uint: 256,
             bytes: 32
           ]},
          tuple: [array: {:uint, 256}, array: {:uint, 256}]
        ]
      }
    )

    log_info("Discovered #{length(committed_batches)} proven batches in the prove tx")

    committed_batches
  end

  defp get_committed_batches_from_logs(logs) do
    executed_batches =
      logs
      |> Enum.reduce([], fn log_entity, batches_numbers ->
        topics = log_entity["topics"]
        if Enum.at(topics, 0) == @block_commit_event do
          [ quantity_to_integer(Enum.at(topics, 1)) | batches_numbers]
        else
          batches_numbers
        end
      end)

    log_info("Discovered #{length(executed_batches)} committed batches in the commitment tx")

    executed_batches
  end

  defp get_executed_batches_from_logs(logs) do
    executed_batches =
      logs
      |> Enum.reduce([], fn log_entity, batches_numbers ->
        topics = log_entity["topics"]
        if Enum.at(topics, 0) == @block_execution_event do
          [ quantity_to_integer(Enum.at(topics, 1)) | batches_numbers]
        else
          batches_numbers
        end
      end)

    log_info("Discovered #{length(executed_batches)} executed batches in the executing tx")

    executed_batches
  end

  ###############################################################################
  ##### Logging related functions
  defp log_warning(msg) do
    Logger.warning(msg)
  end

  defp log_info(msg) do
    Logger.notice(msg)
  end

end