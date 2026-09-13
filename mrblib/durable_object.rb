module Rack
  module Session
    module Abstract
      class SessionHash
        def to_pojo
          self.class.convert_pojo(self, true)
        end

        def self.from_pojo(pojo, id = nil, options = {})
          unless pojo.is_a?(::Cloudflare::DurableObject::POJO)
            raise ArgumentError, "session data must be a DurableObject::POJO"
          end
          new(convert_pojo(pojo, false), id, options)
        end

        # Copy nested containers so converting never mutates the source record.
        # Session IDs and request options are metadata, not user session data.
        def self.convert_pojo(value, wrap, depth = 0)
          raise ArgumentError, "session data is nested too deeply or cyclic" if depth > 64
          case value
          when Hash
            result = wrap ? ::Cloudflare::DurableObject::POJO.new : {}
            value.each do |key, child|
              raise ArgumentError, "session keys must be strings" unless key.is_a?(String)
              result[key] = convert_pojo(child, wrap, depth + 1)
            end
            result
          when Array
            value.map { |child| convert_pojo(child, wrap, depth + 1) }
          when String
            value.dup
          when Integer, TrueClass, FalseClass, NilClass
            value
          when Float
            raise ArgumentError, "session numbers must be finite" unless value.finite?
            value
          else
            raise ArgumentError, "session values must be JSON-compatible"
          end
        end
      end
    end

    # Shares the Persisted cookie lifecycle and ID/data validation through CloudflareCommon.
    class DurableObject < CloudflareCommon
      def initialize(app, options = {})
        super(app, { binding: "SESSION" }.merge(options))
      end

      private

      def storage(req)
        ::Cloudflare::DurableObject.from_env(req.env, @binding)
      end

      def find_session(req, sid)
        return [nil, {}] unless valid_sid?(sid)
        record = storage(req).get(@prefix + sid)
        if record.is_a?(::Cloudflare::DurableObject::POJO) &&
           record["version"] == 1 &&
           record["expires_at"].is_a?(Integer) && record["expires_at"] > Time.now.to_i &&
           record["data"].is_a?(::Cloudflare::DurableObject::POJO)
          [sid, Abstract::SessionHash.from_pojo(record["data"])]
        else
          [nil, {}]
        end
      end

      def write_session(req, sid, data, options)
        ttl = options[:expire_after]
        validate_ttl(ttl)
        raise ArgumentError, "rack.session must be a Hash" unless data.is_a?(Hash)
        session = Abstract::SessionHash.new(data, sid, options)
        record = ::Cloudflare::DurableObject::POJO.new
        record["version"] = 1
        record["expires_at"] = Time.now.to_i + ttl
        record["data"] = session.to_pojo
        storage(req).put(@prefix + sid, record)
        sid
      end

      def delete_session(req, sid, options)
        if valid_sid?(sid)
          record = ::Cloudflare::DurableObject::POJO.new
          record["version"] = 1
          record["expires_at"] = 0
          storage(req).put(@prefix + sid, record)
        end
        options[:drop] ? nil : generate_sid
      end

      def validate_ttl(ttl)
        unless ttl.is_a?(Integer) && ttl >= 1 && ttl <= JAVASCRIPT_MAX_SAFE_INTEGER
          raise ArgumentError, "expire_after must be a positive safe integer"
        end
      end
    end
  end
end
