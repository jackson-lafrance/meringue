# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"
require "rbconfig"

# Private-style executable stubs use real throwaway Git worktrees, exercising
# the public provider contract without requiring an external worktree manager.
class WorkspaceManagerCommandProviderTest < Minitest::Test
  include WorkspaceSupport

  class InterruptAfterProvisionManager < Meringue::Workspace::Manager
    private

    def run_command(*argv, **options)
      result = super
      if argv.include?("provision") && !@interrupted
        @interrupted = true
        raise Interrupt, "simulated manager interruption"
      end
      result
    end
  end

  def test_native_git_is_default_and_config_builds_a_command_provider
    native = Meringue::Workspace::Manager.new(root_path: "/tmp/unused-workspace-root")
    assert_equal "native_git", native.worktree_provider.kind
    assert_equal "native_git", native.worktree_provider_fallback

    config = WorkspaceSupport::StubConfig.new(
      "workspace" => {
        "worktree_provider" => "command",
        "worktree_provider_fallback" => "none",
        "worktree_provider_command" => "private-adapter --quiet"
      }
    )
    configured = Meringue::Workspace::Manager.from_config(config, root_path: "/tmp/unused-workspace-root")
    assert_equal "command", configured.worktree_provider.kind
    assert_equal ["private-adapter", "--quiet"], configured.worktree_provider.command
    assert_equal "none", configured.worktree_provider_fallback
    assert_equal %w[native_git command],
                 Meringue::Config::Schema.fetch("workspace.worktree_provider").option_values
  end

  def test_command_provider_provisions_validates_reuses_and_prunes_selected_path
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      log = File.join(tmp, "provider.jsonl")
      provider_root = File.join(tmp, "provider-owned")
      script = write_provider_stub(tmp, destination_root: provider_root, log: log)
      manager = command_manager(tmp, command: [RbConfig.ruby, script])

      workspace = allocate_workspace(manager, project)
      assert workspace.fetch("created"), workspace.inspect
      assert_equal "command", workspace.fetch("worktree_provider")
      assert_equal "private-slot", workspace.fetch("worktree_provider_identifier")
      assert workspace.fetch("worktree_root_path").start_with?(real_path(provider_root))
      refute workspace.fetch("worktree_root_path").start_with?(real_path(manager.root_path))
      assert manager.validate_worker_workspace(workspace, agent_id: "P1-I1-W1").fetch("usable")

      adopted = allocate_workspace(manager, project)
      assert adopted.fetch("adopted"), adopted.inspect
      assert_equal workspace.fetch("worktree_root_path"), adopted.fetch("worktree_root_path")
      assert_equal 1, provider_calls(log, "provision").length

      branch = workspace.fetch("workspace_branch")
      cleanup = manager.cleanup_pruned_worker_workspace(workspace)
      assert_equal "removed", cleanup.fetch("status")
      assert_equal "provider_workspace_released", cleanup.fetch("reason")
      refute cleanup.fetch("worktree_retained")
      refute Dir.exist?(workspace.fetch("worktree_root_path"))
      assert branch_exists?(project, branch)
      release = provider_calls(log, "release").fetch(0)
      assert_equal "private-slot", option(release, "--identifier")
      assert_equal workspace.fetch("worktree_root_path"), option(release, "--worktree-path")
    end
  end

  def test_arguments_are_not_shell_evaluated_and_dirty_cleanup_does_not_release
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      log = File.join(tmp, "provider.jsonl")
      marker = File.join(tmp, "must-not-exist")
      script = write_provider_stub(tmp, destination_root: File.join(tmp, "provider"), log: log)
      manager = command_manager(tmp, command: [RbConfig.ruby, script])
      title = "Literal ; touch #{marker}"

      workspace = allocate_workspace(manager, project, task_title: title)
      refute File.exist?(marker)
      provision = provider_calls(log, "provision").fetch(0)
      assert_includes option(provision, "--name"), "literal-touch"

      File.write(File.join(workspace.fetch("workspace_path"), "dirty.txt"), "dirty")
      cleanup = manager.cleanup_pruned_worker_workspace(workspace)
      assert_equal "failed", cleanup.fetch("status")
      assert_equal "worktree_dirty", cleanup.fetch("reason")
      assert_empty provider_calls(log, "release")
    end
  end

  def test_retained_worktree_release_is_verified_and_delivery_branch_is_restored
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      log = File.join(tmp, "provider.jsonl")
      script = write_provider_stub(
        tmp,
        destination_root: File.join(tmp, "reusable"),
        log: log,
        retain_worktree: true
      )
      manager = command_manager(tmp, command: [RbConfig.ruby, script])
      workspace = allocate_workspace(manager, project)
      branch = workspace.fetch("workspace_branch")

      cleanup = manager.cleanup_pruned_worker_workspace(workspace)
      assert_equal "removed", cleanup.fetch("status")
      assert cleanup.fetch("worktree_retained")
      assert Dir.exist?(workspace.fetch("worktree_root_path"))
      assert branch_exists?(project, branch)
      refute_equal "refs/heads/#{branch}", worktree_record(project, workspace.fetch("worktree_root_path"))["branch"]

      repeated = manager.cleanup_pruned_worker_workspace(workspace)
      assert_equal "already_removed", repeated.fetch("status")
      assert_equal "provider_workspace_already_released", repeated.fetch("reason")
      assert_equal 1, provider_calls(log, "release").length
    end
  end

  def test_missing_provider_uses_safe_fallback_or_fails_closed
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      missing = File.join(tmp, "missing-provider")
      fallback = command_manager(tmp, command: [missing])
      workspace = allocate_workspace(fallback, project)
      assert workspace.fetch("created"), workspace.inspect
      assert_equal "native_git", workspace.fetch("worktree_provider")
      assert_match(/unavailable/, workspace.fetch("worktree_provider_fallback_reason"))

      strict = command_manager(File.join(tmp, "strict"), command: [missing], fallback: "none")
      failed = allocate_workspace(strict, project, task_title: "Strict provider")
      refute failed.fetch("created")
      assert_equal "external_provider_unavailable", failed.fetch("failure_kind")
      assert failed.fetch("errors").join.include?("fallback")
    end
  end

  def test_sparse_profile_uses_only_the_configured_pre_mutation_fallback
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      log = File.join(tmp, "profile.jsonl")
      script = write_provider_stub(tmp, destination_root: File.join(tmp, "profile-provider"),
                                   log: log, suffix: "profile")
      profile = Meringue::Workspace::Profile.new(name: "sparse", sparse_cone: true,
                                                  sparse_patterns: ["README.md"])

      fallback = command_manager(tmp, command: [RbConfig.ruby, script])
      workspace = fallback.allocate_worker_workspace(
        project_root: project.fetch("project_root"), project_id: "P1", issue_id: "P1-I1",
        agent_id: "P1-I1-W1", task_title: "Sparse fallback", profile: profile
      )
      assert workspace.fetch("created"), workspace.inspect
      assert_equal "native_git", workspace.fetch("worktree_provider")
      assert_match(/sparse patterns/, workspace.fetch("worktree_provider_fallback_reason"))
      assert_empty provider_calls(log, "provision")

      strict = command_manager(File.join(tmp, "strict-profile"), command: [RbConfig.ruby, script], fallback: "none")
      failed = strict.allocate_worker_workspace(
        project_root: project.fetch("project_root"), project_id: "P1", issue_id: "P1-I2",
        agent_id: "P1-I2-W1", task_title: "Sparse strict", profile: profile
      )
      refute failed.fetch("created")
      assert_equal "external_provider_unavailable", failed.fetch("failure_kind")
      assert_empty provider_calls(log, "provision")
    end
  end

  def test_unavailable_release_command_preserves_the_owned_worktree
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      script = write_provider_stub(tmp, destination_root: File.join(tmp, "release-provider"),
                                   log: File.join(tmp, "release.jsonl"), suffix: "release")
      manager = command_manager(tmp, command: [script])
      workspace = allocate_workspace(manager, project, task_title: "Conservative release")
      FileUtils.rm_f(script)

      cleanup = manager.cleanup_pruned_worker_workspace(workspace)
      assert_equal "failed", cleanup.fetch("status")
      assert_equal "external_provider_command_unavailable", cleanup.fetch("reason")
      assert Dir.exist?(workspace.fetch("worktree_root_path"))
      assert manager.validate_worker_workspace(workspace, agent_id: "P1-I1-W1").fetch("usable")
    end
  end

  def test_failed_or_invalid_provider_does_not_double_allocate
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      %w[fail invalid].each do |mode|
        root = File.join(tmp, mode)
        log = File.join(tmp, "#{mode}.jsonl")
        script = write_provider_stub(tmp, destination_root: root, log: log, mode: mode, suffix: mode)
        manager = command_manager(File.join(tmp, "manager-#{mode}"), command: [RbConfig.ruby, script])

        result = allocate_workspace(manager, project, task_title: "Provider #{mode}")
        refute result.fetch("created"), result.inspect
        assert_equal "external_provider_error", result.fetch("failure_kind")
        assert_empty Dir.glob(File.join(manager.root_path, "**", ".git"))
        if mode == "invalid"
          assert_equal 1, provider_calls(log, "release").length
          assert_empty Dir.glob(File.join(root, "*"))
        end
      end
    end
  end

  def test_restart_adopts_the_exact_reserved_branch_without_double_provisioning
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      log = File.join(tmp, "restart.jsonl")
      script = write_provider_stub(tmp, destination_root: File.join(tmp, "restart-provider"),
                                   log: log, suffix: "restart")
      command = [RbConfig.ruby, script]
      crashing = command_manager(tmp, command: command, manager_class: InterruptAfterProvisionManager)

      assert_raises(Interrupt) { allocate_workspace(crashing, project, task_title: "Restart provider") }
      restarted = command_manager(tmp, command: command)
      workspace = allocate_workspace(restarted, project, task_title: "Restart provider")

      assert workspace.fetch("created"), workspace.inspect
      assert workspace.fetch("adopted"), workspace.inspect
      provision = provider_calls(log, "provision")
      assert_equal 1, provision.length
      assert_equal option(provision.fetch(0), "--name"), workspace.fetch("worktree_provider_identifier")
      assert restarted.cleanup_pruned_worker_workspace(workspace).fetch("success")
    end
  end

  def test_command_provider_can_provision_from_a_bare_repository
    with_workspace_tmpdir do |tmp|
      source = create_git_project(tmp)
      bare = File.join(tmp, "source.git")
      run_git!(tmp, "clone", "--bare", source.fetch("project_root"), bare, env: source.fetch("git_env"))
      script = write_provider_stub(tmp, destination_root: File.join(tmp, "bare-provider"),
                                   log: File.join(tmp, "bare.jsonl"), suffix: "bare")
      manager = command_manager(tmp, command: [RbConfig.ruby, script])

      workspace = allocate_workspace(manager, source, task_title: "Bare provider", project_root: bare)
      assert workspace.fetch("created"), workspace.inspect
      assert_equal "command", workspace.fetch("worktree_provider")
      refute_equal bare, workspace.fetch("workspace_path")
      assert_equal workspace.fetch("workspace_branch"), current_branch(source, workspace.fetch("workspace_path"))
      assert manager.cleanup_pruned_worker_workspace(workspace).fetch("success")
    end
  end

  private

  def command_manager(root, command:, fallback: "native_git", manager_class: Meringue::Workspace::Manager)
    manager_class.new(
      root_path: File.join(root, "managed"),
      worktree_provider: "command",
      worktree_provider_fallback: fallback,
      worktree_provider_command: command,
      checkout_timeout: 15,
      checkout_stall_timeout: 15,
      cleanup_timeout: 15
    )
  end

  def allocate_workspace(manager, project, task_title: "Configured provider", project_root: nil)
    manager.allocate_worker_workspace(
      project_root: project_root || project.fetch("project_root"),
      project_id: "P1",
      issue_id: "P1-I1",
      agent_id: "P1-I1-W1",
      task_title: task_title
    )
  end

  def provider_calls(log, action)
    return [] unless File.file?(log)

    File.readlines(log, chomp: true).map { |line| JSON.parse(line) }.select { |argv| argv.first == action }
  end

  def option(argv, name)
    argv.fetch(argv.index(name) + 1)
  end

  def current_branch(project, path)
    git_output(project, path, "branch", "--show-current").strip
  end

  def worktree_record(project, path)
    output = git_output(project, project.fetch("project_root"), "worktree", "list", "--porcelain")
    records = []
    current = nil
    output.each_line(chomp: true) do |line|
      if line.start_with?("worktree ")
        records << current if current
        current = { "worktree" => line.delete_prefix("worktree ") }
      elsif current && !line.empty?
        key, value = line.split(" ", 2)
        current[key] = value || true
      end
    end
    records << current if current
    records.find { |record| File.expand_path(record.fetch("worktree")) == File.expand_path(path) }
  end

  def write_provider_stub(tmp, destination_root:, log:, retain_worktree: false, mode: "ok", suffix: "main")
    script = File.join(tmp, "provider-#{suffix}.rb")
    File.write(script, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      require "fileutils"
      File.open(#{log.inspect}, "a") { |file| file.puts(JSON.generate(ARGV)) }
      action = ARGV.shift
      options = {}
      ARGV.each_slice(2) { |key, value| options[key] = value }

      case action
      when "provision"
        if #{mode.inspect} == "fail"
          warn "provider refused provisioning"
          exit 23
        end
        destination = File.join(#{destination_root.inspect}, options.fetch("--name"))
        FileUtils.mkdir_p(File.dirname(destination))
        args = ["git", "-C", options.fetch("--git-root"), "worktree", "add"]
        args << "--force" if Dir.exist?(destination)
        args.concat([destination, options.fetch("--branch")])
        abort "git worktree add failed" unless system(*args, out: $stderr, err: $stderr)
        if #{mode.inspect} == "invalid"
          puts "not-json"
        else
          puts JSON.generate("identifier" => "private-slot")
        end
      when "release"
        if #{retain_worktree.inspect}
          root = options.fetch("--worktree-path")
          abort "detach failed" unless system("git", "-C", root, "checkout", "--detach", out: $stderr, err: $stderr)
          system("git", "-C", options.fetch("--git-root"), "branch", "-D", options.fetch("--branch"), out: $stderr, err: $stderr)
          puts JSON.generate("released" => true, "worktree_retained" => true, "branch_retained" => false)
        else
          abort "remove failed" unless system("git", "-C", options.fetch("--git-root"), "worktree", "remove", options.fetch("--worktree-path"), out: $stderr, err: $stderr)
          puts JSON.generate("released" => true, "worktree_retained" => false, "branch_retained" => true)
        end
      else
        abort "unexpected action: \#{action.inspect}"
      end
    RUBY
    FileUtils.chmod("+x", script)
    script
  end
end
