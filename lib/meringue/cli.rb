# frozen_string_literal: true

module Meringue
  class CLI
    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
    end

    def run
      case argv.first
      when nil
        App.new(out: out).run
      when "-v", "--version", "version"
        out.puts VERSION
        0
      when "-h", "--help", "help"
        print_help
        0
      when "demo-state"
        out.puts File.read(Meringue.root_path("fixtures", "demo_state.json"))
        0
      else
        err.puts "Unknown command: #{argv.first}"
        print_help
        1
      end
    end

    private

    attr_reader :argv, :out, :err

    def print_help
      out.puts <<~HELP
        Meringue #{VERSION}

        Usage:
          meringue             # boot the scaffolded app
          meringue demo-state  # print the fake demo state fixture
          meringue --version   # print the app version
          meringue --help      # print this help
      HELP
    end
  end
end
