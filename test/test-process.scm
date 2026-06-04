;;; Process / concurrency tests (fiber scheduler).
;;; SPDX-License-Identifier: Apache-2.0
(define-module (test test-process)
  #:use-module (test harness)
  #:use-module (elixir eval)
  #:use-module (elixir runtime)
  #:export (run))

(define (ev src) (reset-elixir!) (elixir-run src))
(define (ev* src) (reset-elixir!) (inspect (elixir-run src)))

;; Shared program: 3 supervised workers a/b/c; crash :b and report which
;; (by id) get restarted under the given strategy.
(define (supervisor-test strategy)
  (string-append "
defmodule W do
  use GenServer
  def start_link({rep, id}), do: GenServer.start_link(W, {rep, id})
  def init({rep, id}) do
    send(rep, {:up, id, self()})
    {:ok, {rep, id}}
  end
  def handle_cast(:crash, _s), do: raise \"x\"
end
defmodule M do
  def run() do
    me = self()
    {:ok, _} = Supervisor.start_link(
      [{W, {me, :a}}, {W, {me, :b}}, {W, {me, :c}}], strategy: :" strategy ")
    pids = collect(me, %{}, 3)
    GenServer.cast(Map.get(pids, :b), :crash)
    Enum.sort(drain(me, []))
  end
  def collect(_me, acc, 0), do: acc
  def collect(me, acc, n) do
    receive do {:up, id, pid} -> collect(me, Map.put(acc, id, pid), n - 1) end
  end
  def drain(me, acc) do
    receive do {:up, id, _} -> drain(me, [id | acc]) after 20 -> acc end
  end
end
M.run()"))

(define (run)
  (run-suite "process"
   (lambda ()
     (deftest "self returns a pid"
       (assert-equal 'true (ev "p = self()\np == self()")))

     (deftest "spawn returns and runs"
       (assert-equal 'spawned (ev "
defmodule W do
  def go(parent), do: send(parent, :spawned)
end
defmodule M do
  def run() do
    me = self()
    spawn(fn -> W.go(me) end)
    receive do msg -> msg end
  end
end
M.run()")))

     (deftest "ping-pong"
       (assert-equal 'got_pong (ev "
defmodule Echo do
  def loop() do
    receive do
      {:ping, from} -> send(from, {:pong, self()})
    end
  end
end
defmodule M do
  def run() do
    c = spawn(fn -> Echo.loop() end)
    send(c, {:ping, self()})
    receive do
      {:pong, _} -> :got_pong
    end
  end
end
M.run()")))

     (deftest "stateful counter (recursion in receive)"
       (assert-equal 3 (ev "
defmodule Counter do
  def loop(n) do
    receive do
      {:inc, from} -> send(from, :ok); loop(n + 1)
      {:get, from} -> send(from, n)
    end
  end
end
defmodule M do
  def run() do
    c = spawn(fn -> Counter.loop(0) end)
    send(c, {:inc, self()})
    receive do _ -> :ok end
    send(c, {:inc, self()})
    receive do _ -> :ok end
    send(c, {:inc, self()})
    receive do _ -> :ok end
    send(c, {:get, self()})
    receive do n -> n end
  end
end
M.run()")))

     (deftest "selective receive (out-of-order match)"
       (assert-equal 'second (ev "
defmodule M do
  def run() do
    send(self(), {:a, :first})
    send(self(), {:b, :second})
    receive do
      {:b, v} -> v
    end
  end
end
M.run()")))

     (deftest "receive timeout fires"
       (assert-equal 'timed_out (ev "
receive do
  {:never, _} -> :got
after
  10 -> :timed_out
end")))

     (deftest "timeout not taken when message present"
       (assert-equal 'got (ev "
defmodule M do
  def run() do
    send(self(), :hello)
    receive do
      :hello -> :got
    after
      10 -> :timed_out
    end
  end
end
M.run()")))

     (deftest "monitor receives DOWN on crash"
       (assert-equal 'down (ev "
defmodule W do
  def go(), do: raise \"boom\"
end
defmodule M do
  def run() do
    pid = spawn(fn -> W.go() end)
    ref = Process.monitor(pid)
    receive do
      {:DOWN, ^ref, :process, _p, _reason} -> :down
    end
  end
end
M.run()")))

     (deftest "monitor reports crash reason"
       (assert-equal "boom" (ev "
defmodule W do
  def go(), do: raise \"boom\"
end
defmodule M do
  def run() do
    pid = spawn(fn -> W.go() end)
    ref = Process.monitor(pid)
    receive do
      {:DOWN, ^ref, :process, _p, {:error, msg}} -> msg
    end
  end
end
M.run()")))

     (deftest "spawn_link propagates crash"
       (assert-equal 'propagated (ev "
defmodule M do
  def run() do
    p = spawn(fn ->
      spawn_link(fn -> raise \"x\" end)
      receive do _ -> :never end
    end)
    ref = Process.monitor(p)
    receive do
      {:DOWN, ^ref, :process, _, _} -> :propagated
    end
  end
end
M.run()")))

     (deftest "Process.alive? after normal exit"
       (assert-equal 'false (ev "
defmodule M do
  def run() do
    me = self()
    p = spawn(fn -> send(me, :ready) end)
    receive do :ready -> :ok end
    Process.sleep(1)
    Process.alive?(p)
  end
end
M.run()")))

     (deftest "GenServer call/cast with state"
       (assert-equal "100 105 0" (ev "
defmodule Counter do
  use GenServer
  def init(n), do: {:ok, n}
  def handle_call(:get, _from, n), do: {:reply, n, n}
  def handle_call({:add, x}, _from, n), do: {:reply, n + x, n + x}
  def handle_cast(:reset, _n), do: {:noreply, 0}
end
defmodule M do
  def run() do
    {:ok, pid} = GenServer.start_link(Counter, 100)
    a = GenServer.call(pid, :get)
    b = GenServer.call(pid, {:add, 5})
    GenServer.cast(pid, :reset)
    c = GenServer.call(pid, :get)
    \"#{a} #{b} #{c}\"
  end
end
M.run()")))

     (deftest "GenServer multiple clients"
       (assert-equal 6 (ev "
defmodule Stack do
  def init(_), do: {:ok, []}
  def handle_cast({:push, x}, s), do: {:noreply, [x | s]}
  def handle_call(:sum, _from, s), do: {:reply, Enum.sum(s), s}
end
defmodule M do
  def run() do
    {:ok, pid} = GenServer.start_link(Stack, nil)
    GenServer.cast(pid, {:push, 1})
    GenServer.cast(pid, {:push, 2})
    GenServer.cast(pid, {:push, 3})
    GenServer.call(pid, :sum)
  end
end
M.run()")))

     (deftest "trap_exit turns link death into a message"
       (assert-equal 'trapped (ev "
defmodule M do
  def run() do
    Process.flag(:trap_exit, true)
    spawn_link(fn -> raise \"boom\" end)
    receive do
      {:EXIT, _pid, _reason} -> :trapped
    end
  end
end
M.run()")))

     (deftest "supervisor restarts crashed child"
       (assert-equal 'true (ev "
defmodule W do
  use GenServer
  def start_link(parent) do
    {:ok, pid} = GenServer.start_link(W, parent)
    send(parent, {:started, pid})
    {:ok, pid}
  end
  def init(p), do: {:ok, p}
  def handle_cast(:crash, _s), do: raise \"boom\"
end
defmodule M do
  def run() do
    me = self()
    {:ok, _sup} = Supervisor.start_link([{W, me}])
    p1 = receive do {:started, pid} -> pid end
    GenServer.cast(p1, :crash)
    p2 = receive do {:started, pid} -> pid end
    p1 != p2
  end
end
M.run()")))

     (deftest "local call inside spawned fn (lexical module)"
       (assert-equal 5000 (ev "
defmodule M do
  def count(0, acc), do: acc
  def count(n, acc), do: count(n - 1, acc + 1)
  def run() do
    me = self()
    spawn(fn -> send(me, count(5000, 0)) end)
    receive do x -> x end
  end
end
M.run()")))

     (deftest "reduction pre-emption interleaves CPU-bound work"
       ;; A (spawned first) is CPU-heavy; B (spawned second) is quick.  With
       ;; reduction-counted pre-emption, B's message arrives before A finishes.
       (assert-equal "{:b_done, :a_done}" (ev* "
defmodule M do
  def busy(0, acc), do: acc
  def busy(n, acc), do: busy(n - 1, acc + 1)
  def run() do
    me = self()
    spawn(fn -> busy(50000, 0); send(me, :a_done) end)
    spawn(fn -> send(me, :b_done) end)
    a = receive do x -> x end
    b = receive do x -> x end
    {a, b}
  end
end
M.run()")))

     (deftest "Process.register + send by name"
       (assert-equal 'hello (ev "
defmodule M do
  def run() do
    me = self()
    pid = spawn(fn -> receive do {:hi, from} -> send(from, :hello) end end)
    Process.register(pid, :greeter)
    send(:greeter, {:hi, me})
    receive do msg -> msg end
  end
end
M.run()")))

     (deftest "GenServer registered name"
       (assert-equal 2 (ev "
defmodule C do
  use GenServer
  def init(n), do: {:ok, n}
  def handle_call(:get, _from, n), do: {:reply, n, n}
  def handle_cast(:inc, n), do: {:noreply, n + 1}
end
defmodule M do
  def run() do
    GenServer.start_link(C, 0, name: :ctr)
    GenServer.cast(:ctr, :inc)
    GenServer.cast(:ctr, :inc)
    GenServer.call(:ctr, :get)
  end
end
M.run()")))

     (deftest "supervisor :one_for_all restarts all on a crash"
       (assert-equal "[:a, :b, :c]" (ev* (supervisor-test "one_for_all"))))
     (deftest "supervisor :rest_for_one restarts the rest"
       (assert-equal "[:b, :c]" (ev* (supervisor-test "rest_for_one"))))
     (deftest "supervisor :one_for_one restarts just the crashed child"
       (assert-equal "[:b]" (ev* (supervisor-test "one_for_one"))))

     (deftest "multiple workers fan-in"
       (assert-equal 6 (ev "
defmodule W do
  def go(parent, x), do: send(parent, x)
end
defmodule M do
  def run() do
    me = self()
    spawn(fn -> W.go(me, 1) end)
    spawn(fn -> W.go(me, 2) end)
    spawn(fn -> W.go(me, 3) end)
    a = receive do x -> x end
    b = receive do x -> x end
    c = receive do x -> x end
    a + b + c
  end
end
M.run()"))))))
