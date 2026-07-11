# frozen_string_literal: true

module Meringue
  class App
    def initialize(out: $stdout)
      @out = out
    end

    def run
      out.puts "Meringue #{VERSION}"
      out.puts "Ruby CLI app scaffold is ready."
      out.puts "Manual Pi head loop: ruby -Ilib bin/meringue head-loop"
      out.puts "Manual fake head loop: ruby -Ilib bin/meringue fake-head-loop"
      0
    end

    private

    attr_reader :out
  end
end
