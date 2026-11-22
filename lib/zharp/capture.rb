# frozen_string_literal: true

require "zlib"
require "stringio"

module Zharp
  # capture_bodies: request and response bodies on incoming requests' spans (any Rack app, Rails
  # included) and outgoing Net::HTTP calls (Faraday's default adapter too), and secrets masked in
  # every span's URL.
  #
  # Nothing changes what the app reads or writes. A request body is seen as the app reads it (the
  # input is teed), a response body as the server writes it; only the first bytes up to the raw
  # limit are kept:
  # - text: the first bytes, decoded (and inflated when it was gzip/deflate encoded);
  # - a form upload (multipart/form-data): each field, and each file as its name, type and size;
  # - anything else (an image, a PDF, an event stream): only its size.
  module Capture
    # Fields kept from one form upload.
    MAX_FIELDS = 200

    module_function

    def inflate(raw, encoding)
      case encoding.to_s.strip.downcase
      when "gzip", "x-gzip" then Zlib::GzipReader.new(StringIO.new(raw)).read
      when "deflate"
        begin
          Zlib::Inflate.inflate(raw)
        rescue Zlib::Error
          Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(raw)
        end
      when "", "identity" then raw
      end
    rescue Zlib::Error, EOFError
      nil
    end

    # The attributes for one side, from the bytes seen. cut: more came than was kept.
    def side_attributes(side, raw, total, cut, content_type, encoding, settings)
      return {} if total.to_i.zero?
      return Bodies.described_attributes(side, content_type, total) unless Bodies.textual?(content_type)

      text = inflate(raw, encoding)
      return Bodies.described_attributes(side, content_type, total) if text.nil?

      Bodies.body_attributes(side, text, content_type, settings, cut)
    end

    # A form upload as Rack parsed it (rack.request.form_hash): fields as they are, files described.
    def form_fields(value, depth = 0, count = [0])
      return "[…]" if depth > 10
      case value
      when Hash
        if value[:tempfile] || value["tempfile"]
          file = value[:tempfile] || value["tempfile"]
          size = file.respond_to?(:size) ? file.size : nil
          return Bodies.file_label(value[:filename] || value["filename"], value[:type] || value["type"], size)
        end
        value.each_with_object({}) do |(k, v), out|
          break out if (count[0] += 1) > MAX_FIELDS

          out[k.to_s] = form_fields(v, depth + 1, count)
        end
      when Array then value.map { |v| form_fields(v, depth + 1, count) }
      when nil then nil
      else value.respond_to?(:tempfile) ? Bodies.file_label(value.original_filename, value.content_type, value.size) : value.to_s
      end
    end

    # rack.input, teed: what the app reads is kept up to the limit (a rewind isn't counted twice).
    class TeeInput
      attr_reader :total

      def initialize(input, limit)
        @input = input
        @limit = limit
        @kept = +"".b
        @pos = 0
        @total = 0
      end

      def read(*args)
        data = @input.read(*args)
        see(data)
        data
      end

      def gets(*args)
        data = @input.gets(*args)
        see(data)
        data
      end

      def each
        return enum_for(:each) unless block_given?

        @input.each do |chunk|
          see(chunk)
          yield chunk
        end
      end

      def rewind
        @pos = 0
        @input.rewind
      end

      def close = @input.respond_to?(:close) ? @input.close : nil
      def respond_to_missing?(name, include_private = false) = @input.respond_to?(name, include_private)
      def method_missing(name, ...) = @input.respond_to?(name) ? @input.public_send(name, ...) : super

      # What the app left unread, read here (up to the limit) after it answered.
      def drain(content_length)
        length = content_length.to_i
        return if length <= 0 || @total >= length

        while @total < [length, @limit].min
          chunk = read([16 * 1024, @limit - @total].min)
          break if chunk.nil? || chunk.empty?
        end
      rescue StandardError
        nil
      end

      def kept = @kept
      def cut? = @total > @kept.bytesize

      private

      def see(data)
        return if data.nil? || data.empty?

        data = data.b
        start = @pos
        @pos += data.bytesize
        return if @pos <= @total # read again after a rewind

        fresh = data.byteslice((@total - start).clamp(0, data.bytesize)..)
        @total = @pos
        room = @limit - @kept.bytesize
        @kept << fresh.byteslice(0, room) if room.positive?
      end
    end

    # A response body that isn't an Array: chunks kept as the server writes them, the attributes
    # set when it closes (before the request's span ends).
    class TapBody
      def initialize(body, limit, &done)
        @body = body
        @limit = limit
        @kept = +"".b
        @total = 0
        @done = done
      end

      def each
        @body.each do |chunk|
          @total += chunk.bytesize
          room = @limit - @kept.bytesize
          @kept << chunk.b.byteslice(0, room) if room.positive?
          yield chunk
        end
      end

      def close
        @body.close if @body.respond_to?(:close)
      ensure
        begin
          @done&.call(@kept, @total, @total > @kept.bytesize)
        rescue StandardError
          nil
        end
        @done = nil
      end

      def respond_to?(name, include_all = false)
        return false if %i[to_ary call to_path].include?(name.to_sym)

        super || @body.respond_to?(name, include_all)
      end

      def method_missing(name, ...) = @body.respond_to?(name) ? @body.public_send(name, ...) : super
      def respond_to_missing?(name, include_private = false) = @body.respond_to?(name, include_private)
    end

    # ─── incoming (Rack) ─────────────────────────────────────────────────────────

    def rack_url(env)
      scheme = env["rack.url_scheme"] || "http"
      host = env["HTTP_HOST"] || env["SERVER_NAME"]
      query = env["QUERY_STRING"].to_s
      "#{scheme}://#{host}#{env['SCRIPT_NAME']}#{env['PATH_INFO']}#{query.empty? ? '' : "?#{query}"}"
    end

    # Before the app: tee its input. Returns the tee (or nil when this request isn't captured).
    def start_request(env, settings)
      return nil unless Bodies.allowed?(settings, rack_url(env))

      input = env["rack.input"]
      tee = TeeInput.new(input || StringIO.new(+""), Bodies.raw_limit(settings))
      env["rack.input"] = tee if input
      tee
    end

    # After the app: the request body's attributes now, the response's when its body closes.
    # Returns the body to hand back.
    def finish_request(span, env, tee, status, headers, body, settings)
      return body unless Bodies.wanted?(settings, status)

      span.add_attributes(request_attributes(env, tee, settings))
      response_body(span, headers, body, settings)
    rescue StandardError => e
      Zharp.debug("bodies: #{e.message}")
      body
    end

    def request_attributes(env, tee, settings)
      type = env["CONTENT_TYPE"]
      if Bodies.multipart?(type)
        form = env["rack.request.form_hash"]
        return Bodies.body_attributes("request", JSON.generate(form_fields(form)), type, settings) if form

        return Bodies.described_attributes("request", type, env["CONTENT_LENGTH"]&.to_i)
      end
      tee.drain(env["CONTENT_LENGTH"]) if Bodies.textual?(type)
      side_attributes("request", tee.kept, tee.total, tee.cut?, type, env["HTTP_CONTENT_ENCODING"], settings)
    end

    def header(headers, name)
      return nil unless headers

      headers[name] || headers.find { |k, _| k.to_s.casecmp?(name) }&.last
    end

    def response_body(span, headers, body, settings)
      type = header(headers, "content-type")
      encoding = header(headers, "content-encoding")
      length = header(headers, "content-length")&.to_i
      unless Bodies.textual?(type)
        span.add_attributes(Bodies.described_attributes("response", type, length))
        return body
      end
      if body.respond_to?(:call) && !body.respond_to?(:each) # a streaming body (Rack 3)
        span.add_attributes(Bodies.unread_attributes("response", type, length))
        return body
      end
      if body.respond_to?(:to_ary)
        parts = body.to_ary
        raw = parts.join.b
        limit = Bodies.raw_limit(settings)
        span.add_attributes(side_attributes("response", raw.byteslice(0, limit), raw.bytesize, raw.bytesize > limit, type, encoding, settings))
        return parts
      end
      TapBody.new(body, Bodies.raw_limit(settings)) do |kept, total, cut|
        span.add_attributes(side_attributes("response", kept, total, cut, type, encoding, settings)) if span.recording?
      end
    end

    # ─── outgoing (Net::HTTP) ────────────────────────────────────────────────────

    # Inside OpenTelemetry's Net::HTTP span (prepended before its instrumentation, so it runs within
    # that span): the request body, and the response body Net::HTTP already read.
    module NetHTTP
      def request(req, body = nil, &block)
        settings = Zharp.options&.capture_bodies
        return super unless settings && started?

        span = ::OpenTelemetry::Trace.current_span
        return super unless span.recording? && span.respond_to?(:kind) && span.kind == :client

        url = "#{use_ssl? ? 'https' : 'http'}://#{address}:#{port}#{req.path}"
        return super unless Bodies.allowed?(settings, url)

        begin
          response = super
        rescue Exception # rubocop:disable Lint/RescueException
          Capture.add(span) { Capture.outgoing_request(req, body, settings) }
          raise
        end
        if Bodies.wanted?(settings, response.code.to_i)
          Capture.add(span) do
            attrs = Capture.outgoing_request(req, body, settings)
            attrs.merge(Capture.outgoing_response(response, settings))
          end
        end
        response
      end
    end

    def add(span)
      span.add_attributes(yield)
    rescue StandardError => e
      Zharp.debug("bodies: #{e.message}")
    end

    def outgoing_request(req, body, settings)
      data = body || req.body
      type = req["content-type"]
      return Bodies.unread_attributes("request", type, req["content-length"]&.to_i) if data.nil? && req.body_stream
      return {} if data.nil?

      raw = data.to_s.b
      limit = Bodies.raw_limit(settings)
      side_attributes("request", raw.byteslice(0, limit), raw.bytesize, raw.bytesize > limit, type, req["content-encoding"], settings)
    end

    def outgoing_response(response, settings)
      type = response["content-type"]
      body = response.instance_variable_get(:@body)
      # Streamed to the app in a block (read_body { |chunk| }), so not kept: described.
      unless response.instance_variable_get(:@read) && (body.is_a?(String) || body.nil?)
        return Bodies.unread_attributes("response", type, response["content-length"]&.to_i)
      end

      raw = body.to_s.b
      limit = Bodies.raw_limit(settings)
      # Net::HTTP inflates what it asked to be compressed and drops the header then.
      side_attributes("response", raw.byteslice(0, limit), raw.bytesize, raw.bytesize > limit, type, response["content-encoding"], settings)
    rescue StandardError
      {}
    end

    def install_net_http
      ::Net::HTTP.prepend(NetHTTP) unless ::Net::HTTP.ancestors.include?(NetHTTP)
    end

    # ─── URLs ────────────────────────────────────────────────────────────────────

    URL_KEYS = %w[url.full http.url http.target].freeze

    # Secrets in URLs never leave the process: secret-looking query values (token, key, sig,
    # password…) in a span's URL attributes become [Filtered] and user:password@ is dropped, on
    # every span, whatever made it, with or without capture_bodies.
    class UrlRedaction
      def on_start(span, parent_context); end

      # Runs inside the span's own lock as it ends, so the attributes are changed in place.
      def on_finishing(span)
        attributes = span.instance_variable_get(:@attributes)
        return unless attributes.is_a?(Hash) && !attributes.frozen?

        URL_KEYS.each do |key|
          value = attributes[key]
          attributes[key] = Bodies.redact_url(value) if value.is_a?(String) && value.include?("?") || value.is_a?(String) && value.include?("@")
        end
        query = attributes["url.query"]
        if query.is_a?(String)
          bare = query.delete_prefix("?")
          redacted = Bodies.redact_query(bare)
          attributes["url.query"] = "#{query.start_with?('?') ? '?' : ''}#{redacted}" if redacted != bare
        end
      rescue StandardError
        nil
      end

      def on_finish(span); end
      def force_flush(timeout: nil) = ::OpenTelemetry::SDK::Trace::Export::SUCCESS
      def shutdown(timeout: nil) = ::OpenTelemetry::SDK::Trace::Export::SUCCESS
    end
  end
end
