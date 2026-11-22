# frozen_string_literal: true

require "json"
require "rbconfig"

module Zharp
  # The code around an error's lines, read on the app's own server and sent with the error as
  # zharp.source_context. Ruby runs its source files, so the lines are right there: Zharp shows
  # exactly the code that ran, with no repository link and nothing to upload. Only the app's own
  # frames (never gems, Ruby's library, OpenTelemetry or Zharp), the innermost five, five lines
  # either side, each line capped. capture_source_context: false (or
  # ZHARP_CAPTURE_SOURCE_CONTEXT=false) turns it off.
  module Source
    ATTRIBUTE = "zharp.source_context"
    AROUND = 5
    MAX_FRAMES = 5
    MAX_LINE = 300
    MAX_BYTES = 12_000
    MAX_FILES = 200

    @enabled = true
    @cache = {}
    @lock = Mutex.new

    class << self
      attr_accessor :enabled

      # The JSON for an error's frames, innermost first: [{file, line, pre, code, post}].
      # frames: [[path as the stack prints it, path to read, line]].
      def context_of(frames)
        return nil unless enabled

        out = []
        seen = {}
        frames.each do |shown, readable, line|
          break if out.size >= MAX_FRAMES
          next if line.nil? || line < 1 || seen[[shown, line]] || !Paths.app?(readable)

          seen[[shown, line]] = true
          lines = lines_of(readable)
          next if lines.nil? || line > lines.size

          pre = lines[[0, line - 1 - AROUND].max...(line - 1)].map { |l| cut(l) }
          post = (lines[line, AROUND] || []).map { |l| cut(l) }
          out << { file: shown, line: line, pre: pre, code: cut(lines[line - 1]), post: post }
        end
        until out.empty?
          text = JSON.generate(out)
          return text if text.bytesize <= MAX_BYTES

          out.pop
        end
        nil
      rescue StandardError
        nil
      end

      def of_exception(error)
        context_of(frames_of(error))
      end

      # An exception's frames, innermost first.
      def frames_of(error)
        locations = error.backtrace_locations
        if locations
          locations.map { |l| [l.path, l.absolute_path || l.path, l.lineno] }
        else
          (error.backtrace || []).filter_map do |text|
            m = /\A(.+?):(\d+)(?::in |\z)/.match(text)
            [m[1], m[1], m[2].to_i] if m
          end
        end
      end

      def cut(text)
        text = text.to_s.chomp
        text.length <= MAX_LINE ? text : "#{text[0, MAX_LINE - 1]}…"
      end

      def lines_of(path)
        @lock.synchronize do
          return @cache[path] if @cache.key?(path)

          @cache.shift if @cache.size >= MAX_FILES
          @cache[path] =
            begin
              File.file?(path) && File.size(path) < 2_000_000 ? File.readlines(path, chomp: true, encoding: "UTF-8") : nil
            rescue StandardError
              nil
            end
        end
      end
    end
  end

  # Where a frame's file lives: the app's own code, or not (gems, Ruby's library, the VM, Zharp).
  module Paths
    ZHARP_DIR = File.expand_path("..", __dir__)

    class << self
      def app?(path)
        return false if path.nil? || path.empty? || path.start_with?("<") || path.start_with?("(")
        return false if library_roots.any? { |root| path.start_with?(root) }

        !path.match?(%r{[\\/]gems[\\/]|[\\/]lib[\\/]ruby[\\/]\d})
      end

      def library_roots
        @library_roots ||= begin
          roots = [ZHARP_DIR, RbConfig::CONFIG["rubylibprefix"], RbConfig::CONFIG["rubylibdir"]]
          roots.concat(Gem.path) if defined?(Gem)
          roots << ::Bundler.bundle_path.to_s if defined?(::Bundler) && (::Bundler.bundle_path rescue nil)
          roots.compact.reject(&:empty?).map { |r| File.expand_path(r) + "/" }.uniq
        end
      end
    end
  end
end
