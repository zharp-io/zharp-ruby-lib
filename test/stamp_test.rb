# frozen_string_literal: true

require "test_helper"
require "json"

class StampTest < Minitest::Test
  include ZharpTest

  IDS = ["0af7651916cd43dd8448eb211c80319c", "b7ad6b7169203331"].freeze

  def test_text_line
    assert_equal "Started GET / trace_id=#{IDS[0]} span_id=#{IDS[1]}\n", Zharp::Stamp.stamp_line("Started GET /\n", IDS)
  end

  def test_json_line_stays_json
    out = Zharp::Stamp.stamp_line(%({"method":"GET","status":200}\n), IDS)
    assert_equal({ "method" => "GET", "status" => 200, "trace_id" => IDS[0], "span_id" => IDS[1] }, JSON.parse(out))
    assert out.end_with?("\n")
  end

  def test_left_alone
    ["\n", "x trace_id=1\n", "[Zharp] hi\n"].each { |l| assert_equal l, Zharp::Stamp.stamp_line(l, IDS) }
  end

  def test_multi_line_record_stamped_once_at_the_end
    out = Zharp::Stamp.stamp_record("boom\n  from a.rb:1\n", IDS)
    assert_equal "boom\n  from a.rb:1 trace_id=#{IDS[0]} span_id=#{IDS[1]}\n", out
  end

  def test_logger_lines_in_a_span_are_stamped
    io = StringIO.new
    logger = Logger.new(io)
    logger.formatter = ->(sev, _t, _p, msg) { "#{sev} #{msg}\n" }
    logger.info("outside")
    tracer.in_span("request") do |span|
      logger.info("inside")
      assert_includes io.string, "INFO inside trace_id=#{span.context.hex_trace_id} span_id=#{span.context.hex_span_id}\n"
    end
    assert_includes io.string, "INFO outside\n"
  end

  def test_logs_are_not_sent_by_default
    Logger.new(StringIO.new).info("not sent")
    assert_empty logs
  end

  def test_logs_sent_when_on
    Zharp::Logs.sending = true
    Logger.new(StringIO.new).warn("sent once")
    assert_equal ["sent once"], logs.map(&:body)
    assert_equal "WARN", logs.first.severity_text
  ensure
    Zharp::Logs.sending = false
  end

  def test_an_exception_logged_is_an_error
    error = RuntimeError.new("logged")
    Logger.new(StringIO.new).error(error)
    Logger.new(StringIO.new).error(error)
    assert_equal 1, errors.size
    assert_equal "true", errors.first.attributes["zharp.handled"]
  end
end
