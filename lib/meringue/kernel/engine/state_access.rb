# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # The state document itself: loading and normalizing it, minting ids, appending logs, and
      # finding records.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def synchronized_state(&block)
        @state_mutex.synchronize { @state_lock.synchronize(&block) }
      end

      def active_harness_client(provider: nil)
        selected_provider = normalize_harness_provider(provider || active_harness_provider)
        @harness_client_provider&.call(selected_provider) || @harness_client
      end

      def active_head_runner(provider: nil)
        selected_provider = normalize_harness_provider(provider || active_harness_provider)
        @head_runner_provider&.call(selected_provider) || @head_runner
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end

      def normalized_state
        state = store.load
        ensure_state_shape!(state)
        state
      end

      def persist_normalized_state_if_changed
        synchronized_state do
          state = store.load
          before = JSON.generate(state)
          ensure_state_shape!(state)
          changed = JSON.generate(state) != before
          store.save(state) if changed
          changed
        end
      end

      def theme_names
        if defined?(Meringue::TUI::Style)
          Meringue::TUI::Style.colorschemes
        else
          %w[catppuccin gruvbox kanagawa meringue rose-pine tokyonight]
        end
      end

      def normalized_theme_name(theme)
        if defined?(Meringue::TUI::Style)
          Meringue::TUI::Style.normalize_colorscheme_name(theme)
        else
          theme.to_s.strip.downcase.tr("_", "-")
        end
      end

      def apply_tui_theme(theme)
        Meringue::TUI::Style.configure!(theme) if defined?(Meringue::TUI::Style)
      end

      def ensure_state_shape!(state)
        State::Models.ensure_state_shape!(state)
        state["schema_version"] ||= State::Models::SCHEMA_VERSION
        state["projects"] ||= []
        state["issues"] ||= []
        state["agents"] ||= []
        state["questions"] ||= []
        state["logs"] ||= []
        state["counters"] ||= {}
        state["counters"]["projects"] ||= max_numeric_suffix(state.fetch("projects"), /^P(\d+)$/)
        state["counters"]["heads"] ||= max_numeric_suffix(state.fetch("agents").select { |agent| agent["type"] == "head" }, /^H(\d+)$/)
        state["counters"]["questions"] ||= max_numeric_suffix(state.fetch("questions"), /^Q(\d+)$/)
        state["counters"]["goals"] ||= max_numeric_suffix(state.fetch("goals", []), Goals::Record::ID_PATTERN)
        state["counters"]["logs"] ||= max_numeric_suffix(state.fetch("logs"), /^L(\d+)$/)
        state["counters"]["issues_by_project"] ||= {}
        state["counters"]["workers_by_issue"] ||= {}
        state["metadata"] ||= {}
        state["metadata"]["created_at"] ||= timestamp
        state["metadata"]["updated_at"] ||= state["metadata"].fetch("created_at")
        shared_harness = state["metadata"]["active_harness"]
        head_harness = normalize_harness_provider(state["metadata"]["active_head_harness"] || shared_harness || @default_head_harness_provider)
        worker_harness = normalize_harness_provider(state["metadata"]["active_worker_harness"] || shared_harness || @default_worker_harness_provider)
        public_head = selectable_harness_provider?(head_harness) ? Meringue::Harness::Registry.public_provider_name(head_harness) : head_harness
        public_worker = selectable_harness_provider?(worker_harness) ? Meringue::Harness::Registry.public_provider_name(worker_harness) : worker_harness
        state["metadata"]["active_head_harness"] = public_head
        state["metadata"]["active_worker_harness"] = public_worker
        state["metadata"]["active_head_harness_label"] = Meringue::Harness::Registry.provider_label(head_harness) if selectable_harness_provider?(head_harness)
        state["metadata"]["active_worker_harness_label"] = Meringue::Harness::Registry.provider_label(worker_harness) if selectable_harness_provider?(worker_harness)
        # The shared key remains a worker-side compatibility fallback. Older
        # readers therefore retain their historical future-worker behavior.
        state["metadata"]["active_harness"] = public_worker
        state["metadata"]["active_harness_label"] = state["metadata"]["active_worker_harness_label"]
        state["metadata"]["harness_generation"] ||= 0
        # Published so the dashboard can mark a quiet worker without reaching for the config file
        # on every frame. The kernel owns the threshold; the panes only read it.
        state["metadata"]["quiet_worker_warning_seconds"] = quiet_worker_warning_seconds
        state["metadata"]["agent_session_defaults"] = configured_session_defaults
        # Harness model catalogs are fetched in the background, so state only
        # guarantees the container exists; an empty map means "not fetched yet".
        state["metadata"]["harness_model_catalogs"] = {} unless state["metadata"]["harness_model_catalogs"].is_a?(Hash)
      end

      def max_numeric_suffix(records, pattern)
        records.filter_map do |record|
          match = record.fetch("id", "").match(pattern)
          match && match[1].to_i
        end.max || 0
      end

      def next_head_id!(state)
        state.fetch("counters")["heads"] = state.fetch("counters").fetch("heads", 0).to_i + 1
        "H#{state.fetch("counters").fetch("heads")}"
      end

      def next_project_id!(state)
        state.fetch("counters")["projects"] = state.fetch("counters").fetch("projects", 0).to_i + 1
        "P#{state.fetch("counters").fetch("projects")}"
      end

      def next_issue_id!(state, project_id)
        counters = state.fetch("counters").fetch("issues_by_project")
        counters[project_id] ||= max_issue_number(state, project_id)
        counters[project_id] = counters.fetch(project_id).to_i + 1
        "#{project_id}-I#{counters.fetch(project_id)}"
      end

      def preview_worker_id(state, issue_id)
        counters = state.fetch("counters").fetch("workers_by_issue")
        next_number = (counters[issue_id] || max_worker_number(state, issue_id)).to_i + 1
        "#{issue_id}-W#{next_number}"
      end

      def next_worker_id!(state, issue_id)
        counters = state.fetch("counters").fetch("workers_by_issue")
        counters[issue_id] ||= max_worker_number(state, issue_id)
        counters[issue_id] = counters.fetch(issue_id).to_i + 1
        "#{issue_id}-W#{counters.fetch(issue_id)}"
      end

      def next_question_id!(state)
        state.fetch("counters")["questions"] = state.fetch("counters").fetch("questions", 0).to_i + 1
        "Q#{state.fetch("counters").fetch("questions")}"
      end

      def decrement_worker_counter!(state, issue_id)
        counters = state.fetch("counters").fetch("workers_by_issue")
        return unless counters[issue_id]

        counters[issue_id] = [counters.fetch(issue_id).to_i - 1, max_worker_number(state, issue_id)].max
      end

      def max_issue_number(state, project_id)
        max_numeric_suffix(state.fetch("issues").select { |issue| issue.fetch("project_id", nil) == project_id }, /^#{Regexp.escape(project_id)}-I(\d+)$/)
      end

      def max_worker_number(state, issue_id)
        max_numeric_suffix(state.fetch("agents").select { |agent| agent.fetch("issue_id", nil) == issue_id }, /^#{Regexp.escape(issue_id)}-W(\d+)$/)
      end

      def worker_pr_urls(last_assistant_text:, harness_events:)
        sources = [present_string(last_assistant_text)]
        Array(harness_events).each do |event|
          sources << serializable_text(event)
        end

        sources.compact.flat_map { |source| extract_pull_request_urls(source) }.uniq
      end

      def extract_pull_request_urls(text)
        text.to_s.scan(PULL_REQUEST_URL_PATTERN).map do |url|
          url.sub(/[.,;:]+\z/, "")
        end
      end

      def extract_linked_pull_request_urls(text)
        extract_pull_request_urls(text).map { |url| canonical_pull_request_url(url) }.uniq
      end

      def canonical_pull_request_url(url)
        cleaned = url.to_s.sub(/[.,;:]+\z/, "")
        match = cleaned.match(%r{\A(https?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+)})
        match ? match[1] : cleaned
      end

      def serializable_text(value)
        JSON.generate(value)
      rescue StandardError
        value.inspect
      end

      def append_harness_event_logs(state, agent, events)
        visible_events = Array(events).filter_map { |event| visible_harness_event(event) }
        return [] if visible_events.empty?

        log_ids = []
        visible_events.first(HARNESS_EVENT_LOG_LIMIT).each do |event|
          log_ids.concat(append_log(
            state,
            source_type: "harness",
            source_id: agent.fetch("id", nil),
            level: event.fetch("level"),
            message: harness_event_log_message(agent, event),
            details: event.fetch("details")
          ))
        end

        overflow_count = visible_events.length - HARNESS_EVENT_LOG_LIMIT
        if overflow_count.positive?
          log_ids.concat(append_log(
            state,
            source_type: "harness",
            source_id: agent.fetch("id", nil),
            level: "info",
            message: "#{agent.fetch("id", "Agent")} produced #{overflow_count} additional agent event#{overflow_count == 1 ? "" : "s"}.",
            details: {
              "omitted_event_count" => overflow_count,
              "event_types" => visible_events.drop(HARNESS_EVENT_LOG_LIMIT).map { |event| event.fetch("type") }.uniq
            }
          ))
        end

        log_ids
      end

      def visible_harness_event(event)
        return nil unless event.is_a?(Hash)

        event = stringify_keys(event)
        event_type = event.fetch("type", "event").to_s
        return nil if HARNESS_EVENT_IGNORED_TYPES.include?(event_type)
        return nil if internal_harness_event_type?(event_type)
        return nil unless event_type.match?(HARNESS_EVENT_LOG_PATTERN)

        details = compact_harness_event_details(event)
        {
          "type" => event_type,
          "label" => harness_event_label(event),
          "level" => harness_event_error?(event_type) ? "warning" : "info",
          "details" => details
        }
      end

      def internal_harness_event_type?(event_type)
        normalized_type = event_type.to_s
                                    .gsub(/([a-z])([A-Z])/, "\\1_\\2")
                                    .tr("-", "_")
                                    .downcase
        return true if %w[turn message tool_execution tool_call tool_result].include?(normalized_type)

        normalized_type.start_with?("turn_", "message_", "tool_execution_")
      end

      def compact_harness_event_details(event)
        details = {
          "event_type" => event.fetch("type", nil),
          "event_timestamp" => event.fetch("timestamp", nil),
          "tool_name" => harness_event_label(event),
          "status" => harness_event_first_present(event, "status", "state", "result"),
          "role" => event.dig("message", "role"),
          "id" => harness_event_first_present(event, "id", "event_id", "toolCallId", "tool_call_id")
        }.compact
        data = event.fetch("data", nil)
        details["data_type"] = data.fetch("type", nil) if data.is_a?(Hash)
        details["error"] = harness_event_first_present(event, "error", "error_message", "message") if harness_event_error?(event.fetch("type", ""))
        details
      end

      def harness_event_log_message(agent, event)
        label = present_string(event.fetch("label", nil))
        suffix = label ? ": #{label}" : ""
        "#{agent.fetch("id", "Agent")} agent session #{event.fetch("type")}#{suffix}."
      end

      def harness_event_error?(event_type)
        event_type.to_s.match?(/error|failed|failure|parse_error/i)
      end

      def harness_event_label(event)
        data = event.fetch("data", nil)
        data = {} unless data.is_a?(Hash)
        harness_event_first_present(
          event,
          "tool_name", "toolName", "tool", "name", "command", "function", "customType"
        ) || harness_event_first_present(
          data,
          "tool_name", "toolName", "tool", "name", "command", "function", "customType"
        )
      end

      def harness_event_first_present(hash, *keys)
        return nil unless hash.is_a?(Hash)

        keys.each do |key|
          value = hash[key] || hash[key.to_sym]
          next unless value.is_a?(String) || value.is_a?(Numeric) || value.is_a?(Symbol) || value == true || value == false

          normalized = present_string(value)
          return normalized if normalized
        end
        nil
      end

      # Harness-neutral progress for one poll, derived from the events this poll already drained.
      #
      # Never a second `read_events`: `ProcessClient::ManagedProcess` keeps one shared drain
      # cursor, so reading again for progress would take events away from settle classification.
      # It is also never allowed to break a reconcile pass, so an unsupported or misbehaving
      # client degrades to "no progress" rather than raising into the tick.
      def session_progress_items(agent, client, events)
        return [] unless agent.fetch("type", nil) == "worker"
        return [] unless client.respond_to?(:session_progress)

        Array(client.session_progress(events)).select { |item| item.is_a?(Hash) }
      rescue StandardError
        []
      end

      # Turns this poll's progress items into at most one durable log line for the worker.
      #
      # The newest observation is always recorded on the record (cheap, single field, no growth)
      # so `GetInfo` and the AgentTree can see current activity even while the log line is
      # throttled; only the throttled subset becomes a log entry.
      def record_worker_progress!(state, agent, progress_items, now)
        return [] unless agent.fetch("type", nil) == "worker"

        candidate = worker_progress_candidate(progress_items)
        return [] unless candidate

        metadata = agent.fetch("harness_metadata", nil)
        metadata = agent["harness_metadata"] = {} unless metadata.is_a?(Hash)
        previous = metadata.fetch("progress", nil)
        previous = {} unless previous.is_a?(Hash)

        progress = previous.merge(
          "kind" => candidate.fetch("kind"),
          "text" => candidate.fetch("text"),
          "observed_at" => now
        )
        metadata["progress"] = progress
        return [] unless worker_progress_log_due?(previous, candidate, now)

        metadata["progress"] = progress.merge(
          "logged_text" => candidate.fetch("text"),
          "logged_kind" => candidate.fetch("kind"),
          "logged_at" => now,
          "logged_count" => previous.fetch("logged_count", 0).to_i + 1
        )
        append_log(
          state,
          source_type: "worker",
          source_id: agent.fetch("id", nil),
          level: "info",
          message: candidate.fetch("text"),
          details: {
            "kind" => "worker_progress",
            "progress_kind" => candidate.fetch("kind"),
            "issue_id" => agent.fetch("issue_id", nil),
            "project_id" => agent.fetch("project_id", nil)
          }.compact
        )
      end

      # One poll can carry a whole burst of items; at most the newest authored update is logged.
      # Tool calls prove activity, but they do not explain progress and must not be synthesized
      # into a semantic-sounding status line.
      def worker_progress_candidate(progress_items)
        authored = Array(progress_items).reverse.find do |item|
          item.is_a?(Hash) &&
            item.fetch("kind", nil).to_s == "assistant_text" &&
            present_string(item.fetch("text", nil))
        end
        return nil unless authored

        text = worker_progress_text(authored.fetch("text"))
        text ? { "kind" => "assistant_text", "text" => text } : nil
      end

      def worker_progress_text(text)
        present_string(text.to_s.gsub(/\s+/, " "))
      end

      def worker_progress_log_due?(previous, candidate, now)
        last_text = previous.fetch("logged_text", nil).to_s
        # Re-observing the same sentence is not progress, whatever the clock says.
        return false if !last_text.empty? && last_text == candidate.fetch("text")

        last_logged_at = parse_time_or_nil(previous.fetch("logged_at", nil))
        # The first line a worker produces is never delayed: that is the one that proves the
        # session is alive. A logged_at Meringue cannot parse also fails open, so a hand-edited
        # record makes the worker chatty rather than silent.
        return true unless last_logged_at

        current = parse_time_or_nil(now)
        return true unless current

        (current - last_logged_at) >= WORKER_PROGRESS_LOG_INTERVAL_SECONDS
      end

      def stringify_keys(hash)
        hash.each_with_object({}) do |(key, value), result|
          result[key.to_s] = value.is_a?(Hash) ? stringify_keys(value) : value
        end
      end

      # Appends an independent event by default. A caller may instead provide a stable, namespaced
      # replacement key for an evolving status whose newest observation makes its predecessor
      # obsolete. Removal and append happen in the caller's state transaction: the replacement gets
      # a fresh monotonic id/timestamp at the end of the log, while unrelated entries keep their
      # relative order. Persisting the key on the entry makes replacement survive process restarts.
      def append_log(state, source_type:, source_id:, level:, message:, details: {}, replacement_key: nil)
        raise ArgumentError, "invalid log source_type: #{source_type}" unless State::Models::LOG_SOURCE_TYPES.include?(source_type)
        raise ArgumentError, "invalid log level: #{level}" unless State::Models::LOG_LEVELS.include?(level)

        log_details = details.is_a?(Hash) ? details.dup : {}
        author = current_head_command_log_author
        # `source_type` remains kernel: Meringue validated and applied the action. Authorship is
        # separate provenance, present only while a head journal command is executing.
        log_details.merge!(author) if source_type == "kernel" && author

        replacement_key = present_string(replacement_key)
        state.fetch("logs").delete_if do |entry|
          replacement_key && entry.is_a?(Hash) && entry.fetch("replacement_key", nil) == replacement_key
        end

        now = timestamp
        state.fetch("counters")["logs"] = state.fetch("counters").fetch("logs", 0).to_i + 1
        log_id = "L#{state.fetch("counters").fetch("logs")}"
        entry = {
          "id" => log_id,
          "timestamp" => now,
          "source_type" => source_type,
          "source_id" => source_id,
          "level" => level,
          "message" => message,
          "details" => log_details
        }
        entry["replacement_key"] = replacement_key if replacement_key
        state.fetch("logs") << entry
        [log_id]
      end

      def with_head_command_log_attribution(head_id)
        author_id = present_string(head_id)
        return yield unless author_id

        contexts = Thread.current.thread_variable_get(:meringue_command_log_authors)
        unless contexts.is_a?(Hash)
          contexts = {}
          Thread.current.thread_variable_set(:meringue_command_log_authors, contexts)
        end
        key = object_id
        previous = contexts[key]
        contexts[key] = head_command_author_details(author_id)
        begin
          yield
        ensure
          previous ? contexts[key] = previous : contexts.delete(key)
        end
      end

      def current_head_command_log_author
        contexts = Thread.current.thread_variable_get(:meringue_command_log_authors)
        contexts.is_a?(Hash) ? contexts[object_id] : nil
      end

      def head_command_author_details(head_id)
        {
          "command_author_type" => "head",
          "command_author_id" => head_id.to_s
        }
      end

      def touch_state!(state, now = timestamp)
        state.fetch("metadata")["updated_at"] = now
      end

      # Resolve a UI selection against the kernel's current snapshot. The input
      # layer intentionally sends only selected_id, so a worker/agent can never
      # smuggle an arbitrary issue id into head context. Issue selections target
      # themselves and worker selections resolve to their durable owning issue.
      # Heads are top-level log-only nodes: retrying one is an explicit RetryHead
      # command, not ambient chat routing context.
      def resolve_selected_head_target(state, requested_target)
        return [nil, nil] if requested_target.nil?

        selected_id = selected_target_id(requested_target)
        # A blank or shapeless selection carries no destination, so it means the
        # same thing as no selection: route the message normally instead of
        # rejecting it for an empty routing hint.
        return [nil, nil] if selected_id.nil?

        issue = find_issue(state, selected_id)
        agent = nil
        unless issue
          agent = find_agent(state, selected_id)
          unless agent
            return [nil, { "code" => "selected_target_not_found", "message" => "selected target #{selected_id} no longer exists." }]
          end

          return [nil, nil] if agent.fetch("type", nil) == "head"

          issue_id = present_string(agent.fetch("issue_id", nil))
          unless issue_id
            return [nil, { "code" => "selected_target_has_no_issue", "message" => "selected agent #{selected_id} does not own an issue." }]
          end

          issue = find_issue(state, issue_id)
          unless issue
            return [nil, { "code" => "selected_target_issue_not_found", "message" => "owning issue #{issue_id} for selected agent #{selected_id} no longer exists." }]
          end
        end

        if issue.fetch("status", nil) == "killed"
          return [nil, { "code" => "selected_target_issue_unavailable", "message" => "selected issue #{issue.fetch("id")} is no longer available." }]
        end

        project = find_project(state, issue.fetch("project_id", nil))
        unless project
          return [nil, { "code" => "selected_target_project_not_found", "message" => "project for selected issue #{issue.fetch("id")} no longer exists." }]
        end

        target = {
          "selected_id" => selected_id,
          "selected_type" => agent ? "agent" : "issue",
          "issue_id" => issue.fetch("id"),
          "project_id" => issue.fetch("project_id", nil),
          "issue_title" => issue.fetch("title", nil)
        }
        if agent
          metadata = agent.fetch("harness_metadata", {}) || {}
          target.merge!(
            "selected_agent_id" => agent.fetch("id"),
            "selected_agent_type" => agent.fetch("type", nil),
            "selected_agent_title" => metadata.fetch("title", nil)
          )
        end
        [target.compact, nil]
      end

      def selected_target_id(requested_target)
        selected_id = if requested_target.is_a?(Hash)
                        value_at(requested_target, "selected_id", "SelectedID", "selectedId", "id")
                      else
                        requested_target
                      end
        selected_id = selected_id.to_s.strip
        selected_id.empty? ? nil : selected_id
      end

      # Scalar ids make the selected prompt visible under both issue and exact
      # agent log scopes; the nested object preserves the complete audit context.
      def selected_target_log_details(selected_target)
        return {} unless selected_target.is_a?(Hash)

        {
          "selected_target" => deep_copy(selected_target),
          "selected_target_id" => selected_target.fetch("selected_id", nil),
          "selected_target_type" => selected_target.fetch("selected_type", nil),
          "project_id" => selected_target.fetch("project_id", nil),
          "issue_id" => selected_target.fetch("issue_id", nil),
          "agent_id" => selected_target.fetch("selected_agent_id", nil),
          "routing_action" => "selected_target"
        }.compact
      end

      # Ids reach the kernel from typed slash commands, head-proposed command payloads, and TUI
      # selections. Meringue ids are canonically uppercase, so an id that only differs by case is
      # resolved to its canonical record here as a defensive second layer for paths that do not go
      # through `apply`. Lookups still prefer an exact match, so nothing can shadow a real record.
      def find_project(state, project_id)
        Ids.find_record(state.fetch("projects"), project_id)
      end

      def find_issue(state, issue_id)
        Ids.find_record(state.fetch("issues"), issue_id)
      end

      def find_agent(state, agent_id)
        Ids.find_record(state.fetch("agents"), agent_id)
      end

      def find_session_agent(state, agent_id:, session_ref: nil)
        ref = session_ref.is_a?(Hash) ? session_ref : {}
        identities = [
          ["harness_session_id", value_at(ref, "session_id", "harness_session_id")],
          ["harness_session_file", value_at(ref, "session_file", "harness_session_file")],
          ["pid", value_at(ref, "pid")]
        ].select { |_key, value| present_string(value) }
        identities.each do |key, value|
          match = state.fetch("agents").find { |agent| agent.fetch(key, nil).to_s == value.to_s }
          return match if match
        end

        identities.empty? ? find_agent(state, agent_id) : nil
      end

      def find_question(state, question_id)
        Ids.find_record(state.fetch("questions"), question_id)
      end

      # Rewrites record ids in a command payload to their canonical uppercase spelling so state,
      # logs, and the head command journal never store `h83` for `H83`. This is the earliest point
      # where an id can be canonicalized without losing what its author typed: only an id that
      # already resolves to a record in state is recased, so an unknown or malformed id reaches
      # validation (and its rejection message) exactly as it was typed. State is loaded only when
      # the payload actually holds a non-canonical id.
      def canonicalize_payload_record_ids(payload)
        return payload unless Ids.payload_needs_canonicalization?(payload)

        state = synchronized_state { normalized_state }
        Ids.canonicalize_payload(payload, state)
      rescue StandardError
        payload
      end

      def normalize_command(command)
        case command
        when Command
          {
            "command_id" => nil,
            "type" => command.type,
            "payload" => command.payload || {}
          }
        when Hash
          {
            "command_id" => value_at(command, "command_id", "id"),
            "type" => value_at(command, "type", "command_type"),
            "payload" => value_at(command, "payload") || {}
          }
        else
          {
            "command_id" => nil,
            "type" => nil,
            "payload" => {}
          }
        end
      end

      def canonical_command_type(command_type)
        text = command_type.to_s
        COMMAND_ALIASES.fetch(text, text)
      end

      def interactive_focus_context(state, agent)
        issue = find_issue(state, agent.fetch("issue_id", nil))
        {
          "agent_id" => agent.fetch("id", nil),
          "issue_id" => agent.fetch("issue_id", nil),
          "issue_title" => issue&.fetch("title", nil),
          "issue_description" => issue&.fetch("description", nil),
          "assignment" => agent.dig("harness_metadata", "spawn_prompt"),
          "workspace_path" => agent.fetch("workspace_path", nil),
          "workspace_branch" => agent.fetch("workspace_branch", nil),
          "session_id" => agent.fetch("harness_session_id", nil),
          "session_file" => agent.fetch("harness_session_file", nil)
        }.compact.transform_values do |value|
          value.is_a?(String) ? value.byteslice(0, 8_000).to_s.scrub : value
        end
      end

      def agent_session_ref(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        {
          "harness" => agent.fetch("harness", nil),
          "pid" => agent.fetch("pid", nil),
          "cwd" => metadata.fetch("cwd", agent.fetch("workspace_path", nil)),
          "session_id" => agent.fetch("harness_session_id", nil),
          "session_file" => agent.fetch("harness_session_file", nil),
          "is_streaming" => metadata.fetch("is_streaming", false),
          "last_event_at" => metadata.fetch("last_event_at", nil),
          "session_settings" => agent.fetch("session_settings", nil),
          "metadata" => metadata.merge("kind" => metadata.fetch("kind", agent.fetch("type", nil)))
        }
      end
    end
  end
end
