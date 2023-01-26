defmodule Cache do
  defmodule State do
    @type t :: %__MODULE__{
            in_progress: %{any() => pid()},
            ttl: %{any() => any()},
            store: %{any() => %{value: any(), expires_at: integer()}},
            functions: %{any() => {function(), integer(), integer()}}
          }

    @moduledoc false
    defstruct in_progress: %{}, ttl: %{}, store: %{}, functions: %{}
  end

  use GenServer
  require Logger

  @type result ::
          {:ok, any()}
          | {:error, :timeout}
          | {:error, :not_registered}

  def start_link(opts \\ []) do
    start_opts =
      [name: __MODULE__]
      |> Keyword.merge(opts)

    GenServer.start_link(__MODULE__, %{}, start_opts)
  end

  def stop(), do: GenServer.stop(__MODULE__)

  @impl GenServer
  def init(state) do
    {:ok, Map.merge(state, %State{})}
  end

  ## +-----------------------------------------------------------------+
  ## Client API

  @doc ~s"""
  Get the value associated with `key`.

  Details:
    - If the value for `key` is stored in the cache, the value is returned
      immediately.
    - If a recomputation of the function is in progress, the last stored value
      is returned.
    - If the value for `key` is not stored in the cache but a computation of
      the function associated with this `key` is in progress, wait up to
      `timeout` milliseconds. If the value is computed within this interval,
      the value is returned. If the computation does not finish in this
      interval, `{:error, :timeout}` is returned.
    - If `key` is not associated with any function, return `{:error,
      :not_registered}`
  """
  @spec get(any(), non_neg_integer(), Keyword.t()) :: result
  def get(key, timeout \\ 30_000, _opts \\ []) when is_integer(timeout) and timeout > 0 do
    GenServer.call(__MODULE__, {:get, key, timeout})
  end

  @doc ~s"""
  Registers a function that will be computed periodically to update the cache.

  Arguments:
    - `fun`: a 0-arity function that computes the value and returns either
      `{:ok, value}` or `{:error, reason}`.
    - `key`: associated with the function and is used to retrieve the stored
    value.
    - `ttl` ("time to live"): how long (in milliseconds) the value is stored
      before it is discarded if the value is not refreshed.
    - `refresh_interval`: how often (in milliseconds) the function is
      recomputed and the new value stored. `refresh_interval` must be strictly
      smaller than `ttl`. After the value is refreshed, the `ttl` counter is
      restarted.

  The value is stored only if `{:ok, value}` is returned by `fun`. If `{:error,
  reason}` is returned, the value is not stored and `fun` must be retried on
  the next run.
  """
  @spec register_function(
          fun :: (() -> {:ok, any()} | {:error, any()}),
          key :: any,
          ttl :: non_neg_integer(),
          refresh_interval :: non_neg_integer()
        ) :: :ok | {:error, :already_registered}
  def register_function(fun, key, ttl, refresh_interval)
      when is_function(fun, 0) and is_integer(ttl) and ttl > 0 and
             is_integer(refresh_interval) and
             refresh_interval < ttl do
    GenServer.call(__MODULE__, {:register_function, fun, key, ttl, refresh_interval})
  end

  ## +-----------------------------------------------------------------+
  ## Internal functions

  @doc ~s"""
  `{:get, key, timeout}`
    Get the value associated with `key`. `internal_get` handles all conditional responses to current state

  `{:register_function, fun, key, ttl, refresh_interval}`
    Register a new function to be computed periodically to update the cache. It will command
  the cache to update the value associated with `key` immediately.

  """
  @impl GenServer
  def handle_call({:get, key, timeout}, _from, state) do
    in_progress = Map.get(state.in_progress, key)
    {:reply, internal_get(state.store, key, timeout, in_progress), state}
  end

  def handle_call({:register_function, fun, key, ttl, refresh_interval}, _from, state) do
    Process.send(self(), {:refresh, key}, [])

    {:reply, :ok,
     %{state | functions: Map.put(state.functions, key, {fun, ttl, refresh_interval})}}
  end

  @doc ~s"""
  `{:refresh, key}`
    Refresh the value associated with `key` by recomputing the function associated with it on another process.
  It will flag the key as being `in_progress`. Will start a new task to compute the value and send message to
  store it in the cache.

  If the function returns an error, it will retry according to refresh_interval.

  `{:store, key, value}`
    Saves the value in the cache and removes the key from `in_progress`
  """
  @impl GenServer
  def handle_info({:refresh, key}, state) do
    {fun, _ttl, refresh_interval} = Map.get(state.functions, key, {nil, nil, nil})

    pid = self()

    ## TODO: don't start a new task if one is already in progress
    task =
      Task.async(fn ->
        with {:ok, value} <- fun.() do
          Process.send(pid, {:store, key, value}, [])
          {:ok, key, value}
        else
          {:error, reason} ->
            Logger.warn("Error while computing value for #{key}: #{inspect(reason)}")
            Process.send_after(self(), {:refresh, key}, refresh_interval, [])
            {:error, key, reason}
        end
      end)

    {:noreply, %{state | in_progress: Map.put(state.in_progress, key, task)}}
  end

  def handle_info({:remove, key}, state) do
      Map.get(state.ttl, key, [])
      |> Enum.map(&Process.cancel_timer/1)
      |> dbg(pretty: true)

      {:noreply, %{state |
          store: Map.delete(state.store, key),
          ttl: Map.delete(state.ttl, key)}
      }
  end

  def handle_info({:store, key, value}, state) do
    %{functions: functions, store: store} = state
    {_fun, ttl, refresh_interval} = Map.get(functions, key, {nil, nil, nil})
    new_store = Cache.Store.store(store, key, value, refresh_interval, ttl)

    timer_ref = [
        Process.send_after(self(), {:refresh, key}, refresh_interval, []),
        Process.send_after(self(), {:remove, key}, ttl, [])
    ]

    Map.get(state.ttl, key, [])
    |> Enum.map(&Process.cancel_timer/1)

    {:noreply, %{state | store: new_store,
        in_progress: Map.delete(state.in_progress, key),
        ttl: Map.put(state.ttl, key, timer_ref)}
    }
  end

  def handle_info({_task_ref, {:ok, key, value}}, state) do
    handle_info({:store, key, value}, state)
  end

  def handle_info({task_ref, {:error, key, _reason}}, state) when is_reference(task_ref) do
    {:noreply, %{state | in_progress: Map.delete(state.in_progress, key)}}
  end

  def handle_info({:DOWN, task_ref, _, _, _}, state) when is_reference(task_ref) do
      {:noreply, state}
  end

  ## +-----------------------------------------------------------------+
  ## Private functions

  defp internal_get(store, key, _timeout, nil) do
    Map.get(store, key)
    |> case do
      nil -> {:error, :not_registered}
      %{value: value} -> {:ok, value}
    end
  end

  defp internal_get(store, key, timeout, task) do
    Map.get(store, key)
    |> case do
      nil -> wait_for_task(task, timeout)
      %{value: value} -> {:ok, value}
    end
  end

  @doc ~s"""
  Wait for a task to finish and return the result. If the task does not finish
  within `timeout` milliseconds, return `{:error, :timeout}`. If the async task returned an error,
  and have already exited
  """
  def wait_for_task(task, timeout) do
    with {:ok, reply} <- Task.yield(task, timeout) do
      case reply do
        {:ok, _key, value} -> {:ok, value}
        {:error, :timeout} -> {:error, :timeout}
        {:error, _key, reason} -> {:error, reason}
        _ -> {:error, :timeout}
      end
    else
      nil             -> {:error, :timeout}
      {:exit, reason} -> {:error, reason}
    end
  end

  ## +-----------------------------------------------------------------+
  ## Helpers
end

defmodule Cache.Store do
  @default_refresh 900_000
  @default_ttl 3_600_000

  def store(store, key, value, refresh_interval \\ @default_refresh, ttl \\ @default_ttl) do
    now = DateTime.utc_now() |> DateTime.to_unix()

    Map.put(store, key, %{
      value: value,
      refresh_at: now + refresh_interval,
      expires_at: now + ttl
    })
  end

  def get(store, key) do
    Map.get(store, key, %{value: nil, refresh_at: 0, expires_at: 0})
  end
end
