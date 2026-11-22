module Shop
  module Actions
    module Carts
      class Total < Hanami::Action
        def handle(_request, response)
          response.body = Cart.new([nil]).total.to_s
        end
      end
    end
  end
end

class Cart
  def initialize(items) = @items = items

  def total
    @items.sum { |item| item.price }
  end
end
