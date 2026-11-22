# frozen_string_literal: true

require "test_helper"

class FakeUniqueViolation < StandardError; end

class DbErrorsTest < Minitest::Test
  include ZharpTest

  # What the pg instrumentation does: a client span with db.system, the exception recorded on it.
  def query(sql)
    tracer.in_span("INSERT shop", kind: :client, attributes: { "db.system" => "postgresql", "db.name" => "shop", "db.statement" => sql }) do
      raise FakeUniqueViolation, "duplicate key value violates unique constraint \"users_email_key\""
    end
  end

  def create_user
    query("INSERT INTO users (email) VALUES ($1)")
  end

  def test_caught_failure_is_reported_once_as_handled_with_the_query
    tracer.in_span("POST /users", kind: :server) do
      create_user
    rescue FakeUniqueViolation
      nil
    end
    assert_empty exception_events, "held, not recorded on the query span"
    assert_equal 1, errors.size
    a = errors.first.attributes
    assert_equal "true", a["zharp.handled"]
    assert_equal "db", a["zharp.mechanism"]
    assert_equal "postgresql", a["db.system"]
    assert_equal "shop", a["db.namespace"]
    assert_equal "INSERT INTO users (email) VALUES ($1)", a["db.query.text"]
    assert_match(/db_errors_test\.rb:\d+:in .*create_user/, a["exception.stacktrace"])
    assert a["zharp.source_context"]
  end

  def test_escaping_failure_carries_the_query_on_its_one_report
    assert_raises(FakeUniqueViolation) do
      tracer.in_span("POST /users", kind: :server) { create_user }
    end
    assert_equal 1, exception_events.size
    a = exception_events.first.attributes
    assert_equal "false", a["zharp.handled"]
    assert_equal "INSERT INTO users (email) VALUES ($1)", a["db.query.text"]
    assert_empty errors
  end
end

class HeldErrorsTest < Minitest::Test
  include ZharpTest

  # What Active Record's instrumentation does: User.create! in a span of its own, inside the request.
  def create_user
    tracer.in_span("User.create!") { query("INSERT INTO users (email) VALUES ($1)") }
  rescue FakeUniqueViolation => e
    raise RecordNotUniqueLike, e.message # a wrapper, as ActiveRecord::RecordNotUnique is
  end

  def query(sql)
    tracer.in_span("INSERT shop", kind: :client, attributes: { "db.system" => "postgresql", "db.statement" => sql }) do
      raise FakeUniqueViolation, "duplicate key"
    end
  end

  def test_an_exception_the_app_rescues_after_it_left_an_inner_span_is_handled_once
    tracer.in_span("POST /users/quiet", kind: :server) do
      tracer.in_span("User.create!") { raise KeyError, "inner" }
    rescue KeyError
      nil
    end
    assert_empty exception_events
    assert_equal ["true"], errors.map { |e| e.attributes["zharp.handled"] }
    assert_equal "KeyError", errors.first.attributes["exception.type"]
  end

  def test_a_wrapped_query_error_the_app_rescues_is_reported_as_the_wrapper_with_its_query
    tracer.in_span("POST /users/quiet", kind: :server) do
      tracer.in_span("User.create!") { create_user }
    rescue RecordNotUniqueLike
      nil
    end
    assert_empty exception_events
    assert_equal 1, errors.size
    a = errors.first.attributes
    assert_equal "RecordNotUniqueLike", a["exception.type"]
    assert_equal "true", a["zharp.handled"]
    assert_equal "INSERT INTO users (email) VALUES ($1)", a["db.query.text"]
  end

  def test_one_that_escapes_the_request_is_reported_once_unhandled
    assert_raises(KeyError) do
      tracer.in_span("GET /x", kind: :server) { tracer.in_span("inner") { raise KeyError, "out" } }
    end
    assert_equal ["false"], exception_events.map { |e| e.attributes["zharp.handled"] }
    assert_equal "GET /x", spans.find { |s| s.events&.any? }.name
    assert_empty errors
  end

  def test_database_calls_with_nothing_around_them_are_not_traced
    tracer.in_span("PIPELINED", kind: :client, attributes: { "db.system" => "redis" }) {}
    tracer.in_span("ActiveRecord.transaction") { tracer.in_span("EXECUTE shop", kind: :client, attributes: { "db.system" => "postgresql" }) {} }
    tracer.in_span("SolidQueue::Process query") {}
    tracer.in_span("GET /x", kind: :server) { tracer.in_span("GET", kind: :client, attributes: { "db.system" => "redis" }) {} }
    assert_equal ["GET", "GET /x"], spans.map(&:name)
  end
end

class RecordNotUniqueLike < StandardError; end
