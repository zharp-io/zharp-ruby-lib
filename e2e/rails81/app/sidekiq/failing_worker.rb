class FailingWorker
  include Sidekiq::Job
  sidekiq_options retry: false

  def perform(order)
    raise ArgumentError, "cannot charge #{order}"
  end
end
