require "bundler/setup"
require "logger"
require "zharp"

class Cart
  def initialize(items) = @items = items

  def total
    @items.sum { |item| item.price }
  end
end

LOG = Logger.new($stdout)

APP = lambda do |env|
  case env["PATH_INFO"]
  when "/orders"
    order = env["rack.input"].read
    [422, { "content-type" => "application/json" }, [%({"error":"card declined","order":#{order},"session_token":"s-1"})]]
  when %r{\A/carts/\d+/total\z} then [200, { "content-type" => "text/plain" }, [Cart.new([nil]).total.to_s]]
  when %r{\A/carts/(\d+)\z}
    LOG.info("showing cart #{$1}")
    [200, { "content-type" => "application/json" }, [%({"cart":"#{$1}","pid":#{Process.pid}})]]
  else [404, {}, ["not found"]]
  end
end

use Zharp::Rack
run APP
