# Structs: defstruct, construction with defaults, update, and matching.
defmodule User do
  defstruct name: "anonymous", age: 0, admin: false
end

defmodule App do
  def greet(%User{admin: true, name: n}), do: "Welcome back, admin #{n}!"
  def greet(%User{name: n}), do: "Hello, #{n}."

  def run() do
    alice = %User{name: "Alice", age: 30}
    boss  = %User{alice | admin: true}
    IO.puts inspect(alice)
    IO.puts greet(alice)
    IO.puts greet(boss)
  end
end

App.run()
