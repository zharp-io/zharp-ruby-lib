# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "logger"
require "rack"
require "zharp"

ENV.delete("ZHARP_LOGS")
ENV.delete("ZHARP_KEY")

module ZharpTest
  SPANS = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
  LOGS = OpenTelemetry::SDK::Logs::Export::InMemoryLogRecordExporter.new

  # One Zharp for the whole run (as in an app): in-memory exporters, no batching.
  def self.start
    return if Zharp.active?

    Zharp.init(key: "zpk_test", service: "unit", environment: "test", quiet: true,
               _exporters: [SPANS, LOGS], _batch: false)
  end

  def setup
    ZharpTest.start
    SPANS.reset
    LOGS.reset
  end

  def spans = SPANS.finished_spans
  def logs = LOGS.emitted_log_records
  def errors = logs.select { |l| l.attributes&.key?("exception.type") }
  def exception_events = spans.flat_map { |s| (s.events || []).select { |e| e.name == "exception" } }
  def tracer = OpenTelemetry.tracer_provider.tracer("test")
end
