defmodule Finch.HTTP1.PoolMetricsTest do
  use FinchCase, async: true

  alias Finch.HTTP1.PoolMetrics

  test "should not start atomics if opt is false", %{bypass: bypass, finch_name: finch_name} do
    start_supervised!(
      {Finch, name: finch_name, pools: %{default: [protocol: :http1, start_pool_metrics?: false]}}
    )

    shp = shp_from_bypass(bypass)

    parent = self()

    Bypass.expect(bypass, "GET", "/", fn conn ->
      ["number", number] = String.split(conn.query_string, "=")
      send(parent, {:ping_bypass, number})
      Plug.Conn.send_resp(conn, 200, "OK")
    end)

    refs =
      Enum.map(1..1, fn i ->
        Finch.build(:get, endpoint(bypass, "?number=#{i}"))
        |> Finch.async_request(finch_name)
      end)

    assert_receive {:ping_bypass, "1"}, 500

    Enum.each(refs, fn req_ref ->
      assert_receive {^req_ref, {:status, 200}}, 2000
    end)

    wait_connection_checkin()

    assert {:error, :metrics_not_found} = Finch.get_pool_status(finch_name, shp)
  end

  test "get pool status", %{bypass: bypass, finch_name: finch_name} do
    start_supervised!(
      {Finch, name: finch_name, pools: %{default: [protocol: :http1, start_pool_metrics?: true]}}
    )

    shp = shp_from_bypass(bypass)

    parent = self()

    Bypass.expect(bypass, "GET", "/", fn conn ->
      ["number", number] = String.split(conn.query_string, "=")
      send(parent, {:ping_bypass, number})

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

  defp shp_from_bypass(bypass), do: {:http, "localhost", bypass.port}

  defp wait_connection_checkin(), do: Process.sleep(5)
end
