# A supervisor that restarts a worker when it crashes (one_for_one).
defmodule Worker do
  use GenServer

  def start_link(reporter), do: GenServer.start_link(Worker, reporter)

  def init(reporter) do
    send(reporter, {:up, self()})
    {:ok, reporter}
  end

  def handle_cast(:crash, _state), do: raise "worker fell over"
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end

defmodule Demo do
  def run() do
    me = self()
    {:ok, _sup} = Supervisor.start_link([{Worker, me}], strategy: :one_for_one)

    first = receive do {:up, pid} -> pid end
    IO.puts "worker started"

    GenServer.cast(first, :crash)
    second = receive do {:up, pid} -> pid end
    IO.puts "worker restarted (new pid: #{first != second})"
    IO.puts "restarted worker answers: #{GenServer.call(second, :ping)}"
  end
end

Demo.run()
