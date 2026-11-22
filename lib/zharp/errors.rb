# frozen_string_literal: true

module Zharp
  # Errors: one report per exception, marked handled or not.
  #
  # An exception that escapes a request is seen several times: Action Pack records it on the
  # request's span, Rails reports it to Rails.error, the Rack middleware sees it, a job runner's
  # error handler gets it. The first sighting reports it and marks the exception object; later ones
  # keep their span status but don't report it again.
  module Errors
    MARK = :@__zharp_reported

    # Lines of a database error that carry the row's values: Postgres's "DETAIL:  Key (email)=(…)".
    # The statement, the constraint and the code say enough.
    PRIVATE_LINES = /^[ \t]*DETAIL:.*(?:\r?\n|\z)/

    # Values inside the messages themselves, each replaced by a quoted ?.
    PRIVATE_VALUES = {
      # MySQL 1062 (mysql2, trilogy): Duplicate entry 'a@b.c' for key 'users.index_users_on_email'
      /(Duplicate entry )'.*?'(?= for key)/m => "'?'",
      # MySQL 1366/1292: Incorrect integer value: 'abc' for column 'age' at row 1
      /(Incorrect [\w ]+? value: )'.*?'(?= for |\s*\z)/m => "'?'",
      # MySQL 1292: Truncated incorrect DOUBLE value: 'abc'
      /(Truncated incorrect [\w ]+? value: )'.*?'/m => "'?'",
      # Postgres: invalid input syntax for type integer: "abc"
      /(invalid input syntax for type [\w ]+?: )".*?"/m => '"?"',
      # Postgres: invalid input value for enum mood: "x"
      /(invalid input value for enum \S+: )".*?"/m => '"?"',
      # Postgres: value "123456789012" is out of range for type integer
      /(value )".*?"(?= is out of range)/m => '"?"'
    }.freeze
    # Drivers whose messages are scrubbed. MySQL's 1048/1265/1452 and Postgres's other messages
    # carry no values (a not-null or foreign-key violation's row is in its DETAIL line).
    DB_ERROR_CLASSES = ["PG::", "Mysql2::", "Trilogy", "ActiveRecord::", "SQLite3::"].freeze

    class << self
      # The failed-query watcher (DbErrors::Processor) when tracing is on.
      attr_accessor :db_errors

      # Reported already: this exception itself, or one it wraps that escaped (unhandled). A wrapper
      # and what it wraps (ActionView::Template::Error around the template's NoMethodError) are one
      # failure. An exception the app reported as handled and then wrapped in a new one it raised
      # doesn't hide the new one.
      def reported?(error)
        return false if error.nil?
        return true if marked(error)

        related(error).drop(1).any? { |e| marked(e) == :unhandled }
      rescue StandardError
        false
      end

      def marked(error)
        error.instance_variable_defined?(MARK) ? error.instance_variable_get(MARK) : nil
      end

      # Marks the exception; an unhandled one marks its causes too, so whichever of a wrapper and
      # its cause is seen second is not reported again.
      def mark(error, handled: false)
        return if error.nil?

        (handled ? [error] : related(error)).each do |e|
          e.instance_variable_set(MARK, handled ? :handled : :unhandled) unless marked(e) == :unhandled
        rescue StandardError # a frozen exception
          nil
        end
      end

      # The query attributes of the failed query this error came from, if any ({} when none).
      def query_of(error)
        db_errors ? (db_errors.claim(error) || {}) : {}
      rescue StandardError
        {}
      end

      def db_error?(error)
        related(error).any? do |e|
          name = e.class.name.to_s
          name.start_with?(*DB_ERROR_CLASSES)
        end
      end

      # An exception and what it wraps (ActiveRecord::StatementInvalid's cause is the driver's error).
      def related(error)
        out = [error]
        inner = error.respond_to?(:cause) ? error.cause : nil
        while inner && out.size < 5 && !out.include?(inner)
          out << inner
          inner = inner.cause
        end
        out
      end

      def scrub(text)
        text = text.to_s.gsub(PRIVATE_LINES, "")
        PRIVATE_VALUES.each { |pattern, value| text = text.gsub(pattern) { "#{Regexp.last_match(1)}#{value}" } }
        text
      end

      def message_of(error)
        message = error.message.to_s
        db_error?(error) ? scrub(message).rstrip : message
      end

      # The stack as Ruby prints it, innermost first: what OpenTelemetry's record_exception sends.
      def stack_of(error)
        stack = error.full_message(highlight: false, order: :top)
        stack = scrub(stack) if db_error?(error)
        stack.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
      rescue StandardError
        "#{error.class}: #{error.message}"
      end

      def attributes(error, handled)
        attrs = {
          "exception.type" => error.class.name.to_s,
          "exception.message" => message_of(error),
          "exception.stacktrace" => stack_of(error),
          "zharp.handled" => handled ? "true" : "false"
        }
        code = Source.of_exception(error)
        attrs[Source::ATTRIBUTE] = code if code
        attrs
      end
    end

    # Span#record_exception skips an exception already reported, holds a failed query's exception
    # (DbErrors) and says handled=false: instrumentations call it for an exception that escaped
    # their span, which is what an uncaught error is. A caller that knows better passes
    # "zharp.handled" => "true".
    module RecordException
      def record_exception(exception, attributes: nil)
        return if Errors.reported?(exception)
        return if Errors.db_errors&.hold(self, exception)

        Errors.mark(exception, handled: attributes.is_a?(Hash) && attributes["zharp.handled"] == "true")
        merged = { "zharp.handled" => "false" }
        merged.merge!(Errors.query_of(exception))
        code = Source.of_exception(exception)
        merged[Source::ATTRIBUTE] = code if code
        if Errors.db_error?(exception)
          merged["exception.message"] = Errors.message_of(exception)
          merged["exception.stacktrace"] = Errors.stack_of(exception)
        end
        merged.merge!(attributes) if attributes
        super(exception, attributes: merged)
      rescue StandardError => e
        Zharp.debug("record_exception: #{e.message}")
        super
      end
    end

    def self.patch_record_exception
      span = ::OpenTelemetry::SDK::Trace::Span
      span.prepend(RecordException) unless span.ancestors.include?(RecordException)
    end
  end
end
