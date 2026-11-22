# frozen_string_literal: true

module Zharp
  # Rails starts Zharp by itself: Bundler.require loads the gem, and this Railtie calls Zharp.init
  # once config/initializers have run (config/initializers/zharp.rb may call it first, with options).
  # It adds Zharp's header layer next to OpenTelemetry's Rack middleware and subscribes to
  # Rails.error, which Rails reports every unhandled request and job error to.
  class Railtie < ::Rails::Railtie
    initializer "zharp.start", after: :load_config_initializers do |app|
      Zharp.init unless Zharp.active?
      if Zharp.active? && Zharp.options.tracing
        # OpenTelemetry's middleware was inserted at 0 when it was installed: ours goes right after it.
        app.middleware.insert_after(0, Zharp::Rack::Headers)
      end
      Rails.error.subscribe(Zharp::ErrorSubscriber.new) if Zharp.active? && Rails.respond_to?(:error)
    end

    # semantic_logger (rails_semantic_logger) may be set up after Zharp started.
    config.after_initialize do
      Setup.install_semantic_logger if Zharp.active?
    end

    generators do
      require_relative "../generators/zharp/install/install_generator"
    end
  end

  # Rails.error: handled reports (Rails.error.handle, Rails.error.report) and unhandled ones (from
  # the executor around requests and jobs). On the request's span when there is one, else a log
  # record; never twice for one exception.
  class ErrorSubscriber
    def report(error, handled:, severity: :error, context: {}, source: nil)
      return if Errors.reported?(error) || severity == :info

      span = Rack.server_span
      if span.recording? && !handled
        span.record_exception(error, attributes: { "zharp.handled" => "false" })
      else
        attributes = {}
        attributes["zharp.source"] = source.to_s if source
        Zharp.report(error, handled: handled, attributes: attributes)
      end
    rescue StandardError => e
      Zharp.debug("Rails.error: #{e.message}")
    end
  end
end
