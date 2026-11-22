# frozen_string_literal: true

# The OpenTelemetry instrumentations Zharp ships with (see zharp.gemspec). Requiring one only
# registers it; Setup installs those whose library the app has loaded.
module Zharp
  INSTRUMENTATIONS = %w[
    rack rails action_pack action_view active_record active_job active_support action_mailer
    active_storage concurrent_ruby sinatra grape net_http faraday http httpx pg mysql2 trilogy
    redis sidekiq resque delayed_job
  ].freeze
end

Zharp::INSTRUMENTATIONS.each do |name|
  require "opentelemetry-instrumentation-#{name}"
rescue LoadError
  nil
end
