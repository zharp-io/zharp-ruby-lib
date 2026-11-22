# Changelog

## 0.1.0 (unreleased)

The first release: one `zharp` gem for Rails, Rack apps, Sidekiq and plain Ruby, built on the
official OpenTelemetry SDK (`opentelemetry-sdk` 1.13, `opentelemetry-instrumentation-all` 0.102).
Ruby 3.3+, Rails 7.1+.

- Rails starts it by itself (a Railtie); `bin/rails generate zharp:install` writes
  `config/initializers/zharp.rb` and can store the key in the credentials.
- Rack apps: `use Zharp::Rack`. Plain Ruby: `Zharp.init`. Sidekiq outside Rails: `-r zharp/sidekiq`.
- Settings from `ZHARP_KEY`, `ZHARP_SERVICE`, `ZHARP_ENVIRONMENT`, `ZHARP_RELEASE`,
  `ZHARP_ENDPOINT`, `ZHARP_SAMPLE_RATE`, `ZHARP_LOGS`, `ZHARP_LOG_CORRELATION`,
  `ZHARP_CAPTURE_HEADERS`, `ZHARP_CAPTURE_QUERY_ERRORS`, `ZHARP_CAPTURE_SOURCE_CONTEXT`,
  `ZHARP_TRACING`, `ZHARP_DISABLED`; in Rails also `credentials.zharp.key`.
- Errors counted once (Action Pack, `Rails.error`, Rack, Sidekiq, Active Job, `at_exit`), with the
  code around the app's frames as `zharp.source_context`.
- All request and response headers on the server span, secrets as `[REDACTED]`.
- Failed queries (pg, mysql2, trilogy, Active Record) reported once with system, database,
  obfuscated statement and error code; Postgres's `DETAIL:` line dropped.
- Sidekiq and Active Job jobs in the trace of the request that queued them.
- ` trace_id=… span_id=…` at the end of each `Logger` and semantic_logger line in a request;
  `ZHARP_LOGS=true` sends the lines from the SDK.
- Fork safety for Puma cluster mode and Unicorn: each worker's exporters get their own connection.
- `Zharp.capture_error`, `set_user`, `clear_user`, `set_tag`, `log`, `start_span`, `flush`,
  `shutdown`.
