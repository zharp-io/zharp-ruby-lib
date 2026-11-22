#!/bin/sh
# Unit tests across Ruby 3.3 / 3.4 / 4.0 × Rails 7.1 / 7.2 / 8.1, in Docker (no Ruby on the host).
#   e2e/unit.sh                 # the whole matrix
#   e2e/unit.sh 3.4 8.1         # one cell
set -u
cd "$(dirname "$0")/.."
SRC=$(pwd -W 2>/dev/null || pwd)
rubies=${1:-"3.3 3.4 4.0"}
rails=${2:-"none 7.1 7.2 8.1"}
status=0
for r in $rubies; do
  for v in $rails; do
    if [ "$v" = none ]; then gemfile=Gemfile; else gemfile=gemfiles/rails_$v.gemfile; fi
    printf '%-10s %-10s ' "ruby $r" "rails $v"
    out=$(MSYS_NO_PATHCONV=1 docker run --rm -v "zharp-rb$(echo "$r" | tr -d .)-gems:/usr/local/bundle" -v "$SRC:/src" -w /src \
      -e BUNDLE_GEMFILE="/src/$gemfile" "ruby:$r" sh -c \
      'gem install -N bundler -v "~> 4.0" >/dev/null 2>&1; bundle install --quiet >/tmp/install.log 2>&1 || { tail -20 /tmp/install.log; exit 2; }; bundle exec rake 2>&1' )
    code=$?
    echo "$out" | grep -E "runs, .* assertions" | tr '\n' ' '
    [ $code -eq 0 ] && echo "ok" || { echo "FAILED"; echo "$out" | tail -40; status=1; }
  done
done
exit $status
