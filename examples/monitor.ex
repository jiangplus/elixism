# Crash isolation with monitors: a worker crashes, the supervisor observes it.
defmodule Worker do
  def run(parent) do
    receive do
      {:divide, a, 0} -> raise "division by zero"
      {:divide, a, b} -> send(parent, {:result, div(a, b)})
    end
  end
end

defmodule Supervisor do
  def run() do
    me = self()
    worker = spawn(fn -> Worker.run(me) end)
    ref = Process.monitor(worker)
    send(worker, {:divide, 10, 0})
    receive do
      {:result, r}  -> IO.puts("got #{r}")
      {:DOWN, ^ref, :process, _pid, {:error, msg}} ->
        IO.puts("worker crashed: #{msg}")
    end
  end
end

Supervisor.run()
