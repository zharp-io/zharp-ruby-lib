# ZHARP_LOGS=true with semantic_logger: lines sent from the SDK in their span's context, and stamped
# on stdout too.
require "bundler/setup"
require "semantic_logger"
require "zharp"

SemanticLogger.add_appender(io: $stdout, formatter: :default)
SemanticLogger.add_appender(io: $stdout, formatter: :json)
Zharp.init(service: "e2e-semantic")
log = SemanticLogger["Billing"]

log.info("outside any span")
Zharp.start_span("charge order") do
  log.info("charging order", order_id: 7)
  log.warn("card expires soon")
  begin
    raise KeyError, "no card on file"
  rescue KeyError => e
    log.error("charge failed", e)
  end
end
SemanticLogger.flush
Zharp.flush
