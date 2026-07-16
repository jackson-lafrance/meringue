# frozen_string_literal: true

require_relative "lib/meringue/version"

Gem::Specification.new do |spec|
  spec.name = "meringue"
  spec.version = Meringue::VERSION
  spec.summary = "Terminal-first control plane for multi-agent development."
  spec.description = "Meringue coordinates projects, issues, agents, questions, and logs across pluggable coding-agent harnesses."
  spec.authors = ["Meringue contributors"]
  spec.homepage = "https://github.com/jackson-lafrance/meringue"
  spec.license = "Nonstandard"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "source_code_uri" => spec.homepage
  }

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "AGENTS.md",
      "README.md",
      "bin/*",
      "docs/**/*.md",
      "fixtures/**/*",
      "lib/**/*.rb"
    ].select { |path| File.file?(path) }
  end
  spec.bindir = "bin"
  spec.executables = ["meringue"]
  spec.require_paths = ["lib"]
end
