# frozen_string_literal: true

require "test_helper"
require "json"

class Cart
  def initialize(items) = @items = items

  def total
    @items.sum { |i| i.price }
  end
end

class ErrorsTest < Minitest::Test
  include ZharpTest

  def failure
    Cart.new([nil]).total
  rescue NoMethodError => e
    e
  end

  def test_capture_error_sends_type_message_stack_and_code
    Zharp.capture_error(failure, order_id: 7)
    assert_equal 1, errors.size
    a = errors.first.attributes
    assert_equal "NoMethodError", a["exception.type"]
    assert_match(/undefined method .price. for nil/, a["exception.message"])
    assert_match(/errors_test\.rb:\d+:in .*total/, a["exception.stacktrace"])
    assert_equal "true", a["zharp.handled"]
    assert_equal 7, a["order_id"]
    code = JSON.parse(a["zharp.source_context"])
    assert_equal "    @items.sum { |i| i.price }", code.first["code"]
    assert(code.all? { |f| f["file"].end_with?("errors_test.rb") }, "only the app's frames")
    assert_equal 5, code.first["pre"].size
  end

  def test_one_report_per_exception
    error = failure
    tracer.in_span("request", kind: :server) do |span|
      span.record_exception(error)
      span.record_exception(error)
      Zharp.capture_error(error)
    end
    assert_equal 1, exception_events.size
    assert_equal "false", exception_events.first.attributes["zharp.handled"]
    assert_empty errors
  end

  def test_in_span_escape_is_unhandled
    assert_raises(NoMethodError) { tracer.in_span("job") { Cart.new([nil]).total } }
    assert_equal ["false"], exception_events.map { |e| e.attributes["zharp.handled"] }
    assert exception_events.first.attributes["zharp.source_context"]
  end

  def test_postgres_detail_line_is_dropped
    error = Class.new(StandardError) { def self.name = "PG::UniqueViolation" }
               .new("ERROR:  duplicate key value violates unique constraint \"users_email_key\"\nDETAIL:  Key (email)=(a@b.c) already exists.\n")
    Zharp.capture_error(error)
    a = errors.first.attributes
    refute_includes a["exception.message"], "a@b.c"
    refute_includes a["exception.stacktrace"], "a@b.c"
    assert_includes a["exception.message"], "users_email_key"
  end

  def test_user_and_tags_on_errors_and_spans
    Zharp.set_tag("region", "eu")
    tracer.in_span("request", kind: :server) do
      Zharp.set_user(id: 42, email: "a@b.c")
      tracer.in_span("child") { Zharp.capture_error(RuntimeError.new("x")) }
    end
    assert_equal "42", errors.first.attributes["enduser.id"]
    assert_equal "eu", errors.first.attributes["region"]
    child = spans.find { |s| s.name == "child" }
    assert_equal "42", child.attributes["enduser.id"]
  ensure
    Zharp.set_tag("region", nil)
  end

  def test_user_and_session_from_baggage
    ctx = OpenTelemetry::Baggage.build(context: OpenTelemetry::Context.empty) do |b|
      b.set_value("enduser.id", "u-1")
      b.set_value("session.id", "s-1")
    end
    OpenTelemetry::Context.with_current(ctx) { tracer.in_span("request") {} }
    assert_equal "u-1", spans.first.attributes["enduser.id"]
    assert_equal "s-1", spans.first.attributes["session.id"]
  end
end

class WrappedErrorsTest < Minitest::Test
  include ZharpTest

  class TemplateError < StandardError; end

  def wrapped
    begin
      nil.total
    rescue NoMethodError
      raise TemplateError, "undefined method 'total' for nil"
    end
  rescue TemplateError => e
    e
  end

  # Action View raises ActionView::Template::Error around the template's NoMethodError; Action Pack
  # reports one and the Rack layer the other: one failure, one report, either way round.
  def test_a_wrapper_and_its_cause_are_reported_once
    [[:itself, :cause], [:cause, :itself]].each do |order|
      SPANS.reset
      error = wrapped
      tracer.in_span("GET /pages/:id", kind: :server) do |span|
        order.each { |which| span.record_exception(which == :itself ? error : error.cause) }
      end
      assert_equal 1, exception_events.size, order.inspect
    end
  end

  def test_an_error_reported_as_handled_does_not_hide_the_one_raised_from_it
    error = wrapped
    Zharp.capture_error(error.cause)
    tracer.in_span("GET /x", kind: :server) { |span| span.record_exception(error) }
    assert_equal 1, errors.size
    assert_equal 1, exception_events.size
  end
end
