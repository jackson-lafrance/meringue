# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Installing from a clone set up the dependencies and left nothing on PATH, so
# the command afterwards was still `bundle exec meringue` from that directory.
# These cover the launcher both install paths now write.
class FoundationShimTest < Minitest::Test
  Shim = Meringue::Shim

  def test_it_writes_an_executable_launcher_that_names_the_checkout
    with_dirs do |source, bin|
      result = Shim.install!(source_dir: source, bin_dir: bin, env: path_env(bin))

      assert_equal Shim::INSTALLED, result.fetch("status")
      target = File.join(bin, "meringue")
      assert File.executable?(target)
      body = File.read(target)
      assert_includes body, source
      assert_includes body, "--gemfile="
    end
  end

  # An explicit --gemfile is what makes the command work from anywhere rather
  # than only from the checkout.
  def test_the_launcher_runs_from_an_unrelated_directory
    with_dirs do |source, bin|
      Shim.install!(source_dir: source, bin_dir: bin, env: path_env(bin))
      Dir.mktmpdir("meringue-elsewhere") do |elsewhere|
        body = File.read(File.join(bin, "meringue"))

        refute_includes body, "cd "
        assert_includes body, %(ruby "#{source}/bin/meringue")
        assert Dir.exist?(elsewhere)
      end
    end
  end

  def test_re_running_is_a_no_op_once_the_launcher_is_current
    with_dirs do |source, bin|
      Shim.install!(source_dir: source, bin_dir: bin, env: path_env(bin))
      again = Shim.install!(source_dir: source, bin_dir: bin, env: path_env(bin))

      assert_equal Shim::UNCHANGED, again.fetch("status")
    end
  end

  # The point of re-running is that the command follows the checkout you last
  # installed from.
  def test_a_launcher_pointing_elsewhere_is_repointed
    with_dirs do |source, bin|
      Shim.install!(source_dir: source, bin_dir: bin, env: path_env(bin))
      Dir.mktmpdir("meringue-other-checkout") do |other|
        result = Shim.install!(source_dir: other, bin_dir: bin, env: path_env(bin))

        assert_equal Shim::INSTALLED, result.fetch("status")
        assert_includes File.read(File.join(bin, "meringue")), other
      end
    end
  end

  # A shim nobody can reach is worse than none, because it looks done.
  def test_it_says_how_to_fix_a_bin_directory_that_is_not_on_path
    with_dirs do |source, bin|
      result = Shim.install!(source_dir: source, bin_dir: bin, env: { "PATH" => "/usr/bin" })

      assert_includes result.fetch("message"), "not on your PATH"
      assert_includes result.fetch("message"), %(export PATH="#{bin}:$PATH")
    end
  end

  def test_it_stays_quiet_about_path_when_the_directory_is_already_on_it
    with_dirs do |source, bin|
      result = Shim.install!(source_dir: source, bin_dir: bin, env: path_env(bin))

      refute_includes result.fetch("message"), "not on your PATH"
      assert_includes result.fetch("message"), "from anywhere"
    end
  end

  def test_the_opt_out_skips_it_entirely
    with_dirs do |source, bin|
      result = Shim.install!(source_dir: source, bin_dir: bin, env: { Shim::OPT_OUT => "1" })

      assert_equal Shim::SKIPPED, result.fetch("status")
      refute File.exist?(File.join(bin, "meringue"))
      assert_empty result.fetch("message")
    end
  end

  # A read-only bin directory is a reason to explain, not to fail the install
  # that called this.
  def test_an_unwritable_directory_reports_rather_than_raising
    with_dirs do |source, bin|
      FileUtils.chmod(0o500, bin)
      result = Shim.install!(source_dir: source, bin_dir: bin, env: path_env(bin))

      assert_equal Shim::FAILED, result.fetch("status")
      assert_includes result.fetch("message"), "bundle exec meringue"
    ensure
      FileUtils.chmod(0o700, bin)
    end
  end

  def test_the_bin_directory_is_configurable_and_defaults_under_home
    assert_equal File.expand_path("/custom/bin"), Shim.default_bin_dir(env: { Shim::BIN_DIR_ENV => "/custom/bin" })
    assert_equal File.expand_path("~/.local/bin"), Shim.default_bin_dir(env: {})
  end

  # Bundler evaluates the Gemfile more than once per install, so the message
  # would otherwise print twice.
  def test_the_announcement_only_fires_once_per_process
    Shim.instance_variable_set(:@announced, nil)

    refute Shim.announced!
    assert Shim.announced!
  ensure
    Shim.instance_variable_set(:@announced, nil)
  end

  # The Gemfile loads this before the rest of Meringue — or any dependency —
  # exists, so it has to stand on its own. The subprocess gets a cleaned
  # environment because Bundler's own RUBYOPT would otherwise load exactly the
  # things this is asserting are not needed.
  def test_it_loads_without_the_rest_of_meringue
    path = Meringue.root_path("lib", "meringue", "shim.rb")
    script = "require #{path.dump}; print Meringue::Shim::NAME"
    output = IO.popen(Meringue::SubprocessEnvironment.clean, ["ruby", "-e", script], err: %i[child out], &:read)

    assert_equal "meringue", output.strip
  end

  private

  def path_env(bin)
    { "PATH" => [bin, "/usr/bin"].join(File::PATH_SEPARATOR) }
  end

  def with_dirs
    Dir.mktmpdir("meringue-shim") do |dir|
      source = File.join(dir, "src")
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p([source, bin])
      yield File.realpath(source), File.realpath(bin)
    end
  end
end
