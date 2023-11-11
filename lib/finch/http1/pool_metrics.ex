defmodule Finch.HTTP1.PoolMetrics do
  @moduledoc """
  HTTP1 Pool metrics. TODO: Add more description
  """
  defstruct [
    :available_connections,
    :in_use_connections
  ]

  @atomic_idx [
    pool_size: 1,
    in_use_connections: 2
  ]

  def init(finch_name, shp, pool_size) do
    ref = :atomics.new(length(@atomic_idx), [])
    :atomics.put(ref, @atomic_idx[:pool_size], pool_size)
    :persistent_term.put({__MODULE__, finch_name, shp}, ref)
    {:ok, ref}
  end

  def maybe_add({_finch_name, _shp, %{start_pool_metrics?: false}}, _metrics_list), do: :ok

  def maybe_add({finch_name, shp, %{start_pool_metrics?: true}}, metrics_list) do
    ref = :persistent_term.get({__MODULE__, finch_name, shp})

    Enum.each(metrics_list, fn {metric_name, val} ->
      :atomics.add(ref, @atomic_idx[metric_name], val)
    end)
  end

  def get_pool_status(finch_name, shp) do
    case :persistent_term.get({__MODULE__, finch_name, shp}, nil) do
      nil ->
        {:error, :metrics_not_found}

      ref ->
        %{
          pool_size: pool_size,
          in_use_connections: in_use_connections
        } =
          @atomic_idx
          |> Enum.map(fn {k, idx} -> {k, :atomics.get(ref, idx)} end)
          |> Map.new()

        result = %__MODULE__{
          available_connections: pool_size - in_use_connections,
          in_use_connections: in_use_connections
        }

        {:ok, result}
    end
  end
end
