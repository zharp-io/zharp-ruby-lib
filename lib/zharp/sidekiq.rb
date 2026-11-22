# frozen_string_literal: true

# A Sidekiq process outside Rails. At the top of the file Sidekiq loads (sidekiq -r ./worker.rb):
#
#   require "zharp/sidekiq"
#
# Sidekiq keeps only one -r, so this goes in that file rather than on the command line. ZHARP_KEY
# and the other settings come from the environment. Rails apps need nothing: the Railtie starts
# Zharp in Sidekiq too.
require "sidekiq"
require "zharp"

Zharp.init
