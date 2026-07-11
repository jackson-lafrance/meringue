# frozen_string_literal: true

require "fileutils"
require "json"

module Meringue
  module State
    class Store
      DEFAULT_PATH = File.expand_path("~/.meringue/state.json")

      attr_reader :path

      def initialize(path: DEFAULT_PATH)
        @path = File.expand_path(path)
      end

      def load
        return Models.empty_state unless File.exist?(path)

        JSON.parse(File.read(path))
      end

      def save(state)
        FileUtils.mkdir_p(File.dirname(path))
        temp_path = "#{path}.tmp.#{$$}"

        File.write(temp_path, JSON.pretty_generate(state) + "\n")
        File.rename(temp_path, path)
        state
      ensure
        File.delete(temp_path) if temp_path && File.exist?(temp_path)
      end
    end
  end
end
