defmodule Raxol.Performance.Optimizer do
  @moduledoc """
  Refactored Performance optimization strategies with GenServer-based memoization.

  This module provides the same optimization techniques as the original but uses
  supervised state management instead of Process dictionary for memoization.
  """

  @compile {:no_warn_undefined, :poolboy}

  import Raxol.Performance.Profiler
  alias Raxol.Core.Runtime.Log
  @default_timeout_ms Raxol.Core.Defaults.timeout_ms()

  @doc """
  Optimizes database queries to prevent N+1 problems.

  ## Examples

      # Before optimization
      users = Repo.all(User)
      users_with_posts = Enum.map(users, fn user ->
        %{user | posts: Repo.all(assoc(user, :posts))}
      end)

      # After optimization
      users_with_posts = optimize_query do
        User |> preload(:posts) |> Repo.all()
      end
  """
  defmacro optimize_query(do: query) do
    quote do
      # Profile the query first
      profile :database_query, metadata: %{optimized: true} do
        unquote(query)
      end
    end
  end

  @doc """
  Implements caching for expensive operations.

  ## Options

  - `:ttl` - Time to live in milliseconds (default: 60_000)
  - `:key` - Cache key (required)
  - `:refresh` - Whether to refresh cache on hit (default: false)

  ## Examples

      cached :expensive_calculation, key: "calc_123", ttl: 300_000 do
        perform_expensive_calculation(123)
      end
  """
  defmacro cached(operation, opts, do: block) do
    quote do
      Raxol.Performance.Optimizer.execute_with_cache(
        unquote(operation),
        unquote(opts),
        fn -> unquote(block) end
      )
    end
  end

  @doc """
  Implements lazy loading for large datasets.

  ## Examples

      lazy_stream :large_file_reader do
        File.stream!("large_file.txt")
        |> Stream.map(&process_line/1)
      end
  """
  defmacro lazy_stream(operation, do: stream) do
    quote do
      profile unquote(operation), metadata: %{lazy: true} do
        unquote(stream)
      end
    end
  end

  @doc """
  Memoizes function results to avoid recomputation.

  Now uses GenServer-based caching instead of Process dictionary.

  ## Examples

      defmodule Calculator do
        use Raxol.Performance.Optimizer
  alias Raxol.Core.Runtime.Log

        memoize expensive_calculation(n) do
          # Complex calculation
          factorial(n) * fibonacci(n)
        end
      end
  """
  defmacro memoize({name, _, args} = _call, do: body) do
    key = {name, args}

    quote do
      Raxol.Performance.Optimizer.ensure_memoization_server()

      Raxol.Performance.Memoization.Server.get_or_compute(
        unquote(key),
        fn -> unquote(body) end
      )
    end
  end

  @doc """
  Optimizes concurrent operations using Task.async_stream.

  ## Options

  - `:max_concurrency` - Maximum concurrent tasks (default: System.schedulers_online())
  - `:timeout` - Task timeout in milliseconds (default: 5000)
  - `:ordered` - Maintain order of results (default: true)

  ## Examples

      concurrent_map users, &send_email/1, max_concurrency: 10
  """
  def concurrent_map(enumerable, fun, opts \\ []) do
    max_concurrency =
      Keyword.get(opts, :max_concurrency, System.schedulers_online())

    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    ordered = Keyword.get(opts, :ordered, true)

    profile :concurrent_operation, metadata: %{concurrency: max_concurrency} do
      enumerable
      |> Task.async_stream(fun,
        max_concurrency: max_concurrency,
        timeout: timeout,
        ordered: ordered
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, reason}
      end)
    end
  end

  @doc """
  Batches operations to reduce overhead.

  ## Examples

      batch_process records, batch_size: 100 do |batch|
        Repo.insert_all(Record, batch)
      end
  """
  def batch_process(enumerable, opts, fun) do
    batch_size = Keyword.get(opts, :batch_size, 100)

    enumerable
    |> Stream.chunk_every(batch_size)
    |> Enum.each(fn batch ->
      profile :batch_operation, metadata: %{batch_size: length(batch)} do
        fun.(batch)
      end
    end)
  end

  @doc """
  Optimizes string concatenation for better performance.

  ## Examples

      # Instead of multiple concatenations
      result = str1 <> str2 <> str3 <> str4

      # Use
      result = string_builder([str1, str2, str3, str4])
  """
  def string_builder(parts) when is_list(parts) do
    profile :string_building, metadata: %{parts: length(parts)} do
      IO.iodata_to_binary(parts)
    end
  end

  @doc """
  Implements circuit breaker pattern for external calls.
  """
  def with_circuit_breaker(name, fun, opts \\ []) do
    profile :circuit_breaker_call, metadata: %{circuit: name} do
      Raxol.Core.ErrorRecovery.with_circuit_breaker(name, fun, opts)
    end
  end

  @doc """
  Optimizes list operations using appropriate data structures.

  ## Examples

      # For frequent prepends, use lists
      optimize_list_ops :prepend, initial_list do |list|
        [new_item | list]
      end

      # For frequent lookups, convert to map
      optimize_list_ops :lookup, list do |list|
        Map.new(list, & {&1.id, &1})
      end
  """
  def optimize_list_ops(operation_type, data, transformer) do
    profile :"list_ops_#{operation_type}",
      metadata: %{size: length_or_size(data)} do
      transformer.(data)
    end
  end

  @doc """
  Reduces memory usage by implementing streaming where possible.

  ## Examples

      stream_process "large_file.csv" do |line|
        parse_csv_line(line)
        |> process_record()
      end
  """
  def stream_process(file_path, processor) do
    profile :stream_processing, metadata: %{file: file_path} do
      File.stream!(file_path)
      |> Stream.map(processor)
      |> Stream.run()
    end
  end

  @doc """
  Optimizes ETS table operations.

  ## Examples

      ets_batch_insert(:my_table, records, batch_size: 1000)
  """
  def ets_batch_insert(table, records, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 1000)

    records
    |> Stream.chunk_every(batch_size)
    |> Enum.each(fn batch ->
      profile :ets_batch_insert,
        metadata: %{table: table, size: length(batch)} do
        :ets.insert(table, batch)
      end
    end)
  end

  @doc """
  Implements connection pooling for external resources.

  Uses poolboy if available, otherwise creates a simple connection pool using Registry.

  ## Examples

      with_pooled_connection(:database, fn conn ->
        MyRepo.query(conn, "SELECT * FROM users")
      end)
  """
  def with_pooled_connection(pool_name, fun) when is_function(fun, 1) do
    profile :pooled_connection, metadata: %{pool: pool_name} do
      case poolboy_available?() do
        true ->
          :poolboy.transaction(pool_name, fun)

        false ->
          # Fallback to simple connection management
          case get_or_create_connection(pool_name) do
            {:ok, conn} ->
              execute_with_connection(pool_name, conn, fun)

            {:error, reason} ->
              Log.warning(
                "Failed to get connection from pool #{pool_name}: #{inspect(reason)}"
              )

              {:error, :connection_unavailable}
          end
      end
    end
  end

  def with_pooled_connection(pool_name, fun) when is_function(fun, 0) do
    # For compatibility with zero-arity functions
    profile :pooled_connection, metadata: %{pool: pool_name} do
      case poolboy_available?() do
        true -> :poolboy.transaction(pool_name, fn _conn -> fun.() end)
        false -> fun.()
      end
    end
  end

  @doc """
  Initializes a connection pool with the given configuration.

  ## Options

  - `:size` - Pool size (default: 5)
  - `:max_overflow` - Maximum overflow connections (default: 10)
  - `:worker` - Worker module for connections
  - `:worker_args` - Arguments for worker initialization

  ## Examples

      init_connection_pool(:database,
        size: 5,
        max_overflow: 10,
        worker: MyConnectionWorker,
        worker_args: [host: "localhost", port: 5432]
      )
  """
  def init_connection_pool(pool_name, opts \\ []) do
    case poolboy_available?() do
      true -> init_poolboy_pool(pool_name, opts)
      false -> init_simple_pool(pool_name, opts)
    end
  end

  @doc """
  Optimizes GenServer calls by batching.

  ## Examples

      batch_genserver_calls(MyServer, messages, batch_size: 50)
  """
  def batch_genserver_calls(server, messages, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 50)
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    messages
    |> Stream.chunk_every(batch_size)
    |> Enum.map(fn batch ->
      profile :batched_genserver_call,
        metadata: %{server: server, batch_size: length(batch)} do
        GenServer.call(server, {:batch, batch}, timeout)
      end
    end)
  end

  @doc """
  Implements read-through cache pattern.
  """
  def read_through_cache(key, loader, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, 60_000)
    cache_name = Keyword.get(opts, :cache, :default_cache)

    case lookup_cache(cache_name, key) do
      {:ok, value} ->
        profile :cache_hit, metadata: %{key: key} do
          value
        end

      :miss ->
        profile :cache_miss, metadata: %{key: key} do
          value = loader.()
          store_cache(cache_name, key, value, ttl)
          value
        end
    end
  end

  @doc """
  Optimizes recursive operations using tail recursion.

  ## Examples

      # Convert recursive function to tail-recursive
      def sum([]), do: 0
      def sum([h | t]), do: h + sum(t)

      # Becomes
      tail_recursive_sum(list)
  """
  def tail_recursive_sum(list), do: do_sum(list, 0)
  defp do_sum([], acc), do: acc
  defp do_sum([h | t], acc), do: do_sum(t, acc + h)

  @doc """
  Profiles and suggests algorithm improvements.
  """
  def analyze_algorithm(name, implementations) do
    results =
      Enum.map(implementations, fn {impl_name, fun} ->
        result =
          benchmark(:"#{name}_#{impl_name}", iterations: 1000) do
            fun.()
          end

        {impl_name, result}
      end)

    best =
      results
      |> Enum.min_by(fn {_, stats} -> stats.mean end)
      |> elem(0)

    %{
      results: results,
      recommendation: "Use #{best} implementation",
      improvement_potential: calculate_improvement_potential(results)
    }
  end

  def execute_with_cache(operation, opts, fun) do
    key = Keyword.fetch!(opts, :key)
    ttl = Keyword.get(opts, :ttl, 60_000)
    refresh = Keyword.get(opts, :refresh, false)

    cache_key = {operation, key}

    case get_from_cache(cache_key) do
      {:ok, value} when not refresh ->
        value

      _ ->
        value =
          profile operation, metadata: %{cache_miss: true} do
            fun.()
          end

        put_in_cache(cache_key, value, ttl)
        value
    end
  end

  # Private functions

  defp poolboy_available? do
    Code.ensure_loaded?(:poolboy)
  end

  defp init_poolboy_pool(pool_name, opts) do
    pool_config = [
      name: {:local, pool_name},
      worker_module:
        Keyword.get(opts, :worker, Raxol.Performance.DefaultWorker),
      size: Keyword.get(opts, :size, 5),
      max_overflow: Keyword.get(opts, :max_overflow, 10)
    ]

    worker_args = Keyword.get(opts, :worker_args, [])

    case :poolboy.start_link(pool_config, worker_args) do
      {:ok, _pid} -> {:ok, pool_name}
      {:error, reason} -> {:error, reason}
    end
  end

  defp init_simple_pool(pool_name, _opts) do
    # Simple connection tracking using Registry
    registry_name = :"#{pool_name}_connections"

    case Registry.start_link(keys: :unique, name: registry_name) do
      {:ok, _pid} ->
        Log.info("Initialized simple connection pool: #{pool_name}")
        {:ok, pool_name}

      {:error, {:already_started, _pid}} ->
        {:ok, pool_name}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_or_create_connection(pool_name) do
    registry_name = :"#{pool_name}_connections"
    connection_id = "conn_#{System.unique_integer([:positive])}"

    case Registry.register(registry_name, connection_id, %{
           created_at: DateTime.utc_now()
         }) do
      {:ok, _pid} ->
        # In a real implementation, this would create an actual connection
        # For now, return a mock connection identifier
        {:ok, %{id: connection_id, pool: pool_name}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp return_connection(pool_name, conn) do
    registry_name = :"#{pool_name}_connections"
    Registry.unregister(registry_name, conn.id)
    :ok
  end

  defp get_from_cache(key) do
    case :persistent_term.get({:cache, key}, :not_found) do
      {:cached, value, expiry} ->
        case expiry > System.system_time(:millisecond) do
          true -> {:ok, value}
          false -> :miss
        end

      _ ->
        :miss
    end
  end

  defp put_in_cache(key, value, ttl) do
    expiry = System.system_time(:millisecond) + ttl
    :persistent_term.put({:cache, key}, {:cached, value, expiry})
  end

  defp lookup_cache(_cache_name, key) do
    get_from_cache(key)
  end

  defp store_cache(_cache_name, key, value, ttl) do
    put_in_cache(key, value, ttl)
  end

  defp length_or_size(data) when is_list(data), do: length(data)
  defp length_or_size(data) when is_map(data), do: map_size(data)
  defp length_or_size(_), do: 0

  defp calculate_improvement_potential(results) do
    times = Enum.map(results, fn {_, stats} -> stats.mean end)
    best = Enum.min(times)
    worst = Enum.max(times)

    %{
      absolute: worst - best,
      percentage: (worst - best) / worst * 100
    }
  end

  defp execute_with_connection(pool_name, conn, fun) do
    case Raxol.Core.ErrorHandling.safe_call(fn -> fun.(conn) end) do
      {:ok, result} ->
        return_connection(pool_name, conn)
        result

      {:error, reason} ->
        return_connection(pool_name, conn)
        {:error, reason}
    end
  end
end
