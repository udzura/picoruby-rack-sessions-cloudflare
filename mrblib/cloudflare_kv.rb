module Rack
  module Session
    class CloudflareKV < CloudflareCommon
      def initialize(app, options = {})
        super(app, { binding: "SESSIONS" }.merge(options))
      end

      private

      def kv(req)
        ::Cloudflare::KV.from_env(req.env, @binding)
      end

      def find_session(req, sid)
        return [nil, {}] unless valid_sid?(sid)
        raw = kv(req).get(@prefix + sid)
        return [nil, {}] unless raw
        record = decode_record(raw)
        if record && record["version"] == 1 && record["data"].is_a?(Hash) &&
           record["expires_at"].is_a?(Integer) && record["expires_at"] > Time.now.to_i
          [sid, record["data"]]
        else
          [nil, {}]
        end
      end

      def decode_record(raw)
        record = JSON.parse(raw)
        record.is_a?(Hash) ? record : nil
      rescue StandardError => error
        # PicoRuby's parser also raises JSONError for malformed delimiters.
        if error.is_a?(JSON::ParserError) ||
           (defined?(JSON::JSONError) && error.is_a?(JSON::JSONError))
          nil
        else
          raise
        end
      end

      def write_session(req, sid, data, options)
        ttl = options[:expire_after]
        validate_ttl(ttl)
        raise ArgumentError, "rack.session must be a Hash" unless data.is_a?(Hash)
        validate_data(data)
        payload = JSON.generate({ "version" => 1, "expires_at" => Time.now.to_i + ttl,
                                  "data" => data })
        kv(req).put(@prefix + sid, payload, ttl: ttl)
        sid
      end

      def delete_session(req, sid, options)
        # The current binding has no delete API. A tombstone also rejects old IDs
        # after propagation, and KV garbage-collects it after 60 seconds.
        kv(req).put(@prefix + sid, "null", ttl: 60) if valid_sid?(sid)
        options[:drop] ? nil : generate_sid
      end

      def validate_ttl(ttl)
        unless ttl.is_a?(Integer) && ttl >= 60 && ttl <= JAVASCRIPT_MAX_SAFE_INTEGER
          raise ArgumentError, "expire_after must be a safe integer of at least 60 seconds"
        end
      end
    end
  end
end
