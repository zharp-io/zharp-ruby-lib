# frozen_string_literal: true

begin
  require "rails"
  require "action_controller/railtie"
  require "active_job/railtie"
rescue LoadError
  return # run with gemfiles/rails_*.gemfile
end
require "test_helper"
require "rack/test"
require "rails/generators"
require "tmpdir"

class ZharpTestApp < Rails::Application
  config.root = __dir__
  config.eager_load = false
  config.logger = Logger.new(StringIO.new)
  config.secret_key_base = "x" * 64
  config.hosts.clear
  config.active_job.queue_adapter = :inline
  config.action_dispatch.show_exceptions = :all
  config.consider_all_requests_local = false
end

class ChargeJob < ActiveJob::Base
  def perform(id) = Rails.logger.info("charged #{id}")
end

class CartsController < ActionController::Base
  def show
    ChargeJob.perform_later(params[:id])
    render plain: "cart #{params[:id]}"
  end

  def broken
    nil.price
  end

  def handled
    Rails.error.handle { raise ArgumentError, "handled one" }
    render plain: "ok"
  end
end

# Zharp starts before the app, as Bundler.require would load it; the Railtie finds it running.
ZharpTest.start
ZharpTestApp.initialize!
ZharpTestApp.routes.draw do
  get "/carts/:id" => "carts#show"
  get "/broken" => "carts#broken"
  get "/handled" => "carts#handled"
end

class RailsTest < Minitest::Test
  include ZharpTest
  include Rack::Test::Methods

  def app = ZharpTestApp

  def server = spans.find { |s| s.kind == :server }

  def test_route_name_headers_and_the_job_in_the_same_trace
    header "Authorization", "Bearer secret"
    get "/carts/42"
    assert_equal 200, last_response.status
    assert_equal "GET /carts/:id", server.name
    assert_equal "[REDACTED]", server.attributes["http.request.header.authorization"]
    jobs = spans.select { |s| s.kind == :consumer || s.name.include?("ChargeJob") || s.name.include?("default") }
    refute_empty jobs, spans.map { |s| [s.name, s.kind] }.inspect
    assert(jobs.all? { |j| j.hex_trace_id == server.hex_trace_id }, "jobs run in the request's trace")
  end

  def test_an_unhandled_error_is_reported_once
    get "/broken"
    assert_equal 500, last_response.status
    assert_equal 1, exception_events.size + errors.size, [exception_events, errors].inspect
    event = exception_events.first
    assert_equal "NoMethodError", event.attributes["exception.type"]
    assert_equal "false", event.attributes["zharp.handled"]
    assert event.attributes["zharp.source_context"]
  end

  def test_rails_error_handle_is_a_handled_error
    get "/handled"
    assert_equal 200, last_response.status
    assert_equal 1, errors.size
    assert_equal "true", errors.first.attributes["zharp.handled"]
    assert_equal server.hex_trace_id, errors.first.trace_id.unpack1("H*")
  end

  def test_generator_writes_the_initializer
    Dir.mktmpdir do |dir|
      Rails::Generators.invoke("zharp:install", [], destination_root: dir, behavior: :invoke, shell: Thor::Shell::Basic.new.tap { |s| s.mute { } })
      text = File.read(File.join(dir, "config/initializers/zharp.rb"))
      assert_includes text, "Zharp.init("
      assert_includes text, "# logs: false"
    end
  end
end
