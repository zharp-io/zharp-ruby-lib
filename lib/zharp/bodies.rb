# frozen_string_literal: true

require "json"
require "uri"
require "bigdecimal"

module Zharp
  # Request and response bodies on HTTP spans (capture_bodies), and secrets in URLs.
  #
  # A port of the rules every Zharp SDK shares (@zharp/internal/bodies, zharp-python's _bodies.py),
  # so a payload looks the same whichever SDK sent it:
  # - field names stay; values under keys that look secret (password, token, authorization, card…)
  #   become [Filtered], and an object under such a key keeps its keys with every value filtered;
  # - an inline image or other long base64 value becomes [image/png · 24 KB], a file in a form
  #   upload [file photo.png · image/png · 240 KB], and a body that isn't text at all
  #   [binary · application/pdf · 1.2 MB] or [event stream];
  # - text is capped (32 KB by default), with http.*.body.truncated set when it was cut.
  module Bodies
    DEFAULT_MAX_BODY = 32 * 1024
    MAX_BODY = 128 * 1024
    FILTERED = "[Filtered]"

    REQUEST_BODY = "http.request.body"
    REQUEST_TRUNCATED = "http.request.body.truncated"
    REQUEST_TYPE = "http.request.header.content-type"
    RESPONSE_BODY = "http.response.body"
    RESPONSE_TRUNCATED = "http.response.body.truncated"
    RESPONSE_TYPE = "http.response.header.content-type"
    ATTRS = {
      "request" => [REQUEST_BODY, REQUEST_TRUNCATED, REQUEST_TYPE],
      "response" => [RESPONSE_BODY, RESPONSE_TRUNCATED, RESPONSE_TYPE]
    }.freeze

    # mode: "errors" (status 400 and above, or no response) or "all"; max_size: characters kept;
    # redact_keys: more secret keys (a String matches ignoring case, - and _; a Regexp is searched
    # in the key); urls: which requests (a bare host, a URL prefix, or a Regexp), nil for all.
    Settings = Struct.new(:mode, :max_size, :redact_keys, :urls, keyword_init: true)

    module_function

    # capture_bodies: true, "errors", "all", false/"off", or a Hash with mode, max_size,
    # redact_keys, urls. ZHARP_CAPTURE_BODIES (errors, all, off) when nothing is passed. Off by default.
    def settings(option, env_value)
      value = option
      if value.nil? && env_value
        text = env_value.to_s.strip.downcase
        value = if %w[errors all].include?(text) then text
                elsif Config::TRUE.match?(text) then true
                end
      end
      return nil if value.nil? || value == false

      value = { mode: value } if value.is_a?(String) || value.is_a?(Symbol)
      value = {} if value == true
      return nil unless value.is_a?(Hash)

      value = value.transform_keys(&:to_sym)
      mode = value[:mode].to_s.strip.downcase
      return nil if ["", "off", "false", "no", "none", "0"].include?(mode) && value.key?(:mode)

      size = value[:max_size]
      size = size.is_a?(Numeric) && size.positive? ? [size.floor, MAX_BODY].min : DEFAULT_MAX_BODY
      Settings.new(
        mode: mode == "all" ? "all" : "errors",
        max_size: size,
        redact_keys: Array(value[:redact_keys]),
        urls: value[:urls].nil? ? nil : Array(value[:urls])
      )
    end

    # Raw text read before shortening and capping: inline images shrink to a few words.
    def raw_limit(settings) = [64 * 1024, settings.max_size * 2].max

    # Whether a request with this outcome has its bodies kept (no status: no response).
    def wanted?(settings, status) = settings.mode == "all" || status.nil? || status.to_i.zero? || status.to_i >= 400

    def allowed?(settings, url) = settings.urls.nil? || url_matches?(url.to_s, settings.urls)

    # ─── content types ───────────────────────────────────────────────────────────

    def mime(content_type) = content_type.to_s.split(";").first.to_s.strip.downcase
    def event_stream?(content_type) = mime(content_type) == "text/event-stream"
    def multipart?(content_type) = mime(content_type) == "multipart/form-data"
    def form?(content_type) = mime(content_type) == "application/x-www-form-urlencoded"

    TEXT_APPLICATION = %r{\Aapplication/(json|xml|x-www-form-urlencoded|graphql|javascript|x-ndjson|ld\+json)\z}

    # Whether a body of this type is text worth showing. An unknown type gets the benefit of the doubt.
    def textual?(content_type)
      kind = mime(content_type)
      return true if kind.empty?
      return false if kind == "text/event-stream"

      kind.start_with?("text/") || kind.end_with?("+json", "+xml") || TEXT_APPLICATION.match?(kind)
    end

    # 240 KB, 1.4 MB.
    def format_size(size)
      return "#{size} B" if size < 1024
      return "#{(size / 1024.0 + 0.5).floor} KB" if size < 1024 * 1024

      "#{format('%.1f', ((size / (1024.0 * 1024)) * 10 + 0.5).floor / 10.0)} MB"
    end

    # [file photo.png · image/png · 240 KB]
    def file_label(name, content_type, size, partial = false)
      parts = ["file #{name.nil? || name.to_s.empty? ? 'blob' : name}"]
      parts << content_type if content_type && !content_type.to_s.empty?
      parts << "#{format_size(size)}#{partial ? '+' : ''}" unless size.nil?
      "[#{parts.join(' · ')}]"
    end

    # [binary · image/png · 24 KB], [event stream]
    def describe_body(content_type, size = nil, partial = false)
      return "[event stream]" if event_stream?(content_type)

      parts = ["binary"]
      kind = mime(content_type)
      parts << kind unless kind.empty?
      parts << "#{format_size(size)}#{partial ? '+' : ''}" if size&.positive?
      "[#{parts.join(' · ')}]"
    end

    # ─── redaction ───────────────────────────────────────────────────────────────

    # Built-in keys whose values never leave the process, compared without case, - or _.
    CONTAINS = %w[
      password passwd passphrase secret token apikey accesskey privatekey authorization cookie
      creditcard cardnumber cvv cvc ssn iban sessionid signature credential
    ].freeze
    EXACT = %w[auth pin pwd otp card pan jwt sid codeverifier].freeze
    # Also secret in a query string, where they are API keys and signed-URL signatures.
    URL_EXACT = %w[key sig code state session].freeze

    def normalize(key) = key.to_s.downcase.gsub(/[^a-z0-9]/, "")

    def secret_key?(key, extra = [])
      k = normalize(key)
      return false if k.empty?
      return true if EXACT.include?(k) || CONTAINS.any? { |c| k.include?(c) }

      extra.any? { |pattern| pattern.is_a?(Regexp) ? pattern.match?(key.to_s) : normalize(pattern) == k }
    end

    DATA_URI = %r{\Adata:([\w.+-]+/[\w.+-]+)?(?:;[\w=.+-]+)*;base64,([A-Za-z0-9+/=\s]*)\z}
    BASE64 = %r{\A[A-Za-z0-9+/_-]{256,}={0,2}\z}

    # A long base64 value as a short description; other strings as they are.
    def shorten(value)
      return value if value.length < 256

      if (uri = DATA_URI.match(value))
        return "[#{uri[1] || 'data'} · #{format_size(uri[2].length * 3 / 4)}]"
      end
      return "[base64 · #{format_size(value.length * 3 / 4)}]" if BASE64.match?(value) && value.match?(%r{[0-9+/]})

      value
    end

    def filter_all(value, depth)
      return FILTERED if depth > 20
      return value if value.nil? || value == ""
      return value.map { |v| filter_all(v, depth + 1) } if value.is_a?(Array)
      return value.transform_values { |v| filter_all(v, depth + 1) } if value.is_a?(Hash)

      FILTERED
    end

    def redact_value(value, extra, depth = 0)
      return shorten(value) if value.is_a?(String)
      return value if depth > 20 || !(value.is_a?(Hash) || value.is_a?(Array))
      return value.map { |v| redact_value(v, extra, depth + 1) } if value.is_a?(Array)

      value.to_h { |k, v| [k, secret_key?(k, extra) ? filter_all(v, depth + 1) : redact_value(v, extra, depth + 1)] }
    end

    RUNS = %r{"((?:data:[\w.+-]+/[\w.+-]+(?:;[\w=.+-]+)*;base64,)?[A-Za-z0-9+/_=-]{256,})("?)}
    PAIRS = /("([^"\\]{1,100})"\s*:\s*)("(?:[^"\\]|\\.)*"?|-?\d[\d.eE+-]*|true|false)/

    # Text that didn't parse: secret "key": value pairs filtered, long base64 runs shortened.
    def redact_loose(text, extra)
      text = text.gsub(RUNS) do
        m = Regexp.last_match
        short = shorten(m[1])
        if short == m[1] then m[0]
        elsif m[2].empty? then %("#{short[0..-2]}+]")
        else %("#{short}")
        end
      end
      text.gsub(PAIRS) { (m = Regexp.last_match) && secret_key?(m[2], extra) ? %(#{m[1]}"#{FILTERED}") : m[0] }
    end

    def decode_component(text) = URI.decode_www_form_component(text)

    def redact_form(text, extra)
      text.split("&", -1).map do |pair|
        eq = pair.index("=")
        next pair unless eq

        key = begin
          decode_component(pair[0...eq])
        rescue ArgumentError
          pair[0...eq]
        end
        next "#{pair[0...eq]}=#{FILTERED}" if secret_key?(key, extra)

        value = pair[(eq + 1)..]
        value.length >= 256 ? "#{pair[0...eq]}=#{shorten_encoded(value)}" : pair
      end.join("&")
    end

    def shorten_encoded(value)
      decoded = decode_component(value)
      short = shorten(decoded)
      short == decoded ? value : short
    rescue ArgumentError
      value
    end

    # ─── JSON as JavaScript writes it ────────────────────────────────────────────

    # JSON.stringify(value): no spaces, numbers as JavaScript writes them (1.0 is 1, 1e21 is 1e+21).
    def stringify(value)
      case value
      when nil then "null"
      when true then "true"
      when false then "false"
      when Integer then value.to_s
      when Float then js_number(value)
      when String then JSON.generate(value)
      when Hash then "{#{value.map { |k, v| "#{JSON.generate(k.to_s)}:#{stringify(v)}" }.join(",")}}"
      when Array then "[#{value.map { |v| stringify(v) }.join(",")}]"
      else JSON.generate(value.to_s)
      end
    end

    def js_number(value)
      return "null" if value.nan? || value.infinite?
      return "0" if value.zero?
      return value.to_i.to_s if value == value.floor && value.abs < 1e21

      text = value.to_s
      return text unless text.include?("e")

      mantissa, exponent = text.split("e")
      exp = exponent.to_i
      return BigDecimal(text).to_s("F").sub(/\.0\z/, "") if exp > -7 && exp < 21

      "#{mantissa.sub(/\.0\z/, '')}e#{exp.positive? ? '+' : '-'}#{exp.abs}"
    end

    # ─── the attribute value ─────────────────────────────────────────────────────

    # A body as it is sent: redacted, then cut to max_size. cut says the text was already cut
    # short where it was read. nil for an empty body. Returns [value, truncated].
    def format_body(text, content_type, settings, cut = false)
      return nil if text.nil?

      body = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("\uFFFD")
      trimmed = body.strip
      return nil if trimmed.empty?

      if form?(content_type)
        body = redact_form(body, settings.redact_keys)
      else
        parsed = nil
        ok = false
        if !cut && "{[".include?(trimmed[0])
          begin
            parsed = JSON.parse(trimmed)
            ok = true
          rescue JSON::ParserError, SystemStackError, EncodingError
            ok = false
          end
        end
        body = ok ? stringify(redact_value(parsed, settings.redact_keys)) : redact_loose(body, settings.redact_keys)
      end
      length = utf16_length(body)
      truncated = cut || length > settings.max_size
      [length > settings.max_size ? utf16_slice(body, settings.max_size) : body, truncated]
    end

    def utf16_length(text) = text.length + text.each_char.count { |c| c.ord > 0xFFFF }

    def utf16_slice(text, limit)
      count = 0
      text.each_char.with_index do |c, i|
        count += c.ord > 0xFFFF ? 2 : 1
        return text[0, i] if count > limit
      end
      text
    end

    # The span attributes for one side of a request ("request" or "response").
    def body_attributes(side, text, content_type, settings, cut = false)
      return {} unless textual?(content_type) || multipart?(content_type)

      formatted = format_body(text, content_type, settings, cut)
      return {} unless formatted

      body_key, truncated_key, type_key = ATTRS.fetch(side)
      out = { body_key => formatted[0] }
      out[truncated_key] = true if formatted[1]
      out[type_key] = content_type if content_type && !content_type.to_s.empty?
      out
    end

    # The attributes for a body that isn't text: what it was, not what it said.
    def described_attributes(side, content_type, size = nil, partial = false)
      body_key, _, type_key = ATTRS.fetch(side)
      out = { body_key => describe_body(content_type, size, partial) }
      out[type_key] = content_type if content_type && !content_type.to_s.empty?
      out
    end

    # A body never read (a streamed response): text is [stream · application/json · 60 B].
    def unread_attributes(side, content_type, size)
      return described_attributes(side, content_type, size) unless textual?(content_type)

      parts = ["stream"]
      kind = mime(content_type)
      parts << kind unless kind.empty?
      parts << format_size(size) if size&.positive?
      body_key, _, type_key = ATTRS.fetch(side)
      out = { body_key => "[#{parts.join(' · ')}]" }
      out[type_key] = content_type if content_type && !content_type.to_s.empty?
      out
    end

    # ─── URLs ────────────────────────────────────────────────────────────────────

    # A URL as it is recorded: secret-looking query values become [Filtered], user:password@ dropped.
    def redact_url(url, extra = [])
      return url if url.nil? || url.empty?

      out = url.sub(%r{\A([a-z][a-z0-9+.-]*://)[^/?#@]*@}i, '\1')
      q = out.index("?")
      return out unless q

      hash_at = out.index("#", q)
      query = hash_at ? out[(q + 1)...hash_at] : out[(q + 1)..]
      redacted = redact_query(query, extra)
      redacted == query ? out : "#{out[0..q]}#{redacted}#{hash_at ? out[hash_at..] : ''}"
    end

    # A query string (without ?) with secret-looking values filtered.
    def redact_query(query, extra = [])
      return query if query.nil? || query.empty?

      query.split("&", -1).map do |pair|
        eq = pair.index("=")
        next pair unless eq

        key = begin
          decode_component(pair[0...eq])
        rescue ArgumentError
          pair[0...eq]
        end
        secret = secret_key?(key, extra) || URL_EXACT.include?(normalize(key))
        secret && eq < pair.length - 1 ? "#{pair[0...eq]}=#{FILTERED}" : pair
      end.join("&")
    end

    DEFAULT_PORTS = { "http" => 80, "https" => 443, "ws" => 80, "wss" => 443, "ftp" => 21 }.freeze

    # A bare host (with or without a port) matches that host; a string with a scheme matches as a
    # prefix; a Regexp is searched in the URL.
    def url_matches?(url, patterns)
      host = hostname = ""
      begin
        uri = URI.parse(url)
        hostname = uri.host.to_s.downcase
        host = uri.port.nil? || DEFAULT_PORTS[uri.scheme.to_s.downcase] == uri.port ? hostname : "#{hostname}:#{uri.port}"
      rescue URI::Error
        nil
      end
      patterns.any? do |pattern|
        if pattern.is_a?(Regexp) then pattern.match?(url)
        elsif pattern.to_s.empty? then false
        elsif pattern.include?("://") then url.start_with?(pattern)
        else [host, hostname].include?(pattern)
        end
      end
    end
  end
end
