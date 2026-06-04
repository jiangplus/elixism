# A GenServer: a key-value store with synchronous calls and async casts.
defmodule KV do
  use GenServer

  # Client API
  def start_link(), do: GenServer.start_link(KV, %{})
  def put(pid, k, v), do: GenServer.cast(pid, {:put, k, v})
  def get(pid, k), do: GenServer.call(pid, {:get, k})

  # Server callbacks
  def init(state), do: {:ok, state}
  def handle_cast({:put, k, v}, state), do: {:noreply, Map.put(state, k, v)}
  def handle_call({:get, k}, _from, state), do: {:reply, Map.get(state, k), state}
end

defmodule Demo do
  def run() do
    {:ok, kv} = KV.start_link()
    KV.put(kv, :name, "Alice")
    KV.put(kv, :role, "engineer")
    IO.puts "name: #{KV.get(kv, :name)}"
    IO.puts "role: #{KV.get(kv, :role)}"
  end
end

Demo.run()
