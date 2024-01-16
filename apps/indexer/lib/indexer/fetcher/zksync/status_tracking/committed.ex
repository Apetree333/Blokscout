defmodule Indexer.Fetcher.ZkSync.StatusTracking.Committed do
  @moduledoc """
    Functionality to discover committed batches
  """

  alias Indexer.Fetcher.ZkSync.Utils.Db
  alias Indexer.Fetcher.ZkSync.Utils.Rpc

  import Indexer.Fetcher.ZkSync.StatusTracking.CommonUtils,
    only: [
      check_if_batch_status_changed: 3,
      prepare_batches_to_import: 2
    ]

  import Indexer.Fetcher.ZkSync.Utils.Logging, only: [log_info: 1]

  # keccak256("BlockCommit(uint256,bytes32,bytes32)")
  @block_commit_event "0x8f2916b2f2d78cc5890ead36c06c0f6d5d112c7e103589947e8e2f0d6eddb763"

  @doc """
    Checks if the oldest uncommitted batch in the database has the associated L1 commitment transaction
    by requesting new batch details from RPC. If so, analyzes the `BlockCommit` event emitted by
    the transaction to explore all the batches committed by it. For all discovered batches, it updates
    the database with new associations, importing information about L1 transactions.
    If it is found that some of the discovered batches are absent in the database, the function
    interrupts and returns the list of batch numbers that can be attempted to be recovered.

    ## Parameters
    - `config`: Configuration containing `json_l1_rpc_named_arguments` and
                `json_l2_rpc_named_arguments` defining parameters for the RPC connections.

    ## Returns
    - `:ok` if no new committed batches are found, or if all found batches and the corresponding L1
      transactions are imported successfully.
    - `{:recovery_required, batches_to_recover}` if the absence of new committed batches is
      discovered; `batches_to_recover` contains the list of batch numbers.
  """
  @spec look_for_batches_and_update(%{
          :json_l1_rpc_named_arguments => EthereumJSONRPC.json_rpc_named_arguments(),
          :json_l2_rpc_named_arguments => EthereumJSONRPC.json_rpc_named_arguments(),
          optional(any()) => any()
        }) :: :ok | {:recovery_required, list()}
  def look_for_batches_and_update(
        %{
          json_l1_rpc_named_arguments: json_l1_rpc_named_arguments,
          json_l2_rpc_named_arguments: json_l2_rpc_named_arguments
        } = _config
      ) do
    case Db.get_earliest_sealed_batch_number() do
      nil ->
        :ok

      expected_batch_number ->
        log_info("Checking if the batch #{expected_batch_number} was committed")

        {next_action, tx_hash, l1_txs} =
          check_if_batch_status_changed(expected_batch_number, :commit_tx, json_l2_rpc_named_arguments)

        case next_action do
          :skip ->
            :ok

          :look_for_batches ->
            log_info("The batch #{expected_batch_number} looks like committed")
            commit_tx_receipt = Rpc.fetch_tx_receipt_by_hash(tx_hash, json_l1_rpc_named_arguments)
            batches_from_rpc = get_committed_batches_from_logs(commit_tx_receipt["logs"])

            case prepare_batches_to_import(batches_from_rpc, %{commit_id: l1_txs[tx_hash][:id]}) do
              {:error, batches_to_recover} ->
                {:recovery_required, batches_to_recover}

              {:ok, committed_batches} ->
                Db.import_to_db(committed_batches, Map.values(l1_txs))
                :ok
            end
        end
    end
  end

  defp get_committed_batches_from_logs(logs) do
    committed_batches = Rpc.filter_logs_and_extract_topic_at(logs, @block_commit_event, 1)
    log_info("Discovered #{length(committed_batches)} committed batches in the commitment tx")

    committed_batches
  end
end