module Rack
  module Session
    class CloudflareCommon < Abstract::Persisted
      # JavaScript Number's largest exactly representable safe integer (2**53 - 1).
      JAVASCRIPT_MAX_SAFE_INTEGER = 9_007_199_254_740_991

      def initialize(app, options = {})
        super(app, { prefix: "rack:session:",
                     expire_after: 86400, secure: true }.merge(options))
        @binding = @default_options[:binding]
        @prefix = @default_options[:prefix]
        unless @binding.is_a?(String) && !@binding.empty?
          raise ArgumentError, "binding must be a non-empty String"
        end
        unless @prefix.is_a?(String) && @prefix.bytesize <= 448 && @prefix.ascii_only?
          raise ArgumentError, "prefix must be ASCII and at most 448 bytes"
        end
        validate_ttl(@default_options[:expire_after])
      end

      private

      def generate_sid
        SecureRandom.random_bytes(32).bytes.map do |byte|
          hex = byte.to_s(16)
          hex.bytesize == 1 ? "0#{hex}" : hex
        end.join
      end

      def valid_sid?(sid)
        sid.is_a?(String) && sid.bytesize == 64 && sid =~ /\A[0-9a-f]+\z/
      end

      def session_snapshot(data)
        raise ArgumentError, "rack.session must be a Hash" unless data.is_a?(Hash)
        validate_data(data)
        JSON.generate(data)
      end

      def session_changed?(snapshot, data)
        snapshot != session_snapshot(data)
      end

      def validate_data(value, depth = 0)
        raise ArgumentError, "session data is nested too deeply or cyclic" if depth > 64
        case value
        when Hash
          value.each do |key, child|
            raise ArgumentError, "session keys must be strings" unless key.is_a?(String)
            validate_data(child, depth + 1)
          end
        when Array
          value.each { |child| validate_data(child, depth + 1) }
        when String, Integer, TrueClass, FalseClass, NilClass
        when Float
          raise ArgumentError, "session numbers must be finite" unless value.finite?
        else
          raise ArgumentError, "session values must be JSON-compatible"
        end
      end
    end
  end
end
