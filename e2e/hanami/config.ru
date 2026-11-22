require "hanami/boot"
require "zharp"

use Zharp::Rack
run Hanami.app
