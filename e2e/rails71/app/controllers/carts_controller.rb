class CartsController < ApplicationController
  def show
    Rails.logger.info("showing cart #{params[:id]}")
    render json: { cart: params[:id], pid: Process.pid }
  end

  def total
    render json: { total: Cart.new([nil]).total }
  end
end
