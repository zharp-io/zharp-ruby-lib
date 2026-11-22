# frozen_string_literal: true

require "logger"
require "socket"

module Zharp
  # Wiring the official OpenTelemetry SDK to Zharp: exporters, resource, propagators, processors and
  # the instrumentations. No tracer of our own.
  module Setup
    State = Struct.new(:options, :tracer_provider, :logger_provider, :tracer, :logger, :instrumented, keyword_init: true)

    # Every instrumentation in opentelemetry-instrumentation-all switches on when its library is
    # loaded. Jobs run in the trace of the request that queued them (OpenTelemetry's default is a
    # linked trace of their own).
    INSTRUMENTATION = {
      "OpenTelemetry::Instrumentation::Sidekiq" => { propagation_style: :child },
      "OpenTelemetry::Instrumentation::ActiveJob" => { propagation_style: :child }
    }.freeze

    module_function

    def start(options, exporters: nil, batch: true)
      quiet_opentelemetry
      resource = resource_for(options)
      span_exporter, log_exporter = exporters || default_exporters(options)

      tracer_provider = nil
      if options.tracing
        tracer_provider = ::OpenTelemetry::SDK::Trace::TracerProvider.new(
          resource: resource,
          sampler: ::OpenTelemetry::SDK::Trace::Samplers.parent_based(
            root: ::OpenTelemetry::SDK::Trace::Samplers.trace_id_ratio_based(options.sample_rate)
          )
        )
        tracer_provider.add_span_processor(Context::SpanProcessor.new)
        if options.capture_query_errors
          # Before the exporter, so a failed query's held exception is reported before its trace ships.
          Errors.db_errors = DbErrors::Processor.new(method(:send_query_error))
          tracer_provider.add_span_processor(Errors.db_errors)
        end
        tracer_provider.add_span_processor(batch ? ::OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(span_exporter) : ::OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(span_exporter))
        ::OpenTelemetry.tracer_provider = tracer_provider
      end

      logger_provider = ::OpenTelemetry::SDK::Logs::LoggerProvider.new(resource: resource)
      logger_provider.add_log_record_processor(Context::LogProcessor.new)
      logger_provider.add_log_record_processor(batch ? ::OpenTelemetry::SDK::Logs::Export::BatchLogRecordProcessor.new(log_exporter) : ::OpenTelemetry::SDK::Logs::Export::SimpleLogRecordProcessor.new(log_exporter))
      ::OpenTelemetry.logger_provider = logger_provider

      ::OpenTelemetry.propagation = ::OpenTelemetry::Context::Propagation::CompositeTextMapPropagator.compose_propagators(
        [::OpenTelemetry::Trace::Propagation::TraceContext.text_map_propagator, ::OpenTelemetry::Baggage::Propagation.text_map_propagator]
      )

      Fork.register(span_exporter)
      Fork.register(log_exporter)
      Fork.install

      Source.enabled = options.capture_source_context
      Errors.patch_record_exception if options.tracing
      state = State.new(
        options: options,
        tracer_provider: tracer_provider,
        logger_provider: logger_provider,
        tracer: (tracer_provider || ::OpenTelemetry::Trace::TracerProvider.new).tracer("zharp", VERSION),
        logger: logger_provider.logger(name: "zharp", version: VERSION),
        instrumented: []
      )
      state.instrumented = instrument(options) if options.tracing && options.instrument
      start_logs(options)
      state
    end

    def resource_for(options)
      attributes = {
        "service.name" => options.service,
        "telemetry.sdk.name" => "zharp",
        "telemetry.sdk.language" => "ruby",
        "telemetry.sdk.version" => VERSION,
        "process.pid" => Process.pid,
        "process.runtime.name" => RUBY_ENGINE,
        "process.runtime.version" => RUBY_VERSION
      }
      attributes["service.version"] = options.release if options.release
      attributes["deployment.environment.name"] = options.environment if options.environment
      attributes["host.name"] = Socket.gethostname rescue nil
      # Resource.create adds OTEL_RESOURCE_ATTRIBUTES; ours win.
      ::OpenTelemetry::SDK::Resources::Resource.create(attributes.compact)
    end

    def default_exporters(options)
      headers = { "Authorization" => "Bearer #{options.key}" }
      [
        ::OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: "#{options.endpoint}/v1/traces", headers: headers, compression: "gzip"),
        ::OpenTelemetry::Exporter::OTLP::Logs::LogsExporter.new(endpoint: "#{options.endpoint}/v1/logs", headers: headers, compression: "gzip")
      ]
    end

    def instrument(options)
      config = INSTRUMENTATION.merge(options.instrumentation.transform_keys(&:to_s)) { |_k, ours, theirs| ours.merge(theirs) }
      ::OpenTelemetry::Instrumentation.registry.install_all(config)
      Rack.patch_nested if defined?(::OpenTelemetry::Instrumentation::Rack::Middlewares)
      install_sidekiq
      installed_names
    rescue StandardError => e
      Config.announce("Could not instrument: #{e.message}")
      []
    end

    def installed_names
      list = ::OpenTelemetry::Instrumentation.registry.instance_variable_get(:@instrumentation) || []
      list.map(&:instance).select(&:installed?).map { |i| i.name.split("::").last.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase }
    rescue StandardError
      []
    end

    # Sidekiq's server middleware records a job's exception on its span; the error handler reports
    # what fails outside it. Both mark the exception, so it is counted once.
    def install_sidekiq
      return unless defined?(::Sidekiq) && ::Sidekiq.respond_to?(:configure_server)

      ::Sidekiq.configure_server do |config|
        handler = ->(error, _context = nil, _config = nil) { Zharp.report(error, handled: false) unless Errors.reported?(error) }
        config.error_handlers << handler if config.respond_to?(:error_handlers)
      end
    rescue StandardError => e
      Zharp.debug("sidekiq: #{e.message}")
    end

    def start_logs(options)
      Stamp.enabled = options.log_correlation
      Stamp.install_logger
      Logs.sending = options.logs
      Logs.install_logger
      install_semantic_logger
    end

    def install_semantic_logger
      Stamp.install_semantic_logger
      Logs.install_semantic_logger
    end

    # A failed query nothing else reported: caught by the app, in the query's span.
    def send_query_error(error, stack, attributes, span_context)
      return if Errors.reported?(error)

      Errors.mark(error)
      attrs = Errors.attributes(error, true).merge(attributes)
      attrs["exception.stacktrace"] = stack
      attrs["zharp.mechanism"] = "db"
      context = ::OpenTelemetry::Trace.context_with_span(::OpenTelemetry::Trace.non_recording_span(span_context))
      Logs.emit("ERROR", 17, "#{attrs['exception.type']}: #{attrs['exception.message']}", attrs, context)
    end

    # OpenTelemetry's own messages: warnings only, and each one once (a wrong key would otherwise
    # print a line every few seconds).
    def quiet_opentelemetry
      logger = ::Logger.new($stderr, level: ::Logger::WARN, progname: "Zharp/OpenTelemetry")
      logger.instance_variable_set(:@__zharp_own, true)
      ::OpenTelemetry.logger = logger
      seen = {}
      lock = Mutex.new
      ::OpenTelemetry.error_handler = lambda do |exception: nil, message: nil|
        text = [message, exception&.message].compact.join(" - ")
        first = lock.synchronize do
          seen.clear if seen.size > 100
          seen[text[0, 200]] ? false : (seen[text[0, 200]] = true)
        end
        logger.warn("OpenTelemetry error: #{text}") if first
      end
    end

    def describe(state)
      options = state.options
      env = options.environment ? %(environment "#{options.environment}") : "no environment set"
      what = state.instrumented.empty? ? "no supported libraries found" : state.instrumented.join(", ")
      mode = options.tracing ? "Application Monitoring active" : "Application Monitoring active, logs only"
      %(#{mode} — service "#{options.service}", #{env} (#{what}))
    end
  end
end
