class ReceiptJob < ActiveJob::Base
  queue_as :default

  def perform(id)
    Rails.logger.info("solid queue receipt #{id}")
  end
end
