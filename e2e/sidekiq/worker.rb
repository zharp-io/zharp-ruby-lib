# Sidekiq outside Rails: `require "zharp/sidekiq"` in the file Sidekiq loads.
require "zharp/sidekiq"

Sidekiq.configure_server { |c| c.redis = { url: ENV.fetch("REDIS_URL") } }
Sidekiq.configure_client { |c| c.redis = { url: ENV.fetch("REDIS_URL") } }

class InvoiceJob
  include Sidekiq::Job

  def perform(id) = Sidekiq.logger.info("invoice #{id} sent")
end

class ChargeJob
  include Sidekiq::Job
  sidekiq_options retry: false

  def perform(order) = raise(ArgumentError, "cannot charge #{order}")
end
