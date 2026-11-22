# frozen_string_literal: true

require_relative "lib/zharp/version"

Gem::Specification.new do |spec|
  spec.name = "zharp"
  spec.version = Zharp::VERSION
  spec.authors = ["Zharp"]
  spec.email = ["support@zharp.io"]

  spec.summary = "Zharp Application Monitoring for Ruby: traces, errors and logs for Rails, Rack, Sinatra, Sidekiq and plain Ruby."
  spec.description = <<~TEXT
    One gem for Zharp Application Monitoring. Rails starts it by itself; Rack apps add `use Zharp::Rack`;
    scripts and workers call `Zharp.init`. Built on the official OpenTelemetry SDK: requests, database
    queries, outgoing HTTP calls and jobs are traced, each error is reported once with the code that
    ran, headers are recorded with secrets filtered, failed queries carry their statement, and each log
    line in a request ends with its trace and span id.
  TEXT
  spec.homepage = "https://zharp.io"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/zharp-io/zharp-ruby-lib",
    "changelog_uri" => "https://github.com/zharp-io/zharp-ruby-lib/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://zharp.io/docs",
    "bug_tracker_uri" => "https://github.com/zharp-io/zharp-ruby-lib/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*", "README.md", "CHANGELOG.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "opentelemetry-sdk", "~> 1.13"
  spec.add_dependency "opentelemetry-exporter-otlp", "~> 0.37"
  spec.add_dependency "opentelemetry-logs-sdk", "~> 0.8"
  spec.add_dependency "opentelemetry-exporter-otlp-logs", "~> 0.7"
  # A hand-picked set rather than opentelemetry-instrumentation-all (~60 gems, which Bundler 2.x
  # takes many minutes to resolve). Each one only switches on when its library is loaded.
  # Rails brings Action Pack (and Rack), Action View, Active Record, Active Job, Active Support,
  # Action Mailer, Active Storage and concurrent-ruby.
  {
    "rack" => "~> 0.32", "rails" => "~> 0.42", "sinatra" => "~> 0.31", "grape" => "~> 0.7",
    "net_http" => "~> 0.30", "faraday" => "~> 0.33", "http" => "~> 0.30", "httpx" => "~> 0.8",
    "pg" => "~> 0.37", "mysql2" => "~> 0.34", "trilogy" => "~> 0.69", "redis" => "~> 0.29",
    "sidekiq" => "~> 0.29", "resque" => "~> 0.9", "delayed_job" => "~> 0.26"
  }.each { |name, version| spec.add_dependency "opentelemetry-instrumentation-#{name}", version }
end
