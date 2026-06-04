# Two processes exchanging a message over the fiber scheduler.
defmodule Echo do
  def loop() do
    receive do
      {:ping, from} -> send(from, {:pong, self()})
    end
  end
end

defmodule Main do
  def run() do
    child = spawn(fn -> Echo.loop() end)
    send(child, {:ping, self()})
    receive do
      {:pong, _who} -> IO.puts("got pong!")
    end
  end
end

Main.run()
