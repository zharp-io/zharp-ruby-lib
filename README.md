# Zharp for Ruby

Application Monitoring for Ruby apps: traces, errors and logs, sent to [Zharp](https://zharp.io).
One gem for Rails, any Rack app (Sinatra, Hanami, Roda, Grape), Sidekiq and plain Ruby, built on
the official OpenTelemetry SDK.

- Requests named by route, continuing the caller's `traceparent`; database queries (pg, mysql2,
  trilogy, Active Record), outgoing HTTP (Net::HTTP, Faraday, HTTP.rb, Excon…), Redis, GraphQL,
  AWS SDK and the rest of `opentelemetry-instrumentation-all`, each switched on when its library is
  loaded.
- **Errors, each counted once**, with type, message, the stack and the code that ran (the lines
  around your app's innermost five frames, read on your server; never gems or Ruby's library).
- **Request and response headers** on the request's span, secrets (authorization, cookies, API
  keys, tokens, sessions) as `[REDACTED]`.
- **Failed queries** reported once, with the statement (obfuscated), the database and the error
  code; Postgres's `DETAIL:` line (the row's values) is dropped.
- **Jobs in the request's trace**: Sidekiq and Active Job (Solid Queue, GoodJob, Delayed Job…) run
  as children of the request that queued them.
- **Logs**: each line written through `Logger` (so `Rails.logger` and lograge) or semantic_logger
  during a request ends with ` trace_id=… span_id=…` (two fields on a JSON line), so the Zharp
  agent links it to its request. `ZHARP_LOGS=true` sends the lines from the SDK instead, where
  there is no agent.
- **Forking servers**: Puma in cluster mode (`preload_app!`) and Unicorn need nothing.

Ruby 3.3+ (3.3, 3.4, 4.0), Rails 7.1+.

## Rails

```sh
bundle add zharp
```

Set your key, from **Settings → Applications** in Zharp:

```sh
ZHARP_KEY=zpk_… bin/rails server
```

or keep it in the credentials (`bin/rails credentials:edit`):

```yaml
zharp:
  key: zpk_…
```

That's all: the gem's Railtie starts Zharp when Rails boots, in the web server, `bin/rails runner`,
Sidekiq and Solid Queue alike. To change a default, generate the initializer, which lists every
option commented out (with `--key` it also stores the key in the credentials):

```sh
bin/rails generate zharp:install --key=zpk_…
```

Puma in cluster mode with `preload_app!` prints "Detected 2 Thread(s) started in app boot": those
are OpenTelemetry's export threads in the master process. Each worker starts its own after the fork
and sends over a connection of its own; nothing needs changing.

## Rack apps: Sinatra, Hanami, Roda, Grape, plain Rack

```sh
bundle add zharp
```

In `config.ru`:

```ruby
require "zharp"
use Zharp::Rack

run App
```

and `ZHARP_KEY` in the environment. Sinatra and Grape spans are named by their routes; others by
the path with ids replaced (`GET /orders/:id`). Call `Zharp.init(service: "shop")` before `use`
to set options in code.

## Plain Ruby: scripts, workers, CLIs

```ruby
require "zharp"
Zharp.init(service: "billing-worker")
```

Call it after your gems are required, so their instrumentation is switched on. An exception that
ends the script is reported and sent before it exits.

### Sidekiq outside Rails

At the top of the file Sidekiq loads (`bundle exec sidekiq -r ./worker.rb`), with `ZHARP_KEY` in
the environment:

```ruby
require "zharp/sidekiq"
```

Sidekiq keeps only one `-r`, so this goes in that file rather than on the command line. Jobs queued
from a traced request or span run in its trace. (In a Rails app Sidekiq needs nothing.)

## Settings

Every setting can be passed to `Zharp.init` or set in the environment.

| `Zharp.init` | Environment | Default |
|---|---|---|
| `key:` | `ZHARP_KEY` (Rails: then `credentials.zharp.key`) | — nothing is sent without one |
| `service:` | `ZHARP_SERVICE`, `OTEL_SERVICE_NAME` | the Rails app's name, else the project folder |
| `environment:` | `ZHARP_ENVIRONMENT` | `Rails.env` |
| `release:` | `ZHARP_RELEASE` | — |
| `endpoint:` | `ZHARP_ENDPOINT` | `https://api.zharp.io/api/v1/otlp` |
| `sample_rate:` | `ZHARP_SAMPLE_RATE` | `1.0` (errors are always sent) |
| `logs:` | `ZHARP_LOGS` | `false` |
| `log_correlation:` | `ZHARP_LOG_CORRELATION` | `true` |
| `capture_headers:` | `ZHARP_CAPTURE_HEADERS` | on; `{ redact: ["x-tenant"] }` filters more names |
| `capture_query_errors:` | `ZHARP_CAPTURE_QUERY_ERRORS` | `true` |
| `capture_source_context:` | `ZHARP_CAPTURE_SOURCE_CONTEXT` | `true` |
| `tracing:` | `ZHARP_TRACING` | `true`; `false` sends errors and logs only |
| `instrumentation:` | — | options per OpenTelemetry instrumentation, by class name |
| — | `ZHARP_DISABLED=true` | turns everything off |

## API

```ruby
Zharp.capture_error(error, order_id: 42)      # an exception you rescued, as a handled error
Zharp.set_user(id: user.id, email: user.email) # on the request's spans, logs and errors
Zharp.set_tag("tenant", "acme")                # on every span and log from now on
Zharp.log.info("order paid", order_id: 42)     # a log line sent from the SDK, whatever ZHARP_LOGS says
Zharp.start_span("render invoice") { render }  # a span around some work
Zharp.flush                                    # send what's queued now (end of a script or job)
```

Rails' own `Rails.error.report` and `Rails.error.handle` reach Zharp too.

A browser or mobile app using a Zharp SDK sends its user and session with each request (W3C
`baggage`); they are put on the request's spans, logs and errors without any code.

## Development

No Ruby needed on the host: everything runs in Docker.

```sh
docker run --rm -v "$PWD:/src" -w /src ruby:3.4 sh -c "gem install bundler && bundle install && bundle exec rake"
e2e/unit.sh                 # unit tests: Ruby 3.3 / 3.4 / 4.0 × no Rails, Rails 7.1 / 7.2 / 8.1
e2e/generator.sh 3.4 8.1.0  # rails new, bundle add zharp, the generator, boot
# End-to-end against a Zharp backend: a throwaway app per case, its docker compose stack, what
# Zharp stored saved in e2e/out/<case>.json. Cases: rails81 rails71 sinatra rack hanami script semantic.
ZHARP_API=http://localhost:3000/api/v1 ZHARP_TOKEN=<user JWT> ZHARP_WORKSPACE=<id> node e2e/run.mjs rails81
```

Use Bundler 4: with Bundler 2.6 (what Ruby 3.4's image ships) or 2.7, resolving
`opentelemetry-instrumentation-all` can take many minutes.

## License

MIT
