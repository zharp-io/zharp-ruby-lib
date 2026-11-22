# frozen_string_literal: true

module Zharp
  # Any Rack app: Sinatra, Hanami, Roda, Grape, plain Rack. In config.ru:
  #
  #   require "zharp"
  #   Zharp.init(service: "shop")   # optional; ZHARP_KEY etc. from the environment otherwise
  #   use Zharp::Rack
  #   run App
  #
  # One server span per request (OpenTelemetry's Rack instrumentation, continuing the caller's
  # traceparent), named by route, with every request and response header (secrets as [REDACTED]),
  # and an exception that escapes reported once. Rails needs none of this: its Railtie adds it.
  class Rack
    # Built with the app (config.ru), so a preloading server (Puma's preload_app!, Unicorn's
    # preload_app) starts Zharp once, before it forks.
    def initialize(app)
      @app = app
      @inner = Headers.new(app)
      @traced = build
    end

    def call(env)
      @traced.call(env)
    end

    private

    # OpenTelemetry's Rack middleware around Zharp's.
    def build
      Zharp.init unless Zharp.active?
      instrumentation = ::OpenTelemetry::Instrumentation::Rack::Instrumentation.instance
      instrumentation.install({}) unless instrumentation.installed?
      klass, *args = instrumentation.middleware_args
      klass.new(@inner, *args)
    rescue StandardError, NameError => e
      Zharp.debug("rack: #{e.message}")
      @inner
    end

    # Zharp's layer inside the server span: headers, the exception that escaped, the route's name.
    # Rails inserts it right after OpenTelemetry's middleware.
    class Headers
      METHOD_ONLY = /\A[A-Z]+\z/

      def initialize(app)
        @app = app
      end

      # Where a framework leaves an exception it turned into an error page itself (Hanami, Roda and
      # other Rack apps use rack.exception).
      HANDLED_ERRORS = %w[rack.exception sinatra.error action_dispatch.exception].freeze

      def call(env)
        # The path as it arrived: a mounted app or router may rewrite PATH_INFO on the way in.
        path = env["PATH_INFO"].to_s
        span = Rack.server_span
        secret = Zharp.options&.capture_headers
        if span.recording? && secret
          span.add_attributes(Zharp::Headers.attributes("request", Zharp::Headers.from_env(env), secret))
        end
        status, headers, body = @app.call(env)
        if span.recording?
          span.add_attributes(Zharp::Headers.attributes("response", headers, secret)) if secret && headers
          report_rendered_error(span, env, status)
          Rack.name_span(span, env, path)
        end
        [status, headers, body]
      rescue Exception => e # rubocop:disable Lint/RescueException
        if span&.recording? && !Errors.reported?(e) && !e.is_a?(SystemExit) && !e.is_a?(SignalException)
          span.record_exception(e, attributes: { "zharp.handled" => "false" })
          span.status = ::OpenTelemetry::Trace::Status.error(e.class.name)
          # No response left the app: the server (Puma, Unicorn) answers 500.
          span.set_attribute("http.response.status_code", 500)
          Rack.name_span(span, env, path)
        end
        raise
      end

      private

      # A 5xx the framework rendered from an exception it caught: that exception escaped the app's
      # code, so it is reported, once, as unhandled.
      def report_rendered_error(span, env, status)
        return unless status.to_i >= 500

        error = HANDLED_ERRORS.lazy.map { |key| env[key] }.find { |e| e.is_a?(Exception) }
        return if error.nil? || Errors.reported?(error)

        span.record_exception(error, attributes: { "zharp.handled" => "false" })
        span.status = ::OpenTelemetry::Trace::Status.error(error.class.name)
      end
    end

    class << self
      def server_span
        if defined?(::OpenTelemetry::Instrumentation::Rack) && ::OpenTelemetry::Instrumentation::Rack.respond_to?(:current_span)
          span = ::OpenTelemetry::Instrumentation::Rack.current_span
          return span if span.recording?
        end
        ::OpenTelemetry::Trace.current_span
      end

      # Sinatra, Grape and Rails name the span by route themselves. Otherwise "GET /orders/:id": the
      # path with its ids replaced, so one route is one name.
      def name_span(span, env, path = nil)
        return unless span.respond_to?(:name) && span.name.to_s.match?(Headers::METHOD_ONLY)

        route = env["zharp.route"] || env["sinatra.route"]&.split&.last || quantize(path || env["PATH_INFO"].to_s)
        span.name = "#{env['REQUEST_METHOD']} #{route}"
        span.set_attribute("http.route", route) unless span.attributes&.key?("http.route")
      rescue StandardError
        nil
      end

      ID_SEGMENT = /\A(?:\d+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{16,}|[A-Za-z0-9_-]{22,})\z/i

      def quantize(path)
        return "/" if path.empty?

        path.split("/", -1).map { |segment| segment.match?(ID_SEGMENT) ? ":id" : segment }.join("/")
      end
    end

    # A Rack app inside another (Sinatra's own middleware inside `use Zharp::Rack`, or a Rails engine)
    # gets no second server span: the outer one is the request.
    module NestedSpan
      def on_start(request, response)
        outer = request.env["otel.rack.context_info"]
        return if outer.is_a?(Hash) && !outer.empty?

        super
      end
    end

    def self.patch_nested
      %w[Stable Dup Old].each do |name|
        mod = ::OpenTelemetry::Instrumentation::Rack::Middlewares.const_get(name) rescue next
        handler = mod.const_get(:EventHandler) rescue next
        handler.prepend(NestedSpan) unless handler.ancestors.include?(NestedSpan)
      end
    end
  end
end
