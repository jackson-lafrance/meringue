# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require "uri"

module Meringue
  module Workers
    # A deliberately small, harness-neutral transfer format for retrying workers on another
    # machine. This is an allowlist, not a serialization of an agent or the state file: process
    # handles, session transcripts, paths, and transport metadata are not portable and are never
    # copied into a bundle.
    module Bundle
      FORMAT = "meringue-worker-bundle"
      VERSION = 1
      EXPORTABLE_STATUSES = %w[queued working idle blocked paused errored supervision_lost].freeze
      SECRET_TEXT_PATTERNS = [
        /(authorization\s*[:=]\s*bearer\s+)[^\s,;]+/i,
        /((?:api[_-]?key|access[_-]?token|auth[_-]?token|token|password|passwd|secret)\s*[:=]\s*["']?)[^\s,"']+/i,
        %r{(https?://)([^/\s:@]+):([^@/\s]+)@}i
      ].freeze
      PORTABLE_SESSION_REASON = "Harness sessions are machine-local and cannot be resumed directly from a portable worker bundle."
      SENSITIVE_CONTENT_WARNING = "Prompt and report text can contain user-provided sensitive content; inspect the bundle before transferring it."

      module_function

      def export(state, worker_ids: [], exported_at: Time.now.utc.iso8601)
        state = state.is_a?(Hash) ? state : {}
        agents = Array(state["agents"]).select { |agent| agent.is_a?(Hash) && agent["type"].to_s == "worker" }
        selected_ids = Array(worker_ids).map { |id| id.to_s }.reject(&:empty?)
        selected = if selected_ids.empty?
                     agents.select { |agent| EXPORTABLE_STATUSES.include?(agent["status"].to_s) }
                   else
                     selected_ids.map do |requested_id|
                       agent = agents.find { |candidate| candidate["id"].to_s.casecmp?(requested_id) }
                       raise ArgumentError, "Worker #{requested_id} does not exist." unless agent
                       raise ArgumentError, "Worker #{agent.fetch("id")} is #{agent.fetch("status")}; only current workers can be exported." unless EXPORTABLE_STATUSES.include?(agent["status"].to_s)

                       agent
                     end.uniq
                   end
        raise ArgumentError, "No current workers are available to export." if selected.empty?

        warnings = [PORTABLE_SESSION_REASON, SENSITIVE_CONTENT_WARNING]
        entries = selected.map do |agent|
          build_worker_entry(state, agent, warnings: warnings)
        end
        bundle = {
          "format" => FORMAT,
          "version" => VERSION,
          "exported_at" => exported_at.to_s,
          "warnings" => warnings.uniq,
          "workers" => entries
        }
        # Keep the identity stable when the same state is exported again later; the timestamp is
        # provenance only and must not make a retry duplicate on the destination.
        bundle["bundle_id"] = Digest::SHA256.hexdigest(JSON.generate(entries))[0, 24]
        bundle
      end

      def write(path, bundle)
        validate!(bundle)
        destination = File.expand_path(path.to_s)
        raise ArgumentError, "Bundle path is required." if path.to_s.strip.empty?

        FileUtils.mkdir_p(File.dirname(destination))
        temporary = "#{destination}.tmp.#{$$}.#{Thread.current.object_id}"
        File.write(temporary, JSON.pretty_generate(bundle) + "\n")
        File.rename(temporary, destination)
        destination
      rescue SystemCallError => e
        raise ArgumentError, "Could not write worker bundle #{path}: #{e.message}"
      ensure
        File.delete(temporary) if temporary && File.exist?(temporary)
      end

      def read(path)
        source = path.to_s.strip
        raise ArgumentError, "Bundle path is required." if source.empty?

        parsed = JSON.parse(File.read(File.expand_path(source)))
        validate!(parsed)
      rescue Errno::ENOENT
        raise ArgumentError, "Worker bundle #{path} does not exist."
      rescue JSON::ParserError => e
        raise ArgumentError, "Worker bundle is not valid JSON: #{e.message}"
      rescue SystemCallError => e
        raise ArgumentError, "Could not read worker bundle #{path}: #{e.message}"
      end

      def validate!(bundle)
        unless bundle.is_a?(Hash) && bundle["format"] == FORMAT && bundle["version"].to_i == VERSION
          raise ArgumentError, "Unsupported worker bundle; expected #{FORMAT} version #{VERSION}."
        end
        workers = bundle["workers"]
        raise ArgumentError, "Worker bundle has no workers." unless workers.is_a?(Array) && !workers.empty?
        workers.each do |worker|
          valid = worker.is_a?(Hash) && present?(worker["source_worker_id"]) &&
                  worker["issue"].is_a?(Hash) && present?(worker.dig("issue", "source_id")) &&
                  worker["project"].is_a?(Hash) && present?(worker.dig("project", "source_id")) &&
                  worker["prompts"].is_a?(Hash) && worker["session"].is_a?(Hash)
          raise ArgumentError, "Worker bundle contains an incomplete worker record." unless valid
        end
        bundle
      end

      # Build the prompt used for a fresh destination session. It says what happened to the old
      # session instead of suggesting that an opaque session id can be reattached on this machine.
      def retry_prompt(worker, destination_project_path: nil)
        validate_worker_entry!(worker)
        project = worker.fetch("project")
        issue = worker.fetch("issue")
        assignment = worker.dig("prompts", "initial").to_s
        previous_report = worker.dig("prompts", "last_report").to_s
        pending = Array(worker.dig("prompts", "pending"))
        delivery = worker.fetch("delivery", {}) || {}
        lines = [
          "Retry a worker transferred from another computer.",
          "",
          "The original harness session cannot be resumed directly: #{PORTABLE_SESSION_REASON.downcase}",
          "Start this as a fresh session in the destination workspace and inspect the current checkout before changing files.",
          "",
          "Project: #{project.fetch("name", "(unnamed project)")}",
          "Issue: #{issue.fetch("title", "(untitled issue)")}",
          issue["description"].to_s.strip.empty? ? nil : "Issue description:\n#{issue.fetch("description")}",
          issue["parent"].is_a?(Hash) ? "Parent issue context: #{issue.dig("parent", "title")}\n#{issue.dig("parent", "description")}" : nil,
          worker["status_reason"].to_s.strip.empty? ? nil : "Source worker status (not a claim about this new session): #{worker.fetch("source_status", "unknown")} — #{worker.fetch("status_reason")}",
          destination_project_path.to_s.strip.empty? ? nil : "Destination project path was selected by the user; do not infer or restore the source machine's path.",
          "",
          "Original worker assignment:",
          assignment.empty? ? "(no assignment text was recorded)" : assignment
        ].compact

        unless previous_report.empty?
          lines.concat(["", "Last recorded worker report:", previous_report])
        end
        unless pending.empty?
          lines.concat(["", "Queued follow-up instructions from the source worker:", *pending.map { |entry| "- #{entry.fetch("prompt", "")}" }])
        end
        if delivery.any?
          lines.concat(["", "Delivery context from the source worker:"])
          lines << "- Previous delivery branch: #{delivery.fetch("branch")}" if present?(delivery["branch"])
          urls = Array(delivery["pull_requests"]).filter_map { |record| record.is_a?(Hash) ? record["url"] : nil }
          lines.concat(urls.map { |url| "- Pull request: #{url}" }) unless urls.empty?
        end
        lines.concat([
          "",
          "The source workspace path, process id, session id, and session file were intentionally not transferred. Use the destination workspace allocated by Meringue.",
          "Continue or retry the issue now; do not claim that the source harness session was resumed."
        ])
        lines.join("\n")
      end

      def build_worker_entry(state, agent, warnings:)
        metadata = agent["harness_metadata"].is_a?(Hash) ? agent["harness_metadata"] : {}
        issue = Array(state["issues"]).find { |candidate| candidate.is_a?(Hash) && candidate["id"].to_s == agent["issue_id"].to_s } || {}
        project = Array(state["projects"]).find { |candidate| candidate.is_a?(Hash) && candidate["id"].to_s == agent["project_id"].to_s } || {}
        unless present?(issue["id"]) && present?(project["id"])
          raise ArgumentError, "Worker #{agent.fetch("id")} is missing its project or issue context."
        end
        scrubbed = []
        scrub = lambda do |value|
          text = redact_text(value)
          scrubbed << true if text != value.to_s
          text
        end

        initial = scrub.call(metadata["spawn_prompt"])
        pending = Array(metadata["pending_prompts"]).filter_map do |entry|
          next unless entry.is_a?(Hash)
          prompt = entry["prompt"] || entry["message"]
          next if prompt.to_s.strip.empty?

          {
            "prompt" => scrub.call(prompt),
            "mode" => entry["mode"].to_s.empty? ? "normal" : entry["mode"].to_s,
            "queued_at" => entry["queued_at"]
          }.compact
        end
        report = scrub.call(metadata["last_assistant_text"])
        warnings << "Credential-shaped text was redacted from one or more worker fields." if scrubbed.any?

        issue_context = {
          "source_id" => issue["id"].to_s,
          "title" => scrub.call(issue["title"]),
          "description" => scrub.call(issue["description"])
        }
        parent = Array(state["issues"]).find { |candidate| candidate.is_a?(Hash) && candidate["id"].to_s == issue["parent_issue_id"].to_s }
        if parent
          issue_context["parent"] = {
            "source_id" => parent["id"].to_s,
            "title" => scrub.call(parent["title"]),
            "description" => scrub.call(parent["description"])
          }
        end

        delivery = delivery_context(issue, agent, metadata, scrub: scrub)
        {
          "source_worker_id" => agent["id"].to_s,
          "source_status" => agent["status"].to_s,
          "status_reason" => scrub.call(
            metadata.dig("settle_failure", "reason") || metadata["status_reason"] || metadata["error_message"]
          ),
          "title" => scrub.call(metadata["title"] || issue["title"]),
          "harness" => agent["harness"].to_s,
          "session_settings" => portable_session_settings(agent["session_settings"]),
          "project" => {
            "source_id" => project["id"].to_s,
            "name" => scrub.call(project["name"])
          },
          "issue" => issue_context,
          "prompts" => {
            "initial" => initial,
            "pending" => pending,
            "last_report" => report
          },
          "session" => {
            "resume_available" => false,
            "reason" => PORTABLE_SESSION_REASON
          },
          "workspace" => {
            "branch" => scrub.call(agent["workspace_branch"] || metadata["delivery_branch"]),
            "strategy" => agent["workspace_strategy"].to_s,
            "mode" => agent["effective_workspace_mode"].to_s.empty? ? agent["workspace_mode"].to_s : agent["effective_workspace_mode"].to_s
          }.compact,
          "lineage" => {
            "follow_up_of_source_worker_id" => agent["follow_up_of_agent_id"],
            "replaces_source_worker_id" => agent["replaces_agent_id"],
            "after_source_worker_id" => agent["after_agent_id"]
          }.compact,
          "delivery" => delivery
        }.compact
      end

      def delivery_context(issue, agent, metadata, scrub: lambda { |value| redact_text(value) })
        records = State::Models.pull_request_records_from(issue)
        records = State::Models.merge_pull_request_records(records).filter_map do |record|
          url = scrub.call(State::Models.pull_request_record_url(record))
          next if url.empty?

          {
            "url" => safe_public_url(url),
            "number" => record["number"],
            "title" => scrub.call(record["title"]),
            "state" => record["state"],
            "repository" => scrub.call(record["repository"] || record["base_repository"]),
            "head_branch" => scrub.call(record["head_branch"] || record["head_ref"])
          }.compact
        end.uniq { |record| record.fetch("url") }
        candidate_urls = Array(issue["candidate_pr_urls"]).filter_map { |url| safe_public_url(scrub.call(url)) }.uniq
        reported_urls = Array(issue["reported_pr_urls"]).filter_map { |url| safe_public_url(scrub.call(url)) }.uniq
        {
          "branch" => scrub.call(agent["workspace_branch"] || metadata["delivery_branch"]),
          "pull_requests" => records,
          "candidate_urls" => candidate_urls,
          "reported_urls" => reported_urls
        }.compact
      end

      def validate_worker_entry!(worker)
        validate!({ "format" => FORMAT, "version" => VERSION, "workers" => [worker] })
      end

      def portable_session_settings(settings)
        return {} unless settings.is_a?(Hash)

        model = settings["model"] || settings[:model]
        model = model["reference"] || model[:reference] if model.is_a?(Hash)
        {
          "model" => model.to_s.empty? ? nil : model.to_s,
          "thinking_level" => (settings["thinking_level"] || settings[:thinking_level]).to_s.empty? ? nil : (settings["thinking_level"] || settings[:thinking_level]).to_s
        }.compact
      end

      def redact_text(value)
        text = value.to_s
        SECRET_TEXT_PATTERNS.reduce(text) do |result, pattern|
          result.gsub(pattern) do
            match = Regexp.last_match
            if pattern.source.include?("https?://")
              "#{match[1]}[REDACTED]:[REDACTED]@"
            else
              "#{match[1]}[REDACTED]"
            end
          end
        end
      end

      def safe_public_url(value)
        text = value.to_s.strip
        return text unless text.match?(/\Ahttps?:\/\//i)

        uri = URI.parse(text)
        uri.user = nil
        uri.password = nil
        uri.query = nil
        uri.fragment = nil
        uri.to_s
      rescue URI::InvalidURIError
        text.split(/[?#]/, 2).first
      end

      def present?(value)
        !value.to_s.strip.empty?
      end
    end
  end
end
