defmodule Finch.HTTP1.PoolMetrics do
  defstruct [
    :available_connections,
    :in_use_connections,
    :average_checkout_time,
    :max_checkout_time,
    :average_usage_time,
    :max_usage_time
  ]

  @atomic_idx [
    pool_size: 1,
    in_use_connections: 2,
    reset_lock: 3,
    reset_lock_queue: 4,
    total_checkout_count: 5,
    total_checkout_time: 6,
    total_usage_time: 7,
    max_checkout_time: 8,
    max_usage_time: 9
  ]

  @check_reset_lock_metrics [
    :total_checkout_count,
    :total_checkout_time,
    :total_usage_time,
    :max_checkout_time,
    :max_usage_time
  ]

  def init(finch_name, shp, pool_size) do
    ref = :atomics.new(length(@atomic_idx), [])
    :atomics.put(ref, @atomic_idx[:pool_size], pool_size)
    :persistent_term.put({__MODULE__, finch_name, shp}, ref)
    {:ok, ref}
  end

  def now(), do: System.monotonic_time(:microsecond)

  def add(finch_name, shp, metrics_list) do
    case :persistent_term.get({__MODULE__, finch_name, shp}, nil) do
      nil ->
        :ok

      ref ->
        Enum.each(metrics_list, fn {metric_name, val} -> maybe_add(ref, metric_name, val) end)
    end
  end

  def put_max(finch_name, shp, metrics_list) do
    case :persistent_term.get({__MODULE__, finch_name, shp}, nil) do
      nil ->
        :ok

      ref ->
        # This is a best effort approach and do not guarantee absolute max
        #
        # In some race condition edge case when a new value is set to
        # the atomic counter after the get and before the put the max
        # value may be overwritten by a lower one.
        Enum.each(metrics_list, fn {metric_name, val} -> maybe_put_max(ref, metric_name, val) end)
    end
  end

  def get_pool_status(finch_name, shp) do
    case :persistent_term.get({__MODULE__, finch_name, shp}, nil) do
      nil ->
        {:error, :metrics_not_found}

      ref ->
        %{
          pool_size: pool_size,
          in_use_connections: in_use_connections,
          total_checkout_count: total_checkout_count,
          total_checkout_time: total_checkout_time,
          total_usage_time: total_usage_time,
          max_checkout_time: max_checkout_time,
          max_usage_time: max_usage_time
        } =
          @atomic_idx
          |> Enum.map(fn {k, idx} -> {k, :atomics.get(ref, idx)} end)
          |> Map.new()

        result = %__MODULE__{
          available_connections: pool_size - in_use_connections,
          in_use_connections: in_use_connections,
          average_checkout_time: safe_round_div(total_checkout_time, total_checkout_count),
          max_checkout_time: max_checkout_time,
          average_usage_time: safe_round_div(total_usage_time, total_checkout_count),
          max_usage_time: max_usage_time
        }

        {:ok, result}
    end
  end

  def reset_metrics(finch_name, shp, timeout \\ 5_000) do
    case :persistent_term.get({__MODULE__, finch_name, shp}, nil) do
      nil ->
        :ok

      ref ->
        do_reset_metrics(ref, finch_name, shp, System.monotonic_time(:millisecond) + timeout)
    end
  end

  defp do_reset_metrics(ref, finch_name, shp, deadline) do
    :atomics.put(ref, @atomic_idx[:reset_lock], 1)

    cond do
      System.monotonic_time(:millisecond) > deadline ->
        # This is a very unlikely scenario but in order to guarantee
        # that no write will happen mid reset we must wait for every
        # other process terminate it write before we can reset to 0
        #
        # This is done by a queue counter that every process increment
        # before write and decrement after. Using a lockc to prevent
        # new entries on the queue we can guarantee that the queue
        # will eventually comes to 0 but we need a deadline here
        # just in case the system is under extremely high load.
        # 
        # It is important to notice that if this error is returned 
        # chances are the metrics may be slightly wrong because of
        # some metrics being writen whitout their counter parts.
        # 
        # For instance, one checkout counter may be added withou add
        # the total usage time counter part, effectivelly lowering
        # the average.
        #
        # Metrics that are not affected by reset locks are not affected
        # by this potential error.
        :atomics.put(ref, @atomic_idx[:reset_lock], 0)
        {:error, :timeout}

      :atomics.get(ref, @atomic_idx[:reset_lock_queue]) > 0 ->
        Process.sleep(5)
        do_reset_metrics(ref, finch_name, shp, deadline)

      true ->
        Enum.each(@atomic_idx, fn {metric, idx} ->
          if metric in @check_reset_lock_metrics,
            do: :atomics.put(ref, idx, 0),
            else: :ok
        end)

        :atomics.put(ref, @atomic_idx[:reset_lock], 0)
        :ok
    end
  end

  defp safe_round_div(0, 0), do: 0
  defp safe_round_div(dividend, divisor), do: round(dividend / divisor)

  defp maybe_add(ref, metric_name, val) when metric_name in @check_reset_lock_metrics do
    if :atomics.get(ref, @atomic_idx[:reset_lock]) == 0,
      do: with_lock(ref, fn -> :atomics.add(ref, @atomic_idx[metric_name], val) end),
      else: :ok
  end

  defp maybe_add(ref, metric_name, val) do
    :atomics.add(ref, @atomic_idx[metric_name], val)
  end

  defp maybe_put_max(ref, metric_name, val) when metric_name in @check_reset_lock_metrics do
    if :atomics.get(ref, @atomic_idx[:reset_lock]) == 0,
      do: with_lock(ref, fn -> do_put_max(ref, metric_name, val) end),
      else: :ok
  end

  defp maybe_put_max(ref, metric_name, val) do
    do_put_max(ref, metric_name, val)
  end

  defp do_put_max(ref, metric_name, val) do
    idx = @atomic_idx[metric_name]
    # This is a best effort approach and do not guarantee absolute max
    #
    # In some race condition edge case when a new value is set to
    # the atomic counter after the get and before the put the max
    # value may be overwritten by a lower one.
    if val > :atomics.get(ref, idx),
      do: :atomics.put(ref, idx, val),
      else: :ok
  end

  defp with_lock(ref, fun) do
    reset_lock_queue_idx = @atomic_idx[:reset_lock_queue]
    :atomics.add(ref, reset_lock_queue_idx, 1)
    res = fun.()
    :atomics.sub(ref, reset_lock_queue_idx, 1)
    res
  end
end
