# A nightly script that crashes: the error that ends it is reported (handled=false) and sent
# before the process exits.
require "bundler/setup"
require "logger"
require "zharp"

Zharp.init(service: "e2e-script")
LOG = Logger.new($stdout)

def parse(rows)
  rows.map { |row| Integer(row) }
end

Zharp.start_span("nightly import") do
  LOG.info("importing 3 rows")
  begin
    parse(["1", "two"])
  rescue ArgumentError => e
    Zharp.capture_error(e, step: "first pass")
  end
end
Zharp.log.info("first pass done", rows: 3)
parse(["3", "four"])
