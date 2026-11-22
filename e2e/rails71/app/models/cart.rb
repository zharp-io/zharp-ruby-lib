class Cart
  def initialize(items) = @items = items

  def total
    @items.sum { |item| item.price }
  end
end
