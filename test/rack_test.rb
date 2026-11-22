# frozen_string_literal: true

require "test_helper"
require "rack/test"

class RackTest < Minitest::Test
  include ZharpTest
  include Rack::Test::Methods

  APP = lambda do |env|
    raise ArgumentError, "bad order" if env["PATH_INFO"].end_with?("/fail")

    [200, { "content-type" => "text/plain", "set-cookie" => "s=1" }, ["ok"]]
  end

  def app
    @app ||= Rack::Builder.new do
      use Zharp::Rack
      run APP
    end.to_app
  end

  def server = spans.find { |s| s.kind == :server }

  def test_one_server_span_named_by_route_with_headers
    header "Authorization", "Bearer secret"
    header "X-Request-Id", "r-1"
    get "/orders/12345"
    assert_equal 200, last_response.status
    assert_equal 1, spans.count { |s| s.kind == :server }
    assert_equal "GET /orders/:id", server.name
    a = server.attributes
    assert_equal "[REDACTED]", a["http.request.header.authorization"]
    assert_equal "r-1", a["http.request.header.x-request-id"]
    assert_equal "[REDACTED]", a["http.response.header.set-cookie"]
    assert_equal "text/plain", a["http.response.header.content-type"]
  end

  def test_continues_the_callers_trace
    header "traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
    get "/"
    assert_equal "0af7651916cd43dd8448eb211c80319c", server.hex_trace_id
    assert_equal "b7ad6b7169203331", server.hex_parent_span_id
  end

  def test_an_escaping_error_is_reported_once
    assert_raises(ArgumentError) { get "/orders/1/fail" }
    assert_equal 1, exception_events.size
    assert_equal "false", exception_events.first.attributes["zharp.handled"]
    assert_equal OpenTelemetry::Trace::Status::ERROR, server.status.code
    assert_equal 500, server.attributes["http.response.status_code"]
  end

  def test_nested_rack_middleware_makes_no_second_span
    inner = OpenTelemetry::Instrumentation::Rack::Instrumentation.instance.middleware_args
    nested = Rack::Builder.new do
      use Zharp::Rack
      use(*inner)
      run APP
    end.to_app
    Rack::MockRequest.new(nested).get("/x")
    assert_equal 1, spans.count { |s| s.kind == :server }
  end
end

class RackRenderedErrorTest < Minitest::Test
  include ZharpTest

  # What Hanami does in production: it catches the exception, renders a 500, keeps it in rack.exception.
  RENDERS = lambda do |env|
    env["PATH_INFO"] = "/rewritten"
    begin
      nil.price
    rescue NoMethodError => e
      env["rack.exception"] = e
      [500, { "content-type" => "text/plain" }, ["error"]]
    end
  end

  def test_an_error_page_the_framework_rendered_reports_its_exception_once
    app = Rack::Builder.new do
      use Zharp::Rack
      run RENDERS
    end.to_app
    Rack::MockRequest.new(app).get("/carts/7/total")
    server = spans.find { |s| s.kind == :server }
    assert_equal "GET /carts/:id/total", server.name
    assert_equal ["NoMethodError"], exception_events.map { |e| e.attributes["exception.type"] }
    assert_equal "false", exception_events.first.attributes["zharp.handled"]
  end
end
