# frozen_string_literal: true

require "open3"
require "rbconfig"
require "stringio"

# Helpers shared by the foundation slice tests.
#
# Everything here must stay hermetic: no network, no real harness processes,
# and no writes outside of a caller-owned Dir.mktmpdir.
module FoundationSupport
  REPO_ROOT = File.expand_path("../..", __dir__)

  module_function

  # Absolute path inside the repository checkout under test.
  def repo_path(*parts)
    File.join(REPO_ROOT, *parts)
  end

  # Run Meringue::CLI in-process with captured stdout/stderr.
  # Returns [status, stdout_string, stderr_string].
  def run_cli(*argv, stdin: "")
    out = StringIO.new
    err = StringIO.new
    status = Meringue::CLI.new(argv, input: StringIO.new(stdin), out: out, err: err).run
    [status, out.string, err.string]
  end

  # Run a ruby subprocess from the repository root.
  # Used only for entrypoint checks that cannot be done in-process.
  # Returns [status, stdout_string, stderr_string].
  def run_ruby(*args)
    stdout, stderr, status = Open3.capture3(
      Meringue::SubprocessEnvironment.clean, RbConfig.ruby, *args, chdir: REPO_ROOT
    )
    [status.exitstatus, stdout, stderr]
  end

  # Every ruby file that ships in the library.
  def library_files
    Dir[File.join(REPO_ROOT, "lib", "**", "*.rb")].sort
  end

  # Ruby files from this checkout that are already loaded in this process.
  def loaded_library_files
    prefix = File.join(REPO_ROOT, "lib")
    $LOADED_FEATURES.select { |path| path.start_with?(prefix) }.sort
  end

  # Yields a scratch directory that is removed afterwards.
  def with_tmpdir
    Dir.mktmpdir("meringue-foundation-test-") do |dir|
      yield dir
    end
  end
end
