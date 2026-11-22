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
