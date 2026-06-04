# Sub-byte (bit-level) binary fields: parse an IPv4 header's first words.
defmodule IPv4 do
  def parse(<<version::4, ihl::4, dscp::6, ecn::2, length::16, _rest::binary>>) do
    %{version: version, ihl: ihl, dscp: dscp, ecn: ecn, total_length: length}
  end
end

# 0x45 -> version 4, IHL 5;  0x00 -> DSCP/ECN;  0x05DC -> length 1500
header = <<0x45, 0x00, 0x05, 0xDC, 1, 2, 3>>
IO.puts inspect(IPv4.parse(header))

# Pack eight bits into one byte (10101010 = 0xAA = 170).
<<byte>> = <<1::1, 0::1, 1::1, 0::1, 1::1, 0::1, 1::1, 0::1>>
IO.puts "packed byte = #{byte}"
