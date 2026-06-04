# Enum pipeline.
1..10
|> Enum.map(fn x -> x * x end)
|> Enum.filter(fn x -> rem(x, 2) == 1 end)
|> Enum.sum()
