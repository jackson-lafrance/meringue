# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "compactor"

module Meringue
  module State
    class Store
      DEFAULT_PATH = File.expand_path("~/.meringue/state.json")

      def self.default_path
        File.expand_path(ENV.fetch("MERINGUE_STATE_PATH", DEFAULT_PATH))
      end

      attr_reader :path

      def initialize(path: self.class.default_path)
        @path = File.expand_path(path)
      end

      def load
        return Models.empty_state unless File.exist?(path)

        state = JSON.parse(File.read(path))
        Compactor.compact!(state)
        state
      end

      def compact!
        return false unless File.exist?(path)

        state = JSON.parse(File.read(path))
        changed = Compactor.compact!(state)
        save(state) if changed
        changed
      end

      def save(state)
        FileUtils.mkdir_p(File.dirname(path))
        temp_path = "#{path}.tmp.#{$$}"
        Compactor.compact!(state)

        File.write(temp_path, JSON.pretty_generate(state) + "\n")
        File.rename(temp_path, path)
        state
      ensure
        File.delete(temp_path) if temp_path && File.exist?(temp_path)
      end
    end
  end
end
