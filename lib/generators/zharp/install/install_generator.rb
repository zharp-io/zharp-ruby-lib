# frozen_string_literal: true

require "rails/generators"

module Zharp
  module Generators
    # bin/rails generate zharp:install [--key=zpk_…]
    #
    # Writes config/initializers/zharp.rb (every option there, commented out) and, given a key,
    # stores it in the credentials as zharp.key. Without one it says how to set ZHARP_KEY.
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      class_option :key, type: :string, desc: "Your Zharp ingest key (zpk_…), stored in the credentials as zharp.key"

      def create_initializer
        template "zharp.rb.tt", "config/initializers/zharp.rb"
      end

      def store_key
        key = options[:key].to_s.strip
        if key.empty?
          say "Set your key: ZHARP_KEY=zpk_… in the environment, or bin/rails credentials:edit and add\n  zharp:\n    key: zpk_…", :yellow
          return
        end
        credentials = ::Rails.application.credentials
        content = credentials.read.to_s
        if content.match?(/^zharp:\s*$/)
          say "credentials already have a zharp: section; left as it is", :yellow
          return
        end
        credentials.write("#{content.chomp}\n\nzharp:\n  key: #{key}\n".lstrip)
        say_status :credentials, "zharp.key added (#{credentials.content_path.basename})"
      rescue StandardError => e
        say "Could not write the credentials (#{e.message}). Set ZHARP_KEY=#{key} in the environment instead.", :red
      end
    end
  end
end
