# Deterministic native-test double. Production uses the host's SecureRandom.
module SecureRandom
  @sequence = 0
  def self.random_bytes(length)
    raise ArgumentError, "expected a 32-byte session ID" unless length == 32
    @sequence += 1
    bytes = ""
    length.times { |i| bytes += ((@sequence + i) % 256).chr }
    bytes
  end
end
