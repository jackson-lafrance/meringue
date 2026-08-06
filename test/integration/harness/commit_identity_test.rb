# frozen_string_literal: true

require "test_helper"

# CommitIdentity is the boundary between a managed harness process and git. The
# repositories here are disposable and never use the checkout's git config.
class HarnessCommitIdentityTest < Minitest::Test
  def test_worker_commit_uses_the_repository_user_identity
    with_repository do |repo, env|
      configure(repo, env, "user.name", "Ada User")
      configure(repo, env, "user.email", "ada@example.test")
      identity_env = managed_environment(repo, env)

      File.write(File.join(repo, "change.txt"), "worker change\n")
      run_git!(repo, env.merge(identity_env), "add", "change.txt")
      run_git!(repo, env.merge(identity_env), "commit", "-m", "worker delivery")

      author = run_git!(repo, env, "show", "-s", "--format=%an <%ae> | %cn <%ce>", "HEAD").strip
      assert_equal "Ada User <ada@example.test> | Ada User <ada@example.test>", author
    end
  end

  def test_meringue_identity_fails_closed_instead_of_authoring_a_commit
    with_repository do |repo, env|
      configure(repo, env, "user.name", "Meringue Worker")
      configure(repo, env, "user.email", "agent@meringue.local")
      identity_env = managed_environment(repo, env)

      File.write(File.join(repo, "change.txt"), "unattributed change\n")
      run_git!(repo, env.merge(identity_env), "add", "change.txt")
      _stdout, stderr, status = Open3.capture3(
        env.merge(identity_env),
        "git", "-C", repo, "commit", "-m", "must not be authored by Meringue"
      )

      refute status.success?
      assert_includes stderr, "Author identity unknown"
      assert_equal 1, run_git!(repo, env, "rev-list", "--count", "HEAD").to_i
    end
  end

  def test_a_global_user_identity_is_used_when_a_local_meringue_identity_is_stale
    with_repository do |repo, env, home|
      configure(repo, env, "user.name", "Meringue")
      configure(repo, env, "user.email", "meringue@example.com")
      configure_global(home, env, "user.name", "Repository Owner")
      configure_global(home, env, "user.email", "owner@example.test")
      identity_env = managed_environment(repo, env)

      File.write(File.join(repo, "change.txt"), "owner change\n")
      run_git!(repo, env.merge(identity_env), "add", "change.txt")
      run_git!(repo, env.merge(identity_env), "commit", "-m", "owner delivery")

      assert_equal "Repository Owner <owner@example.test>",
                   run_git!(repo, env, "show", "-s", "--format=%an <%ae>", "HEAD").strip
    end
  end

  private

  def with_repository
    Dir.mktmpdir("meringue-commit-identity") do |tmp|
      home = File.join(tmp, "home")
      repo = File.join(tmp, "repo")
      FileUtils.mkdir_p([home, repo])
      env = {
        "HOME" => home,
        "GIT_CONFIG_GLOBAL" => File.join(home, "gitconfig"),
        "GIT_CONFIG_SYSTEM" => "/dev/null",
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_TERMINAL_PROMPT" => "0"
      }
      run_git!(repo, env, "init", "--initial-branch=main")
      File.write(File.join(repo, "README.md"), "seed\n")
      configure(repo, env, "user.name", "Repository Owner")
      configure(repo, env, "user.email", "owner@example.test")
      run_git!(repo, env, "add", "README.md")
      run_git!(repo, env, "commit", "-m", "seed")
      yield repo, env, home
    end
  end

  def managed_environment(repo, env)
    Meringue::Git::CommitIdentity.environment(
      cwd: repo,
      base_environment: env.merge(
        "GIT_AUTHOR_NAME" => "Meringue Worker",
        "GIT_AUTHOR_EMAIL" => "agent@meringue.local",
        "GIT_COMMITTER_NAME" => "Meringue Worker",
        "GIT_COMMITTER_EMAIL" => "agent@meringue.local"
      )
    )
  end

  def configure(repo, env, key, value)
    run_git!(repo, env, "config", key, value)
  end

  def configure_global(home, env, key, value)
    run_git!(home, env, "config", "--global", key, value)
  end

  def run_git!(cwd, env, *argv)
    stdout, stderr, status = Open3.capture3(env, "git", "-C", cwd, *argv)
    raise "git #{argv.join(" ")} failed: #{stderr}#{stdout}" unless status.success?

    stdout
  end
end
