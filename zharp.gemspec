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
  spec.add_dependency "opentelemetry-instrumentation-all", "~> 0.102"
end
