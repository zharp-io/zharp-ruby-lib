class CartsController < ApplicationController
  # A request that queues one Sidekiq job and one Active Job (Solid Queue): both in its trace.
  def show
    Rails.logger.info("showing cart #{params[:id]}")
    ReceiptWorker.perform_async(params[:id].to_i)
    ReceiptJob.perform_later(params[:id].to_i)
    render json: { cart: params[:id], pid: Process.pid }
  end

  # An unhandled NoMethodError in a model.
  def total
    render json: { total: Cart.new([nil]).total }
  end

  def failing_job
    FailingWorker.perform_async("order-7")
    render json: { queued: true }
  end

  def pid
    render json: { pid: Process.pid }
  end
end
