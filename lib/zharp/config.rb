# frozen_string_literal: true

module Zharp
  # Options from Zharp.init and the environment, read like the Python SDK's: what is passed wins,
  # then ZHARP_*, then the default. Returns nil from .resolve when there is no key.
  module Config
    DEFAULT_ENDPOINT = "https://api.zharp.io/api/v1/otlp"

    TRUE = /\A(true|1|yes|on)\z/i
    FALSE = /\A(false|0|no|off|none)\z/i

    Options = Struct.new(
      :key, :service, :environment, :release, :endpoint, :sample_rate,
      :tracing, :logs, :log_correlation, :capture_uncaught,
      :capture_headers, :capture_query_errors, :capture_source_context, :capture_bodies,
      :instrument, :instrumentation,
      keyword_init: true
    )

    module_function

    # An environment variable; nil when unset or blank.
    def env(name)
      value = ENV[name]
      return nil if value.nil?

      value = value.strip
      value.empty? ? nil : value
    end

    # The first value that is non-blank text.
    def pick(*values)
      values.each do |value|
        next if value.nil?

        text = value.to_s.strip
        return text unless text.empty?
      end
      nil
    end

    def flag(value)
      return nil if value.nil?
      return true if TRUE.match?(value.to_s)
      return false if FALSE.match?(value.to_s)

      nil
    end

    # ZHARP_DISABLED=true: start nothing, whatever the code asks for.
    def disabled?
      flag(env("ZHARP_DISABLED")) == true
    end

    # An on/off setting: the argument when passed, else the environment variable, else the default.
    def switch(value, variable, default)
      return value ? true : false unless value.nil?

      from_env = flag(env(variable))
      from_env.nil? ? default : from_env
    end

    def resolve(args = {})
      key = pick(args[:key], env("ZHARP_KEY"), env("ZHARP_API_KEY"), credentials_key)
      return nil unless key

      Options.new(
        key: key,
        service: pick(args[:service], env("ZHARP_SERVICE"), env("OTEL_SERVICE_NAME"), app_name) || "unknown-service",
        environment: pick(args[:environment], env("ZHARP_ENVIRONMENT"), env("ZHARP_ENV"), rails_env),
        release: pick(args[:release], env("ZHARP_RELEASE"), env("ZHARP_VERSION")),
        endpoint: (pick(args[:endpoint], env("ZHARP_ENDPOINT")) || DEFAULT_ENDPOINT).sub(%r{/+\z}, ""),
        sample_rate: sample_rate(args[:sample_rate]),
        tracing: switch(args[:tracing], "ZHARP_TRACING", true),
        logs: switch(args[:logs], "ZHARP_LOGS", false),
        log_correlation: switch(args[:log_correlation], "ZHARP_LOG_CORRELATION", true),
        capture_uncaught: args.fetch(:capture_uncaught, true) ? true : false,
        capture_headers: Headers.settings(args[:capture_headers], env("ZHARP_CAPTURE_HEADERS")),
        capture_query_errors: switch(args[:capture_query_errors], "ZHARP_CAPTURE_QUERY_ERRORS", true),
        capture_source_context: switch(args[:capture_source_context], "ZHARP_CAPTURE_SOURCE_CONTEXT", true),
        capture_bodies: Bodies.settings(args[:capture_bodies], env("ZHARP_CAPTURE_BODIES")),
        instrument: args.fetch(:instrument, true) ? true : false,
        instrumentation: args[:instrumentation] || {}
      )
    end

    def sample_rate(value)
      rate = value.nil? ? Float(env("ZHARP_SAMPLE_RATE") || 1.0) : Float(value)
      rate.clamp(0.0, 1.0)
    rescue ArgumentError, TypeError
      1.0
    end

    # Rails: credentials.zharp.key (bin/rails credentials:edit), after ZHARP_KEY.
    def credentials_key
      return nil unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

      ::Rails.application.credentials.dig(:zharp, :key)
    rescue StandardError
      nil
    end

    def rails_env
      defined?(::Rails) && ::Rails.respond_to?(:env) ? ::Rails.env.to_s : nil
    rescue StandardError
      nil
    end

    # The Rails app's name (Shop::Application -> "shop"), else the project folder Bundler runs in.
    def app_name
      if defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application
        name = ::Rails.application.class.name.to_s.split("::").first
        return name.gsub(/([a-z\d])([A-Z])/, '\1-\2').downcase if name && !name.empty?
      end
      return File.basename(::Bundler.root.to_s) if defined?(::Bundler) && ::Bundler.respond_to?(:root)

      nil
    rescue StandardError
      nil
    end

    # One line on stderr, prefixed so it can be searched for.
    def announce(message)
      $stderr.write("[Zharp] #{message}\n")
    rescue StandardError
      nil
    end
  end
end
