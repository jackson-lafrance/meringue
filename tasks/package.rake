# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rubygems/package"
require "tmpdir"

module PackageVerification
  ROOT = File.expand_path("..", __dir__)
  REQUIRED_FILES = %w[
    CHANGELOG.md
    README.md
    bin/meringue
    docs/head_agent_kernel_commands.md
    fixtures/demo_state.json
    lib/meringue.rb
    lib/meringue/version.rb
    lib/meringue/harness/extensions/command_blacklist.js
  ].freeze
  FORBIDDEN_PATHS = %w[AGENTS.md].freeze
  FORBIDDEN_PREFIXES = %w[benchmark/ proof/ test/].freeze

  module_function

  def verify!
    spec = Gem::Specification.load(File.join(ROOT, "meringue.gemspec"))
    abort "Could not load meringue.gemspec" unless spec

    gem_path = File.join(ROOT, "pkg", "#{spec.full_name}.gem")
    FileUtils.mkdir_p(File.dirname(gem_path))
    FileUtils.rm_f(gem_path)

    run!(Gem.ruby, "-S", "gem", "build", "meringue.gemspec", "--strict", "--output", gem_path, chdir: ROOT)
    verify_contents!(gem_path, spec)
    verify_install!(gem_path, spec)

    puts "Verified #{gem_path.delete_prefix("#{ROOT}/")}: contents, metadata, install, and CLI smoke tests passed."
  end

  def verify_contents!(gem_path, expected_spec)
    package = Gem::Package.new(gem_path)
    contents = package.contents
    built_spec = package.spec

    missing = REQUIRED_FILES - contents
    abort "Gem is missing required files: #{missing.join(", ")}" unless missing.empty?

    forbidden = contents.select do |path|
      FORBIDDEN_PATHS.include?(path) || FORBIDDEN_PREFIXES.any? { |prefix| path.start_with?(prefix) }
    end
    abort "Gem contains development-only files: #{forbidden.join(", ")}" unless forbidden.empty?

    abort "Built gem name changed to #{built_spec.name}" unless built_spec.name == "meringue"
    abort "Built gem version changed to #{built_spec.version}" unless built_spec.version == expected_spec.version
    abort "Built gem executable list is not intentional" unless built_spec.executables == ["meringue"]
    abort "Built gem does not require MFA for publishing" unless built_spec.metadata["rubygems_mfa_required"] == "true"
    abort "Built gem may publish outside RubyGems.org" unless built_spec.metadata["allowed_push_host"] == "https://rubygems.org"
  end

  def verify_install!(gem_path, spec)
    Dir.mktmpdir("meringue-gem-install") do |directory|
      gem_home = File.join(directory, "gem-home")
      bin_dir = File.join(directory, "bin")
      install_runtime_dependencies!(spec, gem_home, bin_dir)
      install_gem!(gem_path, gem_home, bin_dir)

      environment = { "GEM_HOME" => gem_home, "GEM_PATH" => gem_home }
      executable = File.join(bin_dir, "meringue")

      version_output = capture!(environment, executable, "--version")
      abort "Installed executable reported #{version_output.strip.inspect}" unless version_output.strip == spec.version.to_s

      help_output = capture!(environment, executable, "--help")
      abort "Installed executable did not print help" unless help_output.include?("Usage:")

      demo_state = JSON.parse(capture!(environment, executable, "demo-state"))
      abort "Installed gem did not load its demo state" unless demo_state.is_a?(Hash)
    end
  end

  def install_runtime_dependencies!(spec, gem_home, bin_dir)
    spec.runtime_dependencies.each do |dependency|
      installed_spec = Gem::Specification.find_by_name(dependency.name, dependency.requirement)
      cache_file = installed_spec.cache_file
      abort "Cached gem is unavailable for #{dependency}" unless File.file?(cache_file)

      install_gem!(cache_file, gem_home, bin_dir)
    end
  end

  def install_gem!(gem_path, gem_home, bin_dir)
    run!(
      Gem.ruby, "-S", "gem", "install", gem_path,
      "--local", "--ignore-dependencies", "--no-document",
      "--install-dir", gem_home, "--bindir", bin_dir
    )
  end

  def run!(*command, **options)
    success = Bundler.with_unbundled_env { system(*command, **options) }
    return if success

    abort "Command failed: #{command.join(" ")}"
  end

  def capture!(environment, *command)
    output, status = Bundler.with_unbundled_env { Open3.capture2e(environment, *command) }
    return output if status.success?

    abort "Command failed: #{command.join(" ")}\n#{output}"
  end
end

namespace :package do
  desc "Strictly build, inspect, install, and smoke-test the gem"
  task :verify do
    PackageVerification.verify!
  end
end
