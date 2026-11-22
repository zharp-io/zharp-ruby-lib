# frozen_string_literal: true

require "test_helper"

class ConfigTest < Minitest::Test
  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def test_no_key_no_options
    with_env("ZHARP_KEY" => nil, "ZHARP_API_KEY" => nil) { assert_nil Zharp::Config.resolve({}) }
  end

  def test_defaults_match_the_other_sdks
    with_env("ZHARP_KEY" => "zpk_1", "ZHARP_LOGS" => nil, "ZHARP_ENDPOINT" => nil, "ZHARP_SERVICE" => "shop") do
      o = Zharp::Config.resolve({})
      assert_equal "zpk_1", o.key
      assert_equal "shop", o.service
      assert_equal "https://api.zharp.io/api/v1/otlp", o.endpoint
      assert_equal false, o.logs
      assert_equal true, o.log_correlation
      assert_equal true, o.tracing
      assert_equal true, o.capture_query_errors
      assert_equal true, o.capture_source_context
      assert_kind_of Regexp, o.capture_headers
      assert_equal 1.0, o.sample_rate
    end
  end

  def test_environment_switches
    with_env("ZHARP_KEY" => "zpk_1", "ZHARP_LOGS" => "true", "ZHARP_CAPTURE_HEADERS" => "false",
             "ZHARP_SAMPLE_RATE" => "0.25", "ZHARP_ENDPOINT" => "http://localhost:3000/api/v1/otlp/") do
      o = Zharp::Config.resolve({})
      assert o.logs
      assert_nil o.capture_headers
      assert_equal 0.25, o.sample_rate
      assert_equal "http://localhost:3000/api/v1/otlp", o.endpoint
    end
  end

  def test_arguments_win
    with_env("ZHARP_KEY" => "zpk_env", "ZHARP_LOGS" => "true") do
      o = Zharp::Config.resolve(key: "zpk_arg", logs: false, service: "billing-worker")
      assert_equal "zpk_arg", o.key
      refute o.logs
      assert_equal "billing-worker", o.service
    end
  end

  def test_disabled
    with_env("ZHARP_DISABLED" => "true") { assert Zharp::Config.disabled? }
  end
end
