# frozen_string_literal: true

module Zharp
  # Failed database queries as errors that say where they came from.
  #
  # The driver's instrumentation (pg, mysql2, trilogy) records the exception on the query's span
  # first, before it has travelled anywhere. So:
  # - that record_exception is held, not reported, and the app's call site is taken there;
  # - if the exception then escapes (Action Pack, Rails.error, the Rack middleware, a job runner),
  #   that one report carries the query: statement, system, database, code;
  # - if the app caught it, it is reported as handled when the request or job ends, with the call
  #   site as its stack.
  # One report per failure either way. ActiveRecord::StatementInvalid counts as its driver's error
  # (its cause).
  module DbErrors
    DB_SYSTEM = %w[db.system db.system.name].freeze
    STATEMENT = %w[db.query.text db.statement].freeze
    DATABASE = %w[db.namespace db.name].freeze
    # How long a failure outside any request waits for a handler before it is reported as caught.
    LONE_WAIT = 1.5
    MAX_PENDING = 200
    MAX_FRAMES = 40

    Failure = Struct.new(:error, :frames, :attributes, :span_context, :done)

    module_function

    def first(attributes, names)
      return nil unless attributes

      names.each do |name|
        value = attributes[name]
        return value.to_s unless value.nil? || value.to_s.empty?
      end
      nil
    end

    # The app's part of a call site, innermost first: from its own first frame on (Active Record
    # and the driver between the app and the query are left out), never Zharp or OpenTelemetry.
    def app_frames(locations)
      kept = locations.reject { |l| (l.absolute_path || l.path).to_s.start_with?(Paths::ZHARP_DIR) }
      first_app = kept.index { |l| Paths.app?(l.absolute_path || l.path) } || 0
      kept[first_app..].first(MAX_FRAMES)
    end

    # The call site as Ruby prints a stack: the first line with the message, then "from" lines.
    def format_stack(frames, error)
      message = Errors.scrub(error.message.to_s).rstrip
      head = frames.first ? "#{frames.first}: #{message} (#{error.class.name})" : "#{message} (#{error.class.name})"
      ([head] + frames.drop(1).map { |f| "\tfrom #{f}" }).join("\n") + "\n"
    end

    def query_attributes(span_attributes, error)
      out = { "db.system" => first(span_attributes, DB_SYSTEM) || "database" }
      statement = first(span_attributes, STATEMENT) || statement_of(error)
      out["db.query.text"] = statement[0, 4000] if statement
      database = first(span_attributes, DATABASE)
      out["db.namespace"] = database if database
      code, constraint = codes_of(error)
      out["db.error.code"] = code if code
      out["db.error.constraint"] = constraint if constraint
      out
    end

    # Active Record's statement, obfuscated as OpenTelemetry's pg instrumentation does.
    def statement_of(error)
      Errors.related(error).each do |e|
        next unless e.respond_to?(:sql) && e.sql

        return ::OpenTelemetry::Helpers::SqlProcessor.obfuscate_sql(e.sql.to_s) if defined?(::OpenTelemetry::Helpers::SqlProcessor)
      end
      nil
    rescue StandardError
      nil
    end

    # Postgres's SQLSTATE and constraint; MySQL's error number.
    def codes_of(error)
      Errors.related(error).each do |e|
        if defined?(::PG::Error) && e.is_a?(::PG::Error) && e.respond_to?(:result) && e.result
          return [e.result.error_field(::PG::PG_DIAG_SQLSTATE), e.result.error_field(::PG::PG_DIAG_CONSTRAINT_NAME)]
        end
        return [e.error_number.to_s, nil] if e.respond_to?(:error_number) && e.error_number
        return [e.error_code.to_s, nil] if e.class.name.to_s.start_with?("Trilogy") && e.respond_to?(:error_code) && e.error_code
      end
      [nil, nil]
    rescue StandardError
      [nil, nil]
    end

    # Watches query spans: their failure when they end, and the end of the request or job they ran
    # in. send.call(error, stack, attributes, span_context) reports what nothing else claimed.
    class Processor
      def initialize(send)
        @send = send
        @lock = Mutex.new
        @held = {}
        @pending = {}
        @local_roots = {}
      end

      # Called by the patched Span#record_exception. True when held.
      def hold(span, error)
        return false unless DbErrors.first(span.attributes, DB_SYSTEM)

        site = caller_locations(2) || []
        @lock.synchronize { @held[span.context.span_id] ||= [error, site] }
        true
      end

      def on_start(span, parent_context)
        parent = ::OpenTelemetry::Trace.current_span(parent_context).context
        return if parent.valid? && !parent.remote?

        @lock.synchronize do
          @local_roots[span.context.span_id] = true
          @local_roots.shift while @local_roots.size > 10_000
        end
      end

      def on_finishing(span); end

      def on_finish(span)
        span_id = span.context.span_id
        trace_id = span.context.trace_id
        held = @lock.synchronize { @held.delete(span_id) }
        if held && span.status.code == ::OpenTelemetry::Trace::Status::ERROR
          error, site = held
          add(trace_id, Failure.new(error, DbErrors.app_frames(site), DbErrors.query_attributes(span.attributes, error), span.context, false))
        end
        root = @lock.synchronize { @local_roots.delete(span_id) }
        return unless root || span.kind == :server || span.kind == :consumer

        waiting = @lock.synchronize { @pending.key?(trace_id) }
        return unless waiting

        if held || span.status.code == ::OpenTelemetry::Trace::Status::ERROR
          # The query was the whole trace, or its root failed: the exception may still be on its
          # way to a handler, which reports it itself.
          Thread.new { sleep(LONE_WAIT); flush(trace_id) }
        else
          flush(trace_id)
        end
      rescue StandardError => e
        Zharp.debug("db errors: #{e.message}")
      end

      def add(trace_id, failure)
        @lock.synchronize do
          failures = (@pending[trace_id] ||= [])
          mine = Errors.related(failure.error)
          # The same failure seen by two instrumentations: once.
          return if failures.any? { |f| mine.include?(f.error) || Errors.related(f.error).include?(failure.error) }

          failures << failure
          @pending.shift if @pending.size > MAX_PENDING
        end
      end

      # error is being reported: the attributes of the failed query it came from, if any, and that
      # failure is not reported again.
      def claim(error)
        return nil if error.nil?

        wanted = Errors.related(error)
        @lock.synchronize do
          @pending.each_value do |failures|
            failures.each do |f|
              next if f.done
              next unless wanted.any? { |c| c.equal?(f.error) || Errors.related(f.error).include?(c) }

              f.done = true
              return f.attributes.dup
            end
          end
        end
        nil
      end

      def flush(trace_id)
        failures = @lock.synchronize { @pending.delete(trace_id) } || []
        failures.each do |f|
          next if f.done || Errors.reported?(f.error)

          attributes = f.attributes.dup
          code = Source.context_of(f.frames.map { |l| [l.path, l.absolute_path || l.path, l.lineno] })
          attributes[Source::ATTRIBUTE] = code if code
          @send.call(f.error, DbErrors.format_stack(f.frames, f.error), attributes, f.span_context)
        rescue StandardError => e
          Zharp.debug("db errors: #{e.message}")
        end
      end

      def force_flush(timeout: nil)
        @lock.synchronize { @pending.keys }.each { |trace_id| flush(trace_id) }
        ::OpenTelemetry::SDK::Trace::Export::SUCCESS
      end

      def shutdown(timeout: nil)
        force_flush
      end
    end
  end
end
