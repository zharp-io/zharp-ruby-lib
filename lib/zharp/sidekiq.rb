# frozen_string_literal: true

# A Sidekiq process outside Rails: bundle exec sidekiq -r ./app.rb -r zharp/sidekiq
# (Rails apps need nothing: the Railtie starts Zharp in Sidekiq too.)
require "sidekiq"
require "zharp"

Zharp.init
