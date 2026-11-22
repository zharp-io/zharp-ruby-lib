require_relative "boot"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "active_job/railtie"

Bundler.require(*Rails.groups)

module Shop
  class Application < Rails::Application
    config.load_defaults 7.1
    config.eager_load = true
    config.api_only = true
    config.logger = ActiveSupport::Logger.new($stdout)
    config.log_level = :info
    config.hosts.clear
  end
end
