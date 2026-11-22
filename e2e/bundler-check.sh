#!/bin/sh
# Times `bundle add zharp` in fresh Rails apps with each Bundler a Ruby shop may have.
#   e2e/bundler-check.sh [rails versions] [bundler versions]
set -u
cd "$(dirname "$0")/.."
SRC=$(pwd -W 2>/dev/null || pwd)
RAILS=${1:-"8.1.0 7.1.0"}
BUNDLERS=${2:-"2.6.9 2.7.2 4.0.1"}
MSYS_NO_PATHCONV=1 docker run --rm -v "$SRC:/gem:ro" ruby:3.4 sh -c "
  for b in $BUNDLERS; do gem install -N bundler -v \$b >/dev/null 2>&1; done
  for r in $RAILS; do
    gem install -N rails -v \"~> \$r\" >/dev/null 2>&1
    v=\$(gem list '^railties$' | grep -o \"\${r%.*}\.[0-9.]*\" | head -1)
    cd /tmp && rm -rf app && rails _\${v}_ new app --minimal --skip-git --skip-docker --quiet >/dev/null 2>&1
    cp app/Gemfile app/Gemfile.lock /tmp/
    for b in $BUNDLERS; do
      cp /tmp/Gemfile /tmp/Gemfile.lock app/
      cd app
      s=\$(date +%s)
      timeout 600 bundle _\${b}_ add zharp --path /gem >/tmp/add.log 2>&1
      code=\$?
      e=\$(( \$(date +%s) - s ))
      echo \"rails \$v  bundler \$b  exit=\$code  \${e}s  \$(bundle _\${b}_ exec ruby -e 'require \"zharp\"; print Zharp::VERSION' 2>/dev/null)\"
      [ \$code -ne 0 ] && tail -5 /tmp/add.log
      cd /tmp
    done
  done
"
