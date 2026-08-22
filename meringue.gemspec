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
    "allowed_push_host" => "https://rubygems.org",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true",
    "source_code_uri" => spec.homepage
  }

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "CHANGELOG.md",
      "LICENSE*",
      "README.md",
      "bin/meringue",
      "docs/head_agent_kernel_commands.md",
      "fixtures/demo_state.json",
      "lib/**/*.rb",
      "lib/**/*.js"
    ].select { |path| File.file?(path) }.sort
  end
  spec.bindir = "bin"
  spec.executables = ["meringue"]
  spec.require_paths = ["lib"]
  spec.add_runtime_dependency "base64", ">= 0.2"
end
