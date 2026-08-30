# frozen_string_literal: true

module Meringue
  # Everything the quick start used to ask a new user to verify by hand.
  #
  # README step 1 was "run `git --version`, `ruby --version`, `bundle --version`
  # and check them yourself", and its troubleshooting section carried the fixes
  # for each way that could go wrong. Nothing in the product checked any of it,
  # so a missing harness surfaced much later as a raw StartError in the middle of
  # a session. This asks the same questions the product actually depends on and
  # answers each failure with the fix.
  #
  # Every check is read-only and bounded. Nothing here writes config or state.
  class Doctor
    OK = "ok"
    PROBLEM = "problem"
    NOTE = "note"

    MINIMUM_RUBY = "3.1"

    Check = Struct.new(:status, :title, :detail, :fix, keyword_init: true) do
      def ok? = status == OK
      def problem? = status == PROBLEM
    end

    def initialize(config:, config_path:, state_path:, registry: nil, cwd: Dir.pwd, ruby_version: RUBY_VERSION)
      @config = config
      @config_path = config_path
      @state_path = state_path
      @registry = registry
      @cwd = cwd
      @ruby_version = ruby_version
    end

    def checks
      [
        ruby_check,
        git_check,
        *harness_checks,
        config_check,
        state_check,
        github_cli_check,
        version_control_check,
        repository_check
      ].compact
    end

    def problems
      checks.select(&:problem?)
    end

    private

    attr_reader :config, :config_path, :state_path, :registry, :cwd, :ruby_version

    def ruby_check
      if Gem::Version.new(ruby_version) >= Gem::Version.new(MINIMUM_RUBY)
        ok("Ruby #{ruby_version}")
      else
        problem(
          "Ruby #{ruby_version} is too old",
          detail: "Meringue needs #{MINIMUM_RUBY} or newer.",
          fix: "Install a newer Ruby (rbenv, asdf, or your package manager) and re-run from it."
        )
      end
    end

    def git_check
      located = Harness::Availability.locate(["git"])
      return ok("Git at #{located.fetch("path")}") if Harness::Availability.installed?(located)

      problem(
        "Git was not found",
        detail: "Workers run in dedicated git worktrees, so Meringue cannot allocate a workspace without it.",
        fix: "Install git and make sure it is on PATH."
      )
    end

    # `gh` is only ever launched by the GitHub-support experiment, so it is only asked
    # about when that is on. Reporting a missing gh to someone working locally would be
    # reporting a tool they were never going to run.
    def github_cli_check
      return nil unless github_support_enabled?

      located = Harness::Availability.locate(["gh"])
      return ok("GitHub CLI at #{located.fetch("path")}") if Harness::Availability.installed?(located)

      problem(
        "GitHub CLI was not found",
        detail: "GitHub support looks up pull request titles and states with gh.",
        fix: "Install the GitHub CLI and run gh auth login, or turn GitHub support off in /config."
      )
    end

    def github_support_enabled?
      config.experiment_enabled?("github_support")
    rescue StandardError
      false
    end

    # The harness is the one thing Meringue cannot run without, so it is checked
    # the way the launcher resolves it rather than by looking for a command name.
    def harness_checks
      return [harness_unconfigured] unless registry

      head = configured_provider("head")
      worker = configured_provider("worker")
      # One backend for both roles is the normal case, and reporting it twice
      # says nothing the first row did not.
      return [harness_check(head, "Harness")] if head && head == worker

      [
        head ? harness_check(head, "Head harness") : harness_unconfigured("head"),
        worker ? harness_check(worker, "Worker harness") : harness_unconfigured("worker")
      ]
    end

    def harness_check(provider, subject)
      located = registry.availability_for(provider)
      label = Harness::Registry.provider_label(provider)
      return ok("#{subject}: #{label}", detail: located["path"]) if Harness::Availability.installed?(located)

      problem(
        "#{subject}: #{label} was not found",
        detail: "Configured command: #{registry.provider_command(provider)}",
        fix: "Install it, put it on PATH, or set its absolute path under [harness.#{provider}] command."
      )
    end

    def harness_unconfigured(role = nil)
      subject = role ? "#{role.capitalize} harness" : "Agent harness"
      problem(
        "#{subject} is not configured",
        detail: "Meringue is harness-agnostic and never guesses a backend.",
        fix: "Run meringue and choose one in first-run setup, or set [harness] head_provider and worker_provider in #{config_path}."
      )
    end

    def configured_provider(role)
      value = config.setting("agent.#{role}_harness")
      value.to_s.strip.empty? ? nil : Harness::Registry.normalize_provider!(value)
    rescue StandardError
      nil
    end

    def config_check
      return ok("Config #{abbreviate(config_path)} (not created yet — defaults apply)") unless File.exist?(config_path)
      return problem("Config #{abbreviate(config_path)} is not readable", fix: "Check its permissions.") unless File.readable?(config_path)

      Config.load(path: config_path)
      ok("Config #{abbreviate(config_path)}")
    rescue Config::ParseError => e
      problem(
        "Config #{abbreviate(config_path)} could not be parsed",
        detail: e.message,
        fix: "Fix the TOML, or move the file aside to start from defaults."
      )
    end

    def state_check
      return ok("State #{abbreviate(state_path)} (not created yet)") unless File.exist?(state_path)
      return problem("State #{abbreviate(state_path)} is not readable", fix: "Check its permissions.") unless File.readable?(state_path)

      JSON.parse(File.read(state_path))
      ok("State #{abbreviate(state_path)}")
    rescue JSON::ParserError => e
      # Meringue already quarantines an unreadable state file and starts empty,
      # so this is a warning about losing history rather than a blocker.
      note(
        "State #{abbreviate(state_path)} is not valid JSON",
        detail: e.message,
        fix: "Meringue will move it aside and start from an empty state on the next launch."
      )
    end

    def version_control_check
      manager = Workspace::Manager.from_config(config)
      backend = VersionControl::GitHubGitBackend.new(manager: manager)
      root = ProjectNaming.git_root_for(cwd) || cwd
      capability = backend.inspect_project(root_path: root)
      return ok("Version control: isolated mutable workspaces ready", detail: capability["repository_identity"]) if capability["available"] == true

      problem(
        "Version control: isolated mutable workspaces unavailable",
        detail: Array(capability["diagnostics"]).join(", "),
        fix: "Use a GitHub repository with a usable base branch, or configure an alternate version-control backend."
      )
    end

    def repository_check
      root = ProjectNaming.git_root_for(cwd)
      return ok("Repository #{abbreviate(root)}") if root

      note(
        "Not inside a git repository",
        detail: "Workers need a checkout to branch from, and setup offers to register the directory it starts in.",
        fix: "Run Meringue from a repository, or register one later with /project add <path>."
      )
    end

    def abbreviate(path)
      home = File.expand_path("~")
      value = path.to_s
      value.start_with?("#{home}/") ? "~#{value[home.length..]}" : value
    rescue StandardError
      path.to_s
    end

    def ok(title, detail: nil)
      Check.new(status: OK, title: title, detail: detail)
    end

    def problem(title, detail: nil, fix: nil)
      Check.new(status: PROBLEM, title: title, detail: detail, fix: fix)
    end

    def note(title, detail: nil, fix: nil)
      Check.new(status: NOTE, title: title, detail: detail, fix: fix)
    end
  end
end
