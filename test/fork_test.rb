# frozen_string_literal: true

require "test_helper"

class ForkTest < Minitest::Test
  include ZharpTest

  def test_child_exporters_get_their_own_connection
    exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: "http://127.0.0.1:9/v1/traces")
    Zharp::Fork.register(exporter)
    parent = exporter.instance_variable_get(:@http)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      child = exporter.instance_variable_get(:@http)
      writer.write([child.equal?(parent), child.address, child.port].inspect)
      writer.close
      exit!(0)
    end
    writer.close
    result = reader.read
    Process.wait(pid)
    assert_equal "[false, \"127.0.0.1\", 9]", result
    assert exporter.instance_variable_get(:@http).equal?(parent), "the parent keeps its own"
  ensure
    Zharp::Fork.exporters.delete(exporter)
  end
end
