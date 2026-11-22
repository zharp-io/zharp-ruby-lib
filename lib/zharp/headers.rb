# frozen_string_literal: true

module Zharp
  # Request and response headers on the request's server span, as http.request.header.<name> and
  # http.response.header.<name>. OpenTelemetry's Rack instrumentation only records the headers on
  # its allow-list; Zharp records all of them. Secret headers (authorization, cookies, API keys,
  # tokens, sessions) are recorded as [REDACTED]: you see one was sent, never its value.
  module Headers
    # Header names (searched case-insensitively) whose values are never sent: the Python SDK's list.
    SECRET_HEADERS = %w[
      authorization cookie password passwd secret token api-?key access-?key
      private-?key credential signature session csrf xsrf jwt ^auth$ ^sid$
    ].freeze
    REDACTED = "[REDACTED]"
    MAX_VALUE = 1000
    MAX_HEADERS = 100

    module_function

    # The secret-header pattern, or nil when header capture is off.
    # capture_headers: false (or ZHARP_CAPTURE_HEADERS=false) turns it off;
    # capture_headers: { redact: ["x-tenant"] } filters more names.
    def settings(option, env_value)
      return nil if option == false || Config.flag(env_value) == false

      extra = option.is_a?(Hash) ? Array(option[:redact] || option["redact"]).map(&:to_s) : []
      Regexp.new((SECRET_HEADERS + extra).join("|"), Regexp::IGNORECASE)
    end

    # The request's headers from a Rack env, by lower-case name.
    def from_env(env)
      out = {}
      env.each do |key, value|
        name =
          if key.start_with?("HTTP_") then key[5..]
          elsif key == "CONTENT_TYPE" || key == "CONTENT_LENGTH" then key
          end
        next unless name && value.is_a?(String)

        out[name.downcase.tr("_", "-")] = value
        break if out.size >= MAX_HEADERS
      end
      out
    end

    # Span attributes for one side's headers, secrets redacted.
    def attributes(side, headers, secret)
      out = {}
      return out unless secret && headers

      headers.each do |name, value|
        name = name.to_s.downcase
        next if name.empty? || name.start_with?("rack.")

        text = value.is_a?(Array) ? value.join(", ") : value.to_s
        text = REDACTED if secret.match?(name)
        out["http.#{side}.header.#{name}"] = text.length > MAX_VALUE ? text[0, MAX_VALUE] : text
        break if out.size >= MAX_HEADERS
      end
      out
    end
  end
end
