# frozen_string_literal: true

require "json"

module Zharp
  # The request's ids at the end of each log line written in it: " trace_id=<32 hex> span_id=<16 hex>"
  # on a text line, two fields on a JSON line (which stays valid JSON). The Zharp agent reads the
  # app's output and links each line to its request by them. Lines outside a request, blank lines,
  # lines already carrying a trace_id and Zharp's own lines are left as they are.
  module Stamp
    module_function

    # The current span's ids as lowercase hex; nil outside a request.
    def current_ids(context = nil)
      span_context = ::OpenTelemetry::Trace.current_span(context).context
      return nil unless span_context.valid?

      [span_context.hex_trace_id, span_context.hex_span_id]
    rescue StandardError
      nil
    end

    def json_object?(text)
      JSON.parse(text).is_a?(Hash)
    rescue JSON::ParserError, TypeError
      false
    end

    def stamp_line(line, ids)
      trace_id, span_id = ids
      newline = line[/\r?\n\z/] || ""
      body = line[0, line.length - newline.length]
      trimmed = body.rstrip
      return line if trimmed.strip.empty? || body.include?("trace_id") || body.include?("[Zharp]")

      tail = body[trimmed.length..]
      start = trimmed.length - trimmed.lstrip.length
      if trimmed.end_with?("}") && trimmed[start] == "{" && json_object?(trimmed[start..])
        close = trimmed.rindex("}")
        inner = trimmed[(start + 1)...close].strip
        fields = %("trace_id":"#{trace_id}","span_id":"#{span_id}")
        return "#{trimmed[0...close]}#{inner.empty? ? '' : ','}#{fields}}#{tail}#{newline}"
      end
      "#{trimmed} trace_id=#{trace_id} span_id=#{span_id}#{tail}#{newline}"
    end

    # One record (which may span lines: a backtrace) stamped once, at the end of its last line.
    def stamp_record(text, ids = nil)
      return text unless text.is_a?(String) && !text.empty? && !text.include?("trace_id")

      ids ||= current_ids
      return text unless ids

      lines = text.split(/(?<=\n)/)
      index = lines.rindex { |l| !l.strip.empty? }
      return text unless index

      lines[index] = stamp_line(lines[index], ids)
      lines.join
    end

    # On Ruby's Logger (so Rails.logger, ActiveSupport::Logger, lograge): each formatted line.
    module LoggerPatch
      def format_message(severity, datetime, progname, msg)
        text = super
        Stamp.enabled ? Stamp.stamp_record(text) : text
      rescue StandardError
        text
      end
    end

    class << self
      attr_accessor :enabled
    end
    @enabled = false

    def install_logger
      ::Logger.prepend(LoggerPatch) unless ::Logger.ancestors.include?(LoggerPatch)
    end

    # semantic_logger formats on its own thread: the ids are taken when the line is logged, and put
    # on the line when its formatter writes it.
    module SemanticLogPatch
      def initialize(*args, **kwargs, &block)
        super
        @__zharp_ids = Stamp.current_ids
      end

      attr_reader :__zharp_ids
    end

    module SemanticFormatterPatch
      def call(log, logger)
        out = super
        ids = log.respond_to?(:__zharp_ids) ? log.__zharp_ids : nil
        return out unless Stamp.enabled && ids

        case out
        when String then Stamp.stamp_record(out, ids)
        when Hash then out.merge(trace_id: ids[0], span_id: ids[1])
        else out
        end
      rescue StandardError
        out
      end
    end

    def install_semantic_logger
      return false unless defined?(::SemanticLogger::Log) && defined?(::SemanticLogger::Formatters)

      ::SemanticLogger::Log.prepend(SemanticLogPatch) unless ::SemanticLogger::Log.ancestors.include?(SemanticLogPatch)
      ::SemanticLogger::Formatters.constants.each do |name|
        klass = ::SemanticLogger::Formatters.const_get(name)
        next unless klass.is_a?(Class) && klass.method_defined?(:call)
        next if klass.ancestors.include?(SemanticFormatterPatch) || klass.instance_method(:call).owner != klass

        klass.prepend(SemanticFormatterPatch)
      rescue StandardError, LoadError
        next
      end
      true
    end
  end
end
