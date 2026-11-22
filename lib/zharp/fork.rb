# frozen_string_literal: true

require "net/http"

module Zharp
  # Forking servers (Puma in cluster mode, Unicorn, Resque, Pitchfork). OpenTelemetry's batch
  # processors restart their thread after a fork, but its OTLP exporters keep the parent's
  # Net::HTTP connection: two processes writing to one socket. Zharp hooks Process._fork and gives
  # each child exporter a connection of its own (the parent's is left alone), so preload_app!
  # needs nothing.
  module Fork
    @exporters = []
    @callbacks = []

    class << self
      attr_reader :exporters

      def register(exporter)
        @exporters << exporter
      end

      def after_fork(&block)
        @callbacks << block
      end

      def in_child
        @exporters.each { |exporter| reconnect(exporter) }
        @callbacks.each do |callback|
          callback.call
        rescue StandardError => e
          Zharp.debug("after fork: #{e.message}")
        end
      end

      # A fresh, unstarted connection with the same settings; the inherited one is never touched
      # (finishing it would close the parent's TLS session).
      def reconnect(exporter)
        old = exporter.instance_variable_get(:@http)
        return unless old.is_a?(::Net::HTTP)

        http = ::Net::HTTP.new(old.address, old.port)
        http.use_ssl = old.use_ssl?
        http.verify_mode = old.verify_mode
        http.ca_file = old.ca_file if old.ca_file
        http.cert = old.cert if old.cert
        http.key = old.key if old.key
        http.keep_alive_timeout = old.keep_alive_timeout
        exporter.instance_variable_set(:@http, http)
      rescue StandardError => e
        Zharp.debug("reconnect after fork: #{e.message}")
      end

      def install
        return if @installed

        @installed = true
        ::Process.singleton_class.prepend(Hook)
      end
    end

    # Process._fork (Ruby 3.1+) is what fork, Process.fork and Kernel#fork all go through.
    module Hook
      def _fork
        pid = super
        Fork.in_child if pid.zero?
        pid
      end
    end
  end
end
