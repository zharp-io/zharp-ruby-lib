# frozen_string_literal: true

require "test_helper"
require "json"
require "socket"
require "net/http"
require "zlib"

class CaptureTest < Minitest::Test
  include ZharpTest

  def with_bodies(option)
    old = Zharp.options.capture_bodies
    Zharp.options.capture_bodies = Zharp::Bodies.settings(option, nil)
    yield
  ensure
    Zharp.options.capture_bodies = old
  end

  def server = spans.find { |s| s.kind == :server }

  def rack(app)
    Rack::MockRequest.new(Rack::Builder.new do
      use Zharp::Rack
      run app
    end.to_app)
  end

  ECHO = lambda do |env|
    input = env["rack.input"]&.read.to_s
    status = env["PATH_INFO"] == "/fail" ? 422 : 200
    [status, { "content-type" => "application/json" }, [%({"got":#{input.empty? ? 'null' : input},"token":"t-1"})]]
  end

  def test_errors_mode_keeps_failed_requests_only_with_secrets_filtered
    with_bodies("errors") do
      rack(ECHO).post("/ok", input: '{"email":"a@b.c","password":"p"}', "CONTENT_TYPE" => "application/json")
      refute server.attributes.key?("http.request.body")
      SPANS.reset
      rack(ECHO).post("/fail", input: '{"email":"a@b.c","password":"p"}', "CONTENT_TYPE" => "application/json")
      a = server.attributes
      assert_equal '{"email":"a@b.c","password":"[Filtered]"}', a["http.request.body"]
      assert_equal '{"got":{"email":"a@b.c","password":"[Filtered]"},"token":"[Filtered]"}', a["http.response.body"]
      assert_equal "application/json", a["http.response.header.content-type"]
    end
  end

  def test_streamed_body_tapped_as_the_server_writes_it_and_gzip_inflated
    gz = Zlib.gzip(%({"name":"Ada","secret":"s"}))
    app = lambda do |_env|
      body = Object.new
      body.define_singleton_method(:each) { |&b| b.call(gz[0, 10]); b.call(gz[10..]) }
      [200, { "content-type" => "application/json", "content-encoding" => "gzip" }, body]
    end
    with_bodies("all") do
      response = rack(app).get("/x")
      assert_equal gz.b, response.body.b, "the app's bytes are untouched"
      assert_equal '{"name":"Ada","secret":"[Filtered]"}', server.attributes["http.response.body"]
    end
  end

  def test_binary_and_unread_request_bodies
    app = ->(_env) { [500, { "content-type" => "image/png", "content-length" => "3000" }, ["x" * 3000]] }
    with_bodies("all") do
      rack(app).post("/upload", input: "a=1&password=2", "CONTENT_TYPE" => "application/x-www-form-urlencoded")
      a = server.attributes
      assert_equal "a=1&password=[Filtered]", a["http.request.body"], "drained after the app left it unread"
      assert_equal "[binary · image/png · 3 KB]", a["http.response.body"]
    end
  end

  def test_multipart_fields_and_files_described
    boundary = "XyZ"
    body = [
      "--#{boundary}", %(Content-Disposition: form-data; name="title"), "", "Holiday",
      "--#{boundary}", %(Content-Disposition: form-data; name="token"), "", "abc",
      "--#{boundary}", %(Content-Disposition: form-data; name="photo"; filename="a.png"), "Content-Type: image/png", "", "PNGDATA" * 300,
      "--#{boundary}--", ""
    ].join("\r\n")
    app = lambda do |env|
      Rack::Request.new(env).POST
      [500, { "content-type" => "text/plain" }, ["no"]]
    end
    with_bodies("all") do
      rack(app).post("/upload", input: body, "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}")
      assert_equal({ "title" => "Holiday", "token" => "[Filtered]", "photo" => "[file a.png · image/png · 2 KB]" },
                   JSON.parse(server.attributes["http.request.body"]))
    end
  end

  def test_outgoing_net_http_bodies_on_the_client_span
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.addr[1]
    thread = Thread.new do
      client = listener.accept
      length = 0
      while (line = client.gets) && line != "\r\n"
        length = line.split(":", 2)[1].to_i if line.downcase.start_with?("content-length")
      end
      client.read(length)
      reply = '{"error":"bad","access_token":"zzz"}'
      client.write("HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: #{reply.bytesize}\r\nConnection: close\r\n\r\n#{reply}")
      client.close
    end
    with_bodies("errors") do
      tracer.in_span("job") do
        http = Net::HTTP.new("127.0.0.1", port)
        http.post("/charge?api_key=k1&page=2", '{"amount":5,"card":"4242"}', "Content-Type" => "application/json")
      end
    end
    thread.join(5)
    client = spans.find { |s| s.kind == :client }
    a = client.attributes
    assert_equal '{"amount":5,"card":"[Filtered]"}', a["http.request.body"]
    assert_equal '{"error":"bad","access_token":"[Filtered]"}', a["http.response.body"]
    assert_equal "api_key=[Filtered]&page=2", a["url.query"], "secret query values masked on every span"
  ensure
    listener&.close
  end

  def test_urls_masked_on_server_spans_without_bodies
    with_bodies(false) do
      rack(ECHO).get("/x?token=abc&page=1")
      assert_equal "token=[Filtered]&page=1", server.attributes["url.query"]
      refute server.attributes.key?("http.response.body")
    end
  end
end
