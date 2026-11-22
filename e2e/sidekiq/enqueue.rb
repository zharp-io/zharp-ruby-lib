# A client process that queues two jobs inside one span: both run in its trace.
require_relative "worker"

Zharp.start_span("nightly billing", kind: :internal) do
  InvoiceJob.perform_async(7)
  ChargeJob.perform_async("order-7")
end
Zharp.flush
