# frozen_string_literal: true

require "monitor"
require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry-logs-sdk"
require "opentelemetry-exporter-otlp-logs"
require_relative "zharp/instrumentations"

require_relative "zharp/version"
require_relative "zharp/config"
require_relative "zharp/headers"
require_relative "zharp/bodies"
require_relative "zharp/capture"
require_relative "zharp/source"
require_relative "zharp/errors"
require_relative "zharp/db_errors"
require_relative "zharp/context"
require_relative "zharp/stamp"
require_relative "zharp/logs"
require_relative "zharp/fork"
require_relative "zharp/rack"
require_relative "zharp/setup"

# Zharp Application Monitoring for Ruby.
#
#   Rails:       bundle add zharp, set ZHARP_KEY. That's all (a Railtie starts it).
#   Rack apps:   require "zharp"; use Zharp::Rack (in config.ru)
#   Plain Ruby:  require "zharp"; Zharp.init(service: "billing-worker")
#
# Requests, database queries, outgoing HTTP calls and jobs are traced, errors become Zharp issues
# (each once, with the code that ran), and each log line written during a request ends with its
# trace and span id for the Zharp agent that reads the app's output (ZHARP_LOGS=true sends the
# logs from the SDK instead, where there is no agent). A thin layer over the official
# OpenTelemetry SDK: anything you instrument with OpenTelemetry yourself is sent too.
module Zharp
  @state = nil
  @lock = Monitor.new

  class << self
    # Start sending traces, errors and logs to Zharp. Call once, after your gems are loaded (Rails
    # calls it for you). Anything not passed is read from the environment: ZHARP_KEY (in Rails also
    # credentials.zharp.key), ZHARP_SERVICE (then OTEL_SERVICE_NAME), ZHARP_ENVIRONMENT,
    # ZHARP_RELEASE, ZHARP_ENDPOINT, ZHARP_SAMPLE_RATE, ZHARP_TRACING, ZHARP_LOGS,
    # ZHARP_LOG_CORRELATION, ZHARP_CAPTURE_HEADERS, ZHARP_CAPTURE_QUERY_ERRORS,
    # ZHARP_CAPTURE_SOURCE_CONTEXT. ZHARP_DISABLED=true turns it off.
    #
    # Options: key:, service:, environment:, release:, endpoint:, sample_rate: (0.0-1.0),
    # tracing: (false = logs and errors only), logs: (send log lines from the SDK; default false),
    # log_correlation: (the ids at the end of each line; default true), capture_headers: (false, or
    # { redact: ["x-tenant"] }), capture_query_errors:, capture_source_context:, capture_uncaught:,
    # instrument: (false = no automatic instrumentation), instrumentation: (options per
    # OpenTelemetry instrumentation, by class name), quiet: (no startup line).
    #
    # Returns true when it started. Never raises.
    def init(**args)
      @lock.synchronize do
        return true if @state
        return false if Config.disabled?

        options = Config.resolve(args)
        unless options
          Config.announce("No key — set ZHARP_KEY or pass key: to Zharp.init. Nothing is sent.") unless args[:quiet]
          return false
        end
        @state = Setup.start(options, exporters: args[:_exporters], batch: args.fetch(:_batch, true))
        install_exit_hook(options)
      end
      Config.announce(Setup.describe(@state)) unless args[:quiet]
      true
    rescue StandardError => e
      Config.announce("Could not start: #{e.message}")
      false
    end

    def active?
      !@state.nil?
    end

    def options
      @state&.options
    end

    def otel_logger
      @state&.logger
    end

    # Report an exception you rescued. It becomes a Zharp issue (marked handled), with the trace,
    # user and session of the current request.
    #
    #   rescue PaymentError => e
    #     Zharp.capture_error(e, order_id: order.id)
    def capture_error(error, attributes = {})
      report(error, handled: true, attributes: attributes)
    end

    # @api private: one report, as a log record in the current context.
    def report(error, handled:, attributes: {}, fatal: false, context: nil)
      return if @state.nil? || !error.is_a?(Exception) || Errors.reported?(error)

      Errors.mark(error)
      attrs = Context.plain(attributes)
      attrs.merge!(Errors.query_of(error))
      attrs.merge!(Errors.attributes(error, handled))
      message = attrs["exception.message"].to_s
      Logs.emit(fatal ? "FATAL" : "ERROR", fatal ? 21 : 17, message.empty? ? attrs["exception.type"] : "#{attrs['exception.type']}: #{message}", attrs, context)
    rescue StandardError => e
      debug("report: #{e.message}")
    end

    # The user of the current request (enduser.id), on its spans, logs and errors from here on.
    # Outside a request it applies to everything after. A browser or mobile app using a Zharp SDK
    # already sends its user with each request.
    def set_user(id: nil, email: nil, name: nil)
      Context.set_user(id: id, email: email, name: name)
    rescue StandardError
      nil
    end

    def clear_user
      Context.clear_user
    rescue StandardError
      nil
    end

    # An attribute on every span and log from now on (nil removes it).
    def set_tag(key, value)
      Context.set_tag(key, value)
    rescue StandardError
      nil
    end

    # A span around some work: Zharp.start_span("render invoice") { render(invoice) }. An exception
    # that escapes is recorded on the span and raised on. With tracing off the block runs as is.
    def start_span(name, attributes: {}, kind: :internal, &block)
      tracer = @state&.tracer || ::OpenTelemetry.tracer_provider.tracer("zharp", VERSION)
      tracer.in_span(name, attributes: Context.plain(attributes), kind: kind, &block)
    end

    # Zharp.log.info("order paid", order_id: 1): debug, info, warn, error, fatal. Sent whether or
    # not ZHARP_LOGS is on: these are the lines you want in Zharp from the SDK itself.
    def log
      @log ||= LogApi.new
    end

    # Send everything queued now, waiting up to timeout seconds: at the end of a script or job.
    def flush(timeout: 5)
      state = @state
      return true unless state

      ok = true
      Errors.db_errors&.force_flush
      [state.tracer_provider, state.logger_provider].compact.each do |provider|
        ok = provider.force_flush(timeout: timeout) == 0 && ok
      end
      ok
    rescue StandardError
      false
    end

    # Send what's left and stop. Runs by itself when the program exits.
    def shutdown(timeout: 5)
      state = nil
      @lock.synchronize do
        state = @state
        @state = nil
      end
      return unless state

      Errors.db_errors&.force_flush
      [state.tracer_provider, state.logger_provider].compact.each do |provider|
        provider.shutdown(timeout: timeout)
      rescue StandardError
        nil
      end
    end

    def debug(message)
      Config.announce("debug: #{message}") if Config.flag(ENV["ZHARP_DEBUG"])
    end

    private

    # A script that crashes: the exception that ends it is reported (handled=false) and sent before
    # the process exits; then everything left is sent.
    def install_exit_hook(options)
      return if @exit_hook

      @exit_hook = true
      at_exit do
        error = $!
        if options.capture_uncaught && error && !error.is_a?(SystemExit) && !error.is_a?(Interrupt) &&
           !error.is_a?(SignalException) && !Errors.reported?(error)
          report(error, handled: false, fatal: true)
        end
        # A flush, not a shutdown: at_exit blocks run last-registered first, and one registered
        # before Zharp started (Minitest's, a CLI framework's) may still do traced work after this.
        flush(timeout: 5)
      end
    end
  end

  class LogApi
    def debug(message, attributes = {}) = Logs.emit("DEBUG", 5, message, Context.plain(attributes))
    def info(message, attributes = {}) = Logs.emit("INFO", 9, message, Context.plain(attributes))
    def warn(message, attributes = {}) = Logs.emit("WARN", 13, message, Context.plain(attributes))
    def fatal(message, attributes = {}) = Logs.emit("FATAL", 21, message, Context.plain(attributes))

    # An exception (as the message) is reported as an error, handled.
    def error(message, attributes = {})
      return Zharp.capture_error(message, attributes) if message.is_a?(Exception)

      Logs.emit("ERROR", 17, message, Context.plain(attributes))
    end
  end
end

require_relative "zharp/railtie" if defined?(::Rails::Railtie)
