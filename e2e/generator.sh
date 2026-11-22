#!/bin/sh
# The Rails generator on a fresh `rails new`, run with the commands `npm init zharp` runs for Rails:
#   bundle add zharp; bundle exec rails generate zharp:install --key=<key>
# then the app boots with Zharp active and the key read from the credentials.
#   e2e/generator.sh [ruby version] [rails version]
set -eu
cd "$(dirname "$0")/.."
SRC=$(pwd -W 2>/dev/null || pwd)
RUBY=${1:-3.4}
RAILS=${2:-8.1.0}
MSYS_NO_PATHCONV=1 docker run --rm -v "$SRC:/gem:ro" -v "zharp-gen-rb$(echo "$RUBY" | tr -d .)-gems:/usr/local/bundle" "ruby:$RUBY" sh -ec "
  gem install -N bundler -v '~> 4.0' >/dev/null
  gem install -N rails -v '~> $RAILS' >/dev/null
  cd /tmp && rails new shop --minimal --skip-git --skip-docker --quiet >/dev/null
  cd shop
  bundle add zharp --path /gem >/dev/null
  bundle exec rails generate zharp:install --key=zpk_generator_test
  echo '--- config/initializers/zharp.rb'; cat config/initializers/zharp.rb
  echo '--- credentials'; bin/rails credentials:show | grep -A1 '^zharp:'
  echo '--- boot'
  ZHARP_ENDPOINT=http://127.0.0.1:9/otlp bin/rails runner 'puts [Zharp.active?, Zharp.options.key, Zharp.options.service].inspect; puts Rails.application.middleware.map(&:inspect).first(3).inspect' 2>&1
"
