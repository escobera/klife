defmodule Klife.TestUtils do
  alias Klife.Connection.Broker
  alias Klife.Connection.Controller, as: ConnController
  alias KlifeProtocol.Messages, as: M
  alias Klife.PubSub

  @port_to_service_name %{
    19092 => "kafka1",
    29092 => "kafka2",
    39092 => "kafka3"
  }

  @docker_file_path Path.relative("test/compose_files/docker-compose.yml")

  defp get_service_name(cluster_name, broker_id) do
    content = %{include_cluster_authorized_operations: true, topics: []}

    {:ok, resp} = Broker.send_message(M.Metadata, cluster_name, :any, content)

    broker = Enum.find(resp.content.brokers, fn b -> b.node_id == broker_id end)

    @port_to_service_name[broker.port]
  end

  def stop_broker(cluster_name, broker_id) do
    Task.async(fn ->
      cb_ref = make_ref()
      :ok = PubSub.subscribe({:cluster_change, cluster_name}, cb_ref)

      service_name = get_service_name(cluster_name, broker_id)

      System.shell("docker-compose -f #{@docker_file_path} stop #{service_name} > /dev/null 2>&1")

      result =
        receive do
          {{:cluster_change, ^cluster_name}, event_data, ^cb_ref} ->
            removed_brokers = event_data.removed_brokers
            brokers_list = Enum.map(removed_brokers, fn {broker_id, _url} -> broker_id end)

            if broker_id in brokers_list,
              do: {:ok, service_name},
              else: {:error, :invalid_event}
        after
          10_000 ->
            {:error, :timeout}
        end

      :ok = PubSub.unsubscribe({:cluster_change, cluster_name})

      result
    end)
    |> Task.await(15_000)
  end

  def start_broker(service_name, cluster_name) do
    Task.async(fn ->
      cb_ref = make_ref()
      port_map = @port_to_service_name |> Enum.map(fn {k, v} -> {v, k} end) |> Map.new()
      expected_url = "localhost:#{port_map[service_name]}"

      :ok = PubSub.subscribe({:cluster_change, cluster_name}, cb_ref)

      old_brokers = :persistent_term.get({:known_brokers_ids, cluster_name})

      System.shell(
        "docker-compose -f #{@docker_file_path} start #{service_name} > /dev/null 2>&1"
      )

      :ok =
        Enum.reduce_while(1..20, nil, fn _, _acc ->
          :ok = ConnController.trigger_brokers_verification(cluster_name)
          new_brokers = :persistent_term.get({:known_brokers_ids, cluster_name})

          if old_brokers != new_brokers do
            {:halt, :ok}
          else
            Process.sleep(500)
            {:cont, nil}
          end
        end)

      result =
        receive do
          {{:cluster_change, ^cluster_name}, event_data, ^cb_ref} ->
            added_brokers = event_data.added_brokers

            case Enum.find(added_brokers, fn {_broker_id, url} -> url == expected_url end) do
              nil ->
                {:error, :invalid_event}

              {broker_id, ^expected_url} ->
                {:ok, broker_id}
            end
        after
          10_000 ->
            {:error, :timeout}
        end

      :ok = PubSub.unsubscribe({:cluster_change, cluster_name})

      result
    end)
    |> Task.await(25_000)
  end
end