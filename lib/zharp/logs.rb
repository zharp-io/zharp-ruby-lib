# frozen_string_literal: true

module Zharp
  # What the app logs, sent from the SDK. Off by default: on a server the Zharp agent reads the
  # app's output and brings those lines in, linked to their request by the stamp. With
  # ZHARP_LOGS=true (where there is no agent), each line written through Ruby's Logger (Rails.logger,
  # lograge) or semantic_logger is sent as an OpenTelemetry log record in its request's context.
  #
  # Either way, an exception passed to a logger (logger.error(e)) is an error: reported once,
  # handled.
  module Logs
    SEVERITY = {
      0 => ["DEBUG", 5], 1 => ["INFO", 9], 2 => ["WARN", 13], 3 => ["ERROR", 17], 4 => ["FATAL", 21], 5 => ["INFO", 9]
    }.freeze
    SEMANTIC = { trace: ["TRACE", 1], debug: ["DEBUG", 5], info: ["INFO", 9], warn: ["WARN", 13], error: ["ERROR", 17], fatal: ["FATAL", 21] }.freeze

    class << self
      attr_accessor :sending
    end
    @sending = false

    module_function

    def emit(severity_text, severity_number, body, attributes = {}, context = nil)
      logger = Zharp.otel_logger
      return unless logger

      logger.on_emit(
        timestamp: Time.now,
        severity_text: severity_text,
        severity_number: severity_number,
        body: body.to_s,
        attributes: attributes,
        context: context || ::OpenTelemetry::Context.current
      )
    end

    def own?(logger)
      logger.equal?(::OpenTelemetry.logger) || logger.instance_variable_defined?(:@__zharp_own)
    end

    # On Ruby's Logger#add: an exception is reported; with logs on, the line is sent.
    module LoggerPatch
      def add(severity, message = nil, progname = nil, &block)
        return super if Thread.current[:__zharp_in_log] || Logs.own?(self)

        severity ||= ::Logger::UNKNOWN
        return super if severity < level

        Thread.current[:__zharp_in_log] = true
        begin
          text = message
          if text.nil?
            if block
              text = yield
              block = nil
              message = text
            else
              text = progname
            end
          end
          if text.is_a?(Exception)
            Zharp.report(text, handled: true) unless Errors.reported?(text)
          elsif Logs.sending && text && !Logs.duplicate?(severity, text)
            name, number = SEVERITY[severity] || SEVERITY[5]
            Logs.emit(name, number, text.is_a?(String) ? text.strip : text.inspect, { "log.logger" => (progname || "ruby").to_s })
          end
        rescue StandardError => e
          Zharp.debug("logs: #{e.message}")
        ensure
          Thread.current[:__zharp_in_log] = false
        end
        super(severity, message, progname, &block)
      end
    end

    # Rails 7.1+ broadcasts one line to several loggers (stdout and a file): sent once.
    def duplicate?(severity, text)
      key = [severity, text.object_id]
      last = Thread.current[:__zharp_last_log]
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Thread.current[:__zharp_last_log] = [key, now]
      last && last[0] == key && now - last[1] < 0.05
    end

    def install_logger
      ::Logger.prepend(LoggerPatch) unless ::Logger.ancestors.include?(LoggerPatch)
    end

    # semantic_logger: an appender that sends each line, in the context it was logged in.
    # Included in a SemanticLogger::Subscriber subclass made when semantic_logger is present.
    module SemanticAppender
      def log(log)
        if log.exception && !Errors.reported?(log.exception)
          Zharp.report(log.exception, handled: true)
        end
        return true unless Logs.sending

        name, number = SEMANTIC[log.level] || SEMANTIC[:info]
        ids = log.respond_to?(:__zharp_ids) ? log.__zharp_ids : nil
        context = nil
        if ids
          span_context = ::OpenTelemetry::Trace::SpanContext.new(
            trace_id: [ids[0]].pack("H*"), span_id: [ids[1]].pack("H*"), trace_flags: ::OpenTelemetry::Trace::TraceFlags::SAMPLED
          )
          context = ::OpenTelemetry::Trace.context_with_span(::OpenTelemetry::Trace.non_recording_span(span_context))
        end
        attributes = { "log.logger" => log.name.to_s }
        (log.named_tags || {}).each { |k, v| attributes["log.tag.#{k}"] = v.to_s }
        (log.payload || {}).each { |k, v| attributes[k.to_s] = Context.plain_value(v) } if log.payload.is_a?(Hash)
        Logs.emit(name, number, log.message.to_s, attributes, context)
        true
      rescue StandardError => e
        Zharp.debug("semantic_logger: #{e.message}")
        true
      end
    end

    def install_semantic_logger
      return false unless defined?(::SemanticLogger::Subscriber)
      return true if ::SemanticLogger.appenders.any? { |a| a.is_a?(SemanticAppender) }

      ::SemanticLogger.add_appender(appender: Class.new(::SemanticLogger::Subscriber) { include SemanticAppender }.new)
      true
    end
  end
end
