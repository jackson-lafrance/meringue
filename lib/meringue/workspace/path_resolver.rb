# frozen_string_literal: true

module Meringue
  module Workspace
    # Single place that decides which directory a UI-owned shell or editor should
    # start in for a selected worker.
    #
    # Every candidate is turned into an absolute path before it is used. Relative
    # values are resolved against the worker's recorded project/git root, never
    # against the Meringue process working directory: resolving a workspace-
    # relative value against a cwd that is already inside a workspace is what
    # produces nested paths such as
    # `~/.meringue/workspaces/<project>/<task>/.meringue/workspaces/<project>/<task>`.
    module PathResolver
      # Ordered so the worker's real working directory wins, with the worktree
      # root as the self-healing fallback when that directory is gone.
      def self.resolve(agent_or_path)
        return resolve_path(agent_or_path) unless agent_or_path.is_a?(Hash)

        agent = agent_or_path
        candidates = candidate_paths(agent)
        return unavailable(nil) if candidates.empty?

        base = base_directory(agent)
        expanded = candidates.map { |candidate| absolute_path(candidate, base: base) }.uniq
        usable = expanded.find { |path| Dir.exist?(path) }
        return usable_result(usable, expanded.first) if usable

        unavailable(expanded.first)
      end

      # Convenience wrapper for callers that only need a directory or nil.
      def self.path_for(agent_or_path)
        resolve(agent_or_path).fetch("path", nil)
      end

      def self.candidate_paths(agent)
        metadata = hash_at(agent, "harness_metadata")
        plan = hash_at(metadata, "workspace_plan")
        [
          agent["workspace_path"],
          metadata["cwd"],
          plan["workspace_path"],
          agent["workspace_root_path"],
          plan["workspace_root_path"],
          plan["worktree_root_path"]
        ].map { |value| value.to_s.strip }.reject(&:empty?)
      end
      private_class_method :candidate_paths

      # Bases are only used for relative candidates. Project/git roots come from
      # the kernel-recorded workspace plan, so they stay stable across Meringue
      # instances and across different launch directories.
      def self.base_directory(agent)
        metadata = hash_at(agent, "harness_metadata")
        plan = hash_at(metadata, "workspace_plan")
        candidate = [plan["project_root"], plan["git_root"], metadata["project_root"]]
                    .map { |value| value.to_s.strip }
                    .find { |value| !value.empty? && value.start_with?(File::SEPARATOR, "~") }
        candidate ? File.expand_path(candidate) : Dir.home
      rescue ArgumentError
        File::SEPARATOR
      end
      private_class_method :base_directory

      def self.absolute_path(value, base:)
        text = value.to_s.strip
        return File.expand_path(text) if text.start_with?(File::SEPARATOR, "~")

        File.expand_path(text, base)
      rescue ArgumentError
        File.expand_path(text, File::SEPARATOR)
      end
      private_class_method :absolute_path

      def self.resolve_path(value)
        text = value.to_s.strip
        return unavailable(nil) if text.empty?

        path = absolute_path(text, base: Dir.home)
        Dir.exist?(path) ? usable_result(path, path) : unavailable(path)
      end
      private_class_method :resolve_path

      def self.usable_result(path, expected_path)
        {
          "path" => path,
          "expected_path" => expected_path,
          "recovered" => path != expected_path,
          "message" => path == expected_path ? nil : "Using #{path} because the recorded workspace #{expected_path} is missing."
        }.compact
      end
      private_class_method :usable_result

      def self.unavailable(expected_path)
        message = if expected_path
                    "Worker worktree #{expected_path} is missing. Its git worktree was removed or moved, " \
                      "so Meringue cannot open a shell there. Recreate the worktree, or open the delivery PR instead."
                  else
                    "This worker has no assigned workspace directory, so Meringue cannot open a shell for it."
                  end
        { "path" => nil, "expected_path" => expected_path, "message" => message }.compact
      end
      private_class_method :unavailable

      def self.hash_at(source, key)
        value = source.is_a?(Hash) ? source.fetch(key, nil) : nil
        value.is_a?(Hash) ? value : {}
      end
      private_class_method :hash_at
    end
  end
end
