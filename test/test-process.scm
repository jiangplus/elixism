;;; Process / concurrency tests (fiber scheduler).
;;; SPDX-License-Identifier: Apache-2.0
(define-module (test test-process)
  #:use-module (test harness)
  #:use-module (elixir eval)
  #:use-module (elixir runtime)
  #:export (run))

(define (ev src) (reset-elixir!) (elixir-run src))
(define (ev* src) (reset-elixir!) (inspect (elixir-run src)))

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
