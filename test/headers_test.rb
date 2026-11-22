# frozen_string_literal: true

require "test_helper"

class HeadersTest < Minitest::Test
  def test_secrets_are_redacted
    secret = Zharp::Headers.settings(nil, nil)
    attrs = Zharp::Headers.attributes("request", {
      "authorization" => "Bearer x", "cookie" => "a=b", "x-api-key" => "k", "x-csrf-token" => "t",
      "user-agent" => "curl/8", "accept" => "*/*"
    }, secret)
    %w[authorization cookie x-api-key x-csrf-token].each { |h| assert_equal "[REDACTED]", attrs["http.request.header.#{h}"] }
    assert_equal "curl/8", attrs["http.request.header.user-agent"]
  end

  def test_extra_names_and_off
    secret = Zharp::Headers.settings({ redact: ["x-tenant"] }, nil)
    assert_equal "[REDACTED]", Zharp::Headers.attributes("response", { "X-Tenant" => "acme" }, secret)["http.response.header.x-tenant"]
    assert_nil Zharp::Headers.settings(false, nil)
    assert_nil Zharp::Headers.settings(nil, "off")
  end

  def test_from_rack_env
    h = Zharp::Headers.from_env("HTTP_X_REQUEST_ID" => "r1", "CONTENT_TYPE" => "application/json", "PATH_INFO" => "/")
    assert_equal({ "x-request-id" => "r1", "content-type" => "application/json" }, h)
  end
end
