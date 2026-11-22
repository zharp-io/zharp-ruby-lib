# frozen_string_literal: true

require "test_helper"
require "json"

# The shared body and URL rules. Expected values are the ones the JavaScript SDK's
# @zharp/internal/bodies (and zharp-python's tests) produce from the same input.
class BodiesTest < Minitest::Test
  B = Zharp::Bodies
  SETTINGS = B.settings({ mode: "all", max_size: 200, redact_keys: ["dateOfBirth"] }, nil)
  IMAGE = "data:image/png;base64,#{'iVBORw0KGgo' * 40}"

  def fmt(text, type = "application/json", cut: false, settings: SETTINGS)
    value, truncated = B.format_body(text, type, settings, cut)
    value.nil? ? nil : { value: value, truncated: truncated }
  end

  def test_settings
    [nil, false, "", "off", "false"].each { |v| assert_nil B.settings(v, nil), v.inspect }
    assert_equal "errors", B.settings(true, nil).mode
    assert_equal "all", B.settings("all", nil).mode
    assert_equal 32 * 1024, B.settings("errors", nil).max_size
    assert_equal 128 * 1024, B.settings({ mode: "all", max_size: 10**9 }, nil).max_size
    assert_equal 4096, B.settings({ max_size: 4096, nonsense: 1 }, nil).max_size
    assert_equal 32 * 1024, B.settings({ max_size: -1 }, nil).max_size
    assert_equal "all", B.settings(nil, "all").mode
    assert_equal "errors", B.settings(nil, "true").mode
    assert_nil B.settings(nil, "off")
    assert_equal "all", B.settings("all", "off").mode, "an explicit option wins"
  end

  def test_off_by_default
    ENV.delete("ZHARP_CAPTURE_BODIES")
    assert_nil Zharp::Config.resolve(key: "zpk_x").capture_bodies
  end

  def test_wanted
    errors = B.settings("errors", nil)
    refute B.wanted?(errors, 200)
    assert B.wanted?(errors, 404)
    assert B.wanted?(errors, nil), "no response"
    assert B.wanted?(B.settings("all", nil), 200)
  end

  def test_secret_keys
    %w[password Password user_password apiKey X-Api-Key accessToken cvv pwd card Authorization session_id].each { |k| assert B.secret_key?(k), k }
    %w[email name author pwdx cards key session sessions].each { |k| refute B.secret_key?(k), k }
    assert B.secret_key?("date_of_birth", ["dateOfBirth"])
    assert B.secret_key?("internalRef", [/Ref$/])
  end

  def test_json_keeps_names_and_filters_secret_values
    out = JSON.parse(fmt('{"email":"a@b.test","password":"hunter2","dateOfBirth":"1990","list":[{"apiKey":"k","ok":true,"x":null}],"empty":""}')[:value])
    assert_equal({ "email" => "a@b.test", "password" => "[Filtered]", "dateOfBirth" => "[Filtered]",
                   "list" => [{ "apiKey" => "[Filtered]", "ok" => true, "x" => nil }], "empty" => "" }, out)
  end

  def test_secret_object_keeps_its_keys
    out = JSON.parse(fmt('{"card":{"brand":"visa","last4":"4242","meta":{"x":1},"none":null}}')[:value])
    assert_equal({ "brand" => "[Filtered]", "last4" => "[Filtered]", "meta" => { "x" => "[Filtered]" }, "none" => nil }, out["card"])
  end

  def test_numbers_and_text_as_javascript_writes_them
    assert_equal '{"n":1,"m":1.5,"tiny":0.00001,"big":1e+21,"neg":0,"s":"héllo 😀   \u0001"}',
                 fmt('{"n":1.0,"m":1.5,"tiny":0.00001,"big":1e21,"neg":-0.0,"s":"héllo 😀 \u2028 \u0001"}')[:value]
  end

  def test_inline_images_and_base64
    out = JSON.parse(fmt(JSON.generate({ img: IMAGE, b: "#{'QUJD' * 100}1", name: "Ada" }), settings: B.settings("all", nil))[:value])
    assert_equal({ "img" => "[image/png · 330 B]", "b" => "[base64 · 300 B]", "name" => "Ada" }, out)
  end

  def test_cut_json_is_redacted_loosely
    assert_equal({ value: %({"token":"[Filtered]","avatar":"[image/png · 330 B+]"), truncated: true },
                 fmt(%({"token":"abc","avatar":"#{IMAGE}), cut: true))
  end

  def test_forms
    assert_equal "user=ada&password=[Filtered]&code=123", fmt("user=ada&password=p4ss&code=123", "application/x-www-form-urlencoded")[:value]
  end

  def test_cap_and_truncated_flag
    out = fmt(%("#{'x' * 300}"), "text/plain")
    assert_equal 200, out[:value].length
    assert out[:truncated]
  end

  def test_empty_and_not_text
    assert_nil fmt("   ")
    assert_equal({}, B.body_attributes("response", "x", "image/png", SETTINGS))
    assert B.textual?(nil) && B.textual?("application/problem+json") && !B.textual?("text/event-stream")
  end

  def test_labels
    assert_equal ["0 B", "1023 B", "1 KB", "1 KB", "2 KB", "1.3 MB", "2.3 MB", "4.8 MB"],
                 [0, 1023, 1024, 1535, 1536, 1_310_720, 2_359_296, 5_000_000].map { |n| B.format_size(n) }
    assert_equal "[binary · image/png · 3 KB]", B.describe_body("image/png", 3000)
    assert_equal "[event stream]", B.describe_body("text/event-stream; charset=utf-8")
    assert_equal "[file a.png · image/png · 2 KB+]", B.file_label("a.png", "image/png", 2048, true)
    assert_equal "[file blob]", B.file_label(nil, nil, nil)
    assert_equal "[stream · application/json · 60 B]", B.unread_attributes("response", "application/json", 60)["http.response.body"]
  end

  def test_urls
    assert_equal "https://h.test/a?token=[Filtered]&page=2&key=&session=[Filtered]&sessions=3#frag?x=1",
                 B.redact_url("https://u:p@h.test/a?token=t&page=2&key=&session=s&sessions=3#frag?x=1")
    assert_equal "/p?sig=[Filtered]&q=1", B.redact_url("/p?sig=abc&q=1")
    assert_equal "pwd=[Filtered]&api_key=[Filtered]&state=[Filtered]", B.redact_query("pwd=x&api_key=y&state=z")
  end

  def test_url_matching
    assert B.url_matches?("https://api.example.com/x", ["api.example.com"])
    assert B.url_matches?("http://api.example.com:80/x", ["api.example.com"])
    assert B.url_matches?("http://localhost:3000/x", ["localhost:3000"])
    assert B.url_matches?("https://example.com/v2/a", ["https://example.com/v2"])
    assert B.url_matches?("https://x.test/api/a", [%r{/api/}])
    refute B.url_matches?("https://other.test/", ["api.example.com"])
  end
end
