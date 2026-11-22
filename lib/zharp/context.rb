# frozen_string_literal: true

module Zharp
  # Who and what a span or log belongs to: the user, the session, and tags.
  #
  # A browser or mobile app using a Zharp SDK sends enduser.id and session.id in W3C baggage next to
  # traceparent. The processors here copy them onto every span and log of that request, so the back
  # end's telemetry joins the front end's. Zharp.set_user overrides them for the rest of the
  # request (or, outside one, for everything after).
  module Context
    USER_ID = "enduser.id"
    USER_EMAIL = "enduser.email"
    USER_NAME = "enduser.name"
    SESSION_ID = "session.id"
    PROPAGATED = [USER_ID, SESSION_ID].freeze
    INHERITED = [USER_ID, USER_EMAIL, USER_NAME, SESSION_ID].freeze
    USER_IVAR = :@__zharp_user

    @tags = {}
    @global_user = nil
    @lock = Mutex.new

    class << self
      attr_reader :tags

      # The user goes on the current span and the request's span (and from them onto every span
      # started after), or, outside a request, on everything after.
      def set_user(id: nil, email: nil, name: nil)
        user = { USER_ID => id, USER_EMAIL => email, USER_NAME => name }.compact.transform_values(&:to_s)
        spans = request_spans
        if spans.empty?
          @global_user = user.empty? ? nil : user
          return
        end
        spans.each do |span|
          span.instance_variable_set(USER_IVAR, user)
          span.add_attributes(user) unless user.empty?
        end
      end

      def clear_user
        set_user
      end

      def set_tag(key, value)
        @lock.synchronize do
          if value.nil?
            @tags = @tags.reject { |k, _| k == key.to_s }
          else
            @tags = @tags.merge(key.to_s => plain_value(value))
          end
        end
      end

      def request_spans
        spans = [::OpenTelemetry::Trace.current_span]
        spans << ::OpenTelemetry::Instrumentation::Rack.current_span if defined?(::OpenTelemetry::Instrumentation::Rack) && ::OpenTelemetry::Instrumentation::Rack.respond_to?(:current_span)
        spans.select(&:recording?).uniq
      end

      # The tags, then user and session from the parent span, baggage and set_user (later wins).
      def attributes_for(context = nil)
        context ||= ::OpenTelemetry::Context.current
        out = @tags.dup
        parent = ::OpenTelemetry::Trace.current_span(context)
        if parent.respond_to?(:attributes) && parent.recording?
          attrs = parent.attributes || {}
          INHERITED.each { |k| out[k] = attrs[k] if attrs[k] && !attrs[k].to_s.empty? }
        end
        PROPAGATED.each do |k|
          value = ::OpenTelemetry::Baggage.value(k, context: context)
          out[k] = value.to_s if value && !value.to_s.empty?
        end
        user = parent.instance_variable_get(USER_IVAR) if parent.instance_variable_defined?(USER_IVAR)
        user ||= @global_user
        if user
          [USER_ID, USER_EMAIL, USER_NAME].each { |k| out.delete(k) }
          out.merge!(user)
        end
        out
      end

      def plain_value(value)
        case value
        when String, Integer, Float, true, false then value
        when Array then value.all? { |v| v.is_a?(String) || v.is_a?(Numeric) || v == true || v == false } ? value : value.to_s
        else value.to_s
        end
      end

      def plain(attributes)
        (attributes || {}).each_with_object({}) do |(k, v), out|
          out[k.to_s] = plain_value(v) unless v.nil?
        end
      end
    end

    # Puts user, session and tags on every span as it starts; a span inherits its parent's set_user.
    class SpanProcessor
      def on_start(span, parent_context)
        attrs = Context.attributes_for(parent_context)
        span.add_attributes(attrs) unless attrs.empty?
        parent = ::OpenTelemetry::Trace.current_span(parent_context)
        if parent.instance_variable_defined?(USER_IVAR)
          span.instance_variable_set(USER_IVAR, parent.instance_variable_get(USER_IVAR))
        end
      rescue StandardError => e
        Zharp.debug("context: #{e.message}")
      end

      def on_finishing(span); end
      def on_finish(span); end

      def force_flush(timeout: nil) = ::OpenTelemetry::SDK::Trace::Export::SUCCESS
      def shutdown(timeout: nil) = ::OpenTelemetry::SDK::Trace::Export::SUCCESS
    end

    # Puts user, session and tags on every log record, before it is batched.
    class LogProcessor
      def on_emit(log_record, context)
        extra = Context.attributes_for(context)
        return if extra.empty?

        log_record.attributes = extra.merge(log_record.attributes || {})
      rescue StandardError => e
        Zharp.debug("context: #{e.message}")
      end

      def force_flush(timeout: nil) = ::OpenTelemetry::SDK::Logs::Export::SUCCESS
      def shutdown(timeout: nil) = ::OpenTelemetry::SDK::Logs::Export::SUCCESS
    end
  end
end
