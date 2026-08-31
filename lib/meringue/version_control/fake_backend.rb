# frozen_string_literal: true

module Meringue
  module VersionControl
    # Deterministic stand-in for the Git + GitHub backend, in the same spirit as
    # `Harness::FakeClient` and `Heads::FakeRunner`.
    #
    # Registration asks a backend to prove that a project can host isolated mutable
    # workspaces, and the built-in backend proves it by finding a Git repository with a
    # usable base ref (a forge remote is optional). That is the right bar for a real
    # project and the wrong one for a test about issues, workers, heads, or goals: those
    # fixtures are directories, and making each of them a repository would buy nothing
    # but git subprocesses. This answers the capability probe from a fixture's own
    # configuration instead, and leaves everything that actually touches a worktree to
    # the real workspace manager, so the code under test is unchanged.
    #
    # Tests that are about the probe itself use the real backend against a real
    # repository; see `test/integration/workspace/`.
    class FakeBackend < GitHubGitBackend
      DEFAULT_REPOSITORY_IDENTITY = "git@github.com:example/fixture.git"

      attr_reader :probes

      # `isolated: false` models a backend that refuses the project, which is how a
      # registration rejection is exercised without arranging a broken repository.
      def initialize(manager: nil, isolated: true, repository_identity: DEFAULT_REPOSITORY_IDENTITY, diagnostics: nil)
        super(manager: manager)
        @isolated = isolated
        @repository_identity = repository_identity
        @diagnostics = diagnostics
        @probes = []
      end

      def isolated? = @isolated

      def inspect_project(root_path:)
        @probes << root_path.to_s
        {
          "available" => @isolated,
          "backend" => id,
          "repository_identity" => @isolated ? @repository_identity : root_path.to_s,
          "capabilities" => {
            "isolated_workspaces" => @isolated,
            "mutable_workspace" => @isolated,
            "shared_read_only_workspace" => true,
            "delivery" => @isolated
          },
          "diagnostics" => @diagnostics || (@isolated ? [] : ["not_a_git_repository"]),
          "diagnostic_at" => Time.now.utc.iso8601
        }
      end
    end
  end
end
