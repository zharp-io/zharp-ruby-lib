class ReceiptWorker
  include Sidekiq::Job

  def perform(id)
    Sidekiq.logger.info("sidekiq receipt #{id}")
  end
end
