defmodule Finch.HTTP1.PoolMetricsTest do
  use FinchCase, async: true

  use Mimic

  alias Finch.HTTP1.PoolMetrics

  test "get pool status", %{bypass: bypass, finch_name: finch_name} do
    start_supervised!(
      {Finch, name: finch_name, pools: %{default: [protocol: :http1, start_pool_metrics: true]}}
    )

    shp = shp_from_bypass(bypass)

    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "OK")
    end)

    PoolMetrics
    |> expect(:now, fn -> 10 end)
    |> expect(:now, fn -> 15 end)
    |> expect(:now, fn -> 30 end)

    assert {:ok, %{status: 200}} =
             Finch.build(:get, endpoint(bypass))
             |> Finch.request(finch_name)

    wait_connection_checkin()

    assert {:ok,
            %PoolMetrics{
              available_connections: 50,
              in_use_connections: 0,
              average_checkout_time: 5,
              max_checkout_time: 5,
              average_usage_time: 15,
              max_usage_time: 15
            }} = Finch.get_pool_status(finch_name, shp)
  end

  test "get pool status - multiple metrics", %{bypass: bypass, finch_name: finch_name} do
    start_supervised!(
      {Finch, name: finch_name, pools: %{default: [protocol: :http1, start_pool_metrics: true]}}
    )

    shp = shp_from_bypass(bypass)

    Bypass.expect(bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "OK")
    end)

    Enum.each(1..10, fn i ->
      PoolMetrics
      |> expect(:now, fn -> 10 end)
      |> expect(:now, fn -> 10 + i * 2 end)
      |> expect(:now, fn -> 10 + i * 2 + i * 3 end)

      assert {:ok, %{status: 200}} =
               Finch.build(:get, endpoint(bypass))
               |> Finch.request(finch_name)
    end)

    wait_connection_checkin()

    checkout_times = Enum.map(1..10, fn i -> i * 2 end)
    usage_times = Enum.map(1..10, fn i -> i * 3 end)

    expected_checkout_avg = round(Enum.sum(checkout_times) / 10)
    expected_usage_avg = round(Enum.sum(usage_times) / 10)

    assert {:ok,
            %PoolMetrics{
              available_connections: 50,
              in_use_connections: 0,
              average_checkout_time: ^expected_checkout_avg,
              max_checkout_time: 20,
              average_usage_time: ^expected_usage_avg,
              max_usage_time: 30
            }} = Finch.get_pool_status(finch_name, shp)
  end

  test "get pool status - in use connections", %{bypass: bypass, finch_name: finch_name} do
    start_supervised!(
      {Finch, name: finch_name, pools: %{default: [protocol: :http1, start_pool_metrics: true]}}
    )

    shp = shp_from_bypass(bypass)

    parent = self()

    Bypass.expect(bypass, "GET", "/", fn conn ->
      ["number", number] = String.split(conn.query_string, "=")
      if number == "20", do: send(parent, {:ping_bypass, number})

      Process.sleep(:timer.seconds(1))
      Plug.Conn.send_resp(conn, 200, "OK")
    end)

    refs =
      Enum.map(1..20, fn i ->
        Finch.build(:get, endpoint(bypass, "?number=#{i}"))
        |> Finch.async_request(finch_name)
      end)

    assert_receive {:ping_bypass, "20"}, 500

    assert {:ok,
            %PoolMetrics{
              available_connections: 30,
              in_use_connections: 20
            }} = Finch.get_pool_status(finch_name, shp)

    Enum.each(refs, fn req_ref ->
      assert_receive {^req_ref, {:status, 200}}, 2000
    end)

    wait_connection_checkin()

    assert {:ok,
            %PoolMetrics{
              available_connections: 50,
              in_use_connections: 0
            }} = Finch.get_pool_status(finch_name, shp)
  end

  test "reset pool metrics", %{bypass: bypass, finch_name: finch_name} do
    start_supervised!(
      {Finch, name: finch_name, pools: %{default: [protocol: :http1, start_pool_metrics: true]}}
    )

    shp = shp_from_bypass(bypass)

    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "OK")
    end)

    PoolMetrics
    |> expect(:now, fn -> 10 end)
    |> expect(:now, fn -> 15 end)
    |> expect(:now, fn -> 30 end)

    assert {:ok, %{status: 200}} =
             Finch.build(:get, endpoint(bypass))
             |> Finch.request(finch_name)

    wait_connection_checkin()

    assert {:ok,
            %PoolMetrics{
              available_connections: 50,
              in_use_connections: 0,
              average_checkout_time: 5,
              max_checkout_time: 5,
              average_usage_time: 15,
              max_usage_time: 15
            }} = Finch.get_pool_status(finch_name, shp)

    assert :ok = PoolMetrics.reset_metrics(finch_name, shp)

    assert {:ok,
            %PoolMetrics{
              available_connections: 50,
              in_use_connections: 0,
              average_checkout_time: 0,
              max_checkout_time: 0,
              average_usage_time: 0,
              max_usage_time: 0
            }} = Finch.get_pool_status(finch_name, shp)
  end

  defp shp_from_bypass(bypass), do: {:http, "localhost", bypass.port}

  defp wait_connection_checkin(), do: Process.sleep(5)
end
