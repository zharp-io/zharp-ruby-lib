require "bundler/setup"
require_relative "app"
require "zharp"

use Zharp::Rack
run App
