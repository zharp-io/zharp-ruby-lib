# frozen_string_literal: true

require "test_helper"


class ScrubTest < Minitest::Test
  include ZharpTest

  # Driver errors by name only: defining the real modules would make OpenTelemetry think the drivers are loaded.
  def driver_error(name, message) = Class.new(StandardError) { define_singleton_method(:name) { name } }.new(message)

  # The messages as the drivers word them (the MySQL one captured in the Rails 7.1 e2e run).
  CASES = {
    "Duplicate entry 'dup-1795357650990@example.com' for key 'users.index_users_on_email'" =>
      "Duplicate entry '?' for key 'users.index_users_on_email'",
    "1062: Duplicate entry 'ann@example.com' for key 'users.email'" => "1062: Duplicate entry '?' for key 'users.email'",
    "Incorrect integer value: 'forty' for column 'age' at row 1" => "Incorrect integer value: '?' for column 'age' at row 1",
    "Incorrect datetime value: '2026-13-45'" => "Incorrect datetime value: '?'",
    "Truncated incorrect DOUBLE value: '12abc'" => "Truncated incorrect DOUBLE value: '?'",
    "Data too long for column 'name' at row 1" => "Data too long for column 'name' at row 1",
    "ERROR:  invalid input syntax for type integer: \"forty\"" => "ERROR:  invalid input syntax for type integer: \"?\"",
    "ERROR:  invalid input value for enum mood: \"angry\"" => "ERROR:  invalid input value for enum mood: \"?\"",
    "ERROR:  value \"99999999999\" is out of range for type integer" => "ERROR:  value \"?\" is out of range for type integer",
    "ERROR:  null value in column \"email\" of relation \"users\" violates not-null constraint\nDETAIL:  Failing row contains (1, null, ann).\n" =>
      "ERROR:  null value in column \"email\" of relation \"users\" violates not-null constraint\n"
  }.freeze

  def test_values_are_replaced
    CASES.each { |message, expected| assert_equal expected, Zharp::Errors.scrub(message), message }
  end

  def test_reported_mysql_and_trilogy_errors_carry_no_values
    Zharp.capture_error(driver_error("Mysql2::Error", "Duplicate entry 'ann@example.com' for key 'users.email'"))
    Zharp.capture_error(driver_error("Trilogy::ProtocolError", "1366: Incorrect integer value: 'forty' for column 'age' at row 1"))
    Zharp.capture_error(driver_error("PG::InvalidTextRepresentation", "ERROR:  invalid input syntax for type integer: \"forty\""))
    errors.each do |e|
      refute_match(/ann@example|forty/, e.attributes["exception.message"])
      refute_match(/ann@example|forty/, e.attributes["exception.stacktrace"])
      refute_match(/ann@example|forty/, e.body.to_s)
    end
    assert_equal 3, errors.size
  end

  def test_other_errors_keep_their_messages
    Zharp.capture_error(ArgumentError.new("Duplicate entry 'x' for key 'y'"))
    assert_includes errors.first.attributes["exception.message"], "'x'"
  end
end
