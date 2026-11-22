require "sinatra/base"
require "logger"

class Cart
  def initialize(items) = @items = items

  def total
    @items.sum { |item| item.price }
  end
end

class App < Sinatra::Base
  set :show_exceptions, false
  set :raise_errors, false
  set :host_authorization, { permitted_hosts: [] }
  LOG = Logger.new($stdout)

  get "/carts/:id" do
    LOG.info("showing cart #{params[:id]}")
    content_type :json
    %({"cart":"#{params[:id]}","pid":#{Process.pid}})
  end

  get "/carts/:id/total" do
    Cart.new([nil]).total.to_s
  end
end
