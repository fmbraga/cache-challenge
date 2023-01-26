defmodule CacheTest do
  use ExUnit.Case
  doctest Cache

  test "no functions upon start" do
    {:ok, pid} = Cache.start_link()

    assert is_pid(pid)
    assert Cache.get(:foo) == {:error, :not_registered}

    Cache.stop()
  end

  test "register simple slow function" do
    slow_1 = fn ->
      :timer.sleep(1_000)
      {:ok, 1}
    end

    state = %Cache.State{}

    register =
      Cache.handle_call({:register_function, slow_1, :slow_1, 180_000, 60_000}, self(), state)

    assert elem(register, 0) == :reply
    assert elem(register, 1) == :ok

    state = elem(register, 2)
    assert state.__struct__ == Cache.State
    assert state.functions[:slow_1] == {slow_1, 180_000, 60_000}

    refresh = Cache.handle_info({:refresh, :slow_1}, state)
    assert elem(refresh, 0) == :noreply

    state = elem(refresh, 1)
    assert state.__struct__ == Cache.State
    assert %Task{} = state.in_progress[:slow_1]

    task = state.in_progress[:slow_1]
    assert Process.alive?(task.pid)
    assert_receive {:store, :slow_1, 1}, 2_000

    store = Cache.handle_info({:store, :slow_1, 1}, state)
    assert elem(store, 0) == :noreply

    state = elem(store, 1)
    assert state.__struct__ == Cache.State
    assert is_map(state.store)

    saved = Cache.Store.get(state.store, :slow_1)
    assert Map.get(saved, :value) == 1

    get = Cache.handle_call({:get, :slow_1, 30000}, self(), state)
    assert elem(get, 0) == :reply
    assert elem(get, 1) == {:ok, 1}
  end

  test "genserver functions" do
    slow_1 = fn ->
      :timer.sleep(1_000)
      {:ok, 1}
    end

    {:ok, _pid} = Cache.start_link()
    assert Cache.register_function(slow_1, :slow_1, 180_000, 60_000) == :ok
    assert Cache.get(:foo) == {:error, :not_registered}
    assert Cache.get(:slow_1) == {:ok, 1}

    Cache.stop()
  end

  test "timeout error" do
    slow_5 = fn ->
      :timer.sleep(5_000)
      {:ok, 5}
    end

    {:ok, _pid} = Cache.start_link()
    assert Cache.register_function(slow_5, :slow_5, 180_000, 60_000) == :ok
    assert Cache.get(:slow_5, 1000) == {:error, :timeout}

    Cache.stop()
  end

end
