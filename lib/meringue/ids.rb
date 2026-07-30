# frozen_string_literal: true

module Meringue
  # Meringue record ids are canonically uppercase (P1, P1-I23, P1-I23-W1, H83, Q8), but people
  # type them in whatever case is convenient and head agents echo them back the same way. This
  # module is the single place that understands that shape, so ids can be compared and
  # canonicalized without case-folding anything else: filesystem paths, git branch names, model
  # references, theme/harness names, and harness session ids all stay byte-exact.
  #
  # Canonicalization is deliberately conservative. Only a string shaped exactly like a Meringue id
  # is ever recased, and payload canonicalization only rewrites an id that already resolves to a
  # record in state. An unknown or malformed id therefore keeps the text its author typed and is
  # still rejected by the command that received it.
  module Ids
    PROJECT_PATTERN = /\AP\d+\z/i
    ISSUE_PATTERN = /\AP\d+-I\d+\z/i
    WORKER_PATTERN = /\AP\d+-I\d+-W\d+\z/i
    HEAD_PATTERN = /\AH\d+\z/i
    QUESTION_PATTERN = /\AQ\d+\z/i
    LOG_PATTERN = /\AL\d+\z/i

    # "Is this string shaped like a Meringue record id?"
    RECORD_ID_PATTERN = /\A(?:P\d+(?:-I\d+(?:-W\d+)?)?|H\d+|Q\d+|L\d+)\z/i
    # The same shapes, unanchored, for pulling ids out of prose such as a user message.
    RECORD_ID_SCAN_PATTERN = /\b(?:P\d+(?:-I\d+(?:-W\d+)?)?|H\d+|Q\d+)\b/i

    # State sections that hold record ids. Id shapes are disjoint across sections, so scanning
    # them in order cannot resolve one id to two different kinds of record.
    RECORD_SECTIONS = %w[agents issues projects questions].freeze

    # Payload keys that carry a user- or head-supplied Meringue record id, in every spelling the
    # kernel accepts. Keys that must stay case-sensitive (path, model, theme, provider, level,
    # branch, session ids) are intentionally absent.
    ID_PAYLOAD_KEYS = %w[
      id
      target_id TargetID targetId
      agent_id AgentID agentId
      issue_id IssueID issueId
      project_id ProjectID projectId
      question_id QuestionID questionId
      head_id HeadID headId _head_id
      parent_issue_id ParentIssueID parentIssueId
      follow_up_of_agent_id FollowUpOfAgentID followUpOfAgentID followUpOfAgentId
      replace_agent_id ReplaceAgentID replaceAgentID replaceAgentId
      originating_head_id OriginatingHeadID originatingHeadId
      _rerouted_from_issue_id rerouted_from_issue_id
    ].freeze

    # Payload keys whose value is a nested hash that itself carries a selected record id.
    NESTED_ID_PAYLOAD_KEYS = %w[selected_target SelectedTarget selectedTarget].freeze
    NESTED_ID_KEYS = %w[
      selected_id SelectedID selectedId id
      selected_agent_id selectedAgentId
      issue_id IssueID issueId
      project_id ProjectID projectId
    ].freeze

    module_function

    def record_id?(value)
      RECORD_ID_PATTERN.match?(value.to_s.strip)
    end

    # Canonical (uppercase) spelling of a record-shaped id. Anything else, including nil and a
    # malformed id, is returned untouched.
    def canonical(value)
      return value unless value.is_a?(String)

      text = value.strip
      record_id?(text) ? text.upcase : value
    end

    # Case-insensitive equality for record-shaped ids, exact equality for everything else.
    def same?(left, right)
      left_text = left.to_s.strip
      right_text = right.to_s.strip
      return false if left_text.empty? || right_text.empty?
      return true if left_text == right_text
      return false unless record_id?(left_text) && record_id?(right_text)

      left_text.casecmp(right_text).zero?
    end

    # Finds a record by id. An exact match always wins, so a case-insensitive fallback can never
    # shadow a canonically stored record.
    def find_record(records, id)
      list = Array(records)
      needle = id.to_s.strip
      return nil if needle.empty?

      list.find { |record| record.is_a?(Hash) && record["id"].to_s == needle } ||
        list.find { |record| record.is_a?(Hash) && same?(record["id"], needle) }
    end

    # Canonical id of the record `value` names in `state`, or nil when nothing matches.
    def canonical_in_state(state, value, sections: RECORD_SECTIONS)
      return nil unless state.is_a?(Hash)

      needle = value.to_s.strip
      return nil if needle.empty?

      sections.each do |section|
        record = find_record(state[section], needle)
        return record["id"].to_s if record
      end
      nil
    end

    # True when a payload holds at least one record-shaped id that is not already canonical. It
    # lets a caller skip loading state for the overwhelmingly common already-canonical case.
    def payload_needs_canonicalization?(payload)
      return false unless payload.is_a?(Hash)

      ID_PAYLOAD_KEYS.any? { |key| recasable?(payload_value(payload, key)) } ||
        NESTED_ID_PAYLOAD_KEYS.any? do |key|
          nested = payload_value(payload, key)
          nested.is_a?(Hash) && NESTED_ID_KEYS.any? { |nested_key| recasable?(payload_value(nested, nested_key)) }
        end
    end

    # Returns a copy of `payload` with every record id that exists in `state` rewritten to its
    # canonical spelling. Ids that do not resolve are left exactly as they arrived.
    def canonicalize_payload(payload, state)
      return payload unless payload.is_a?(Hash)

      canonicalized = payload.dup
      ID_PAYLOAD_KEYS.each do |key|
        value = payload_value(canonicalized, key)
        next unless recasable?(value)

        resolved = canonical_in_state(state, value)
        write_payload_value!(canonicalized, key, resolved) if resolved
      end
      NESTED_ID_PAYLOAD_KEYS.each do |key|
        nested = payload_value(canonicalized, key)
        next unless nested.is_a?(Hash)

        nested_copy = nested.dup
        changed = false
        NESTED_ID_KEYS.each do |nested_key|
          value = payload_value(nested_copy, nested_key)
          next unless recasable?(value)

          resolved = canonical_in_state(state, value)
          next unless resolved

          write_payload_value!(nested_copy, nested_key, resolved)
          changed = true
        end
        write_payload_value!(canonicalized, key, nested_copy) if changed
      end
      canonicalized
    end

    # A value worth canonicalizing: record-shaped and not already uppercase.
    def recasable?(value)
      value.is_a?(String) && record_id?(value) && value.strip != value.strip.upcase
    end

    # Kernel payloads accept both string and symbol keys, so both spellings are honoured here too.
    def payload_value(payload, key)
      return payload[key] if payload.key?(key)

      symbol_key = key.to_sym
      payload.key?(symbol_key) ? payload[symbol_key] : nil
    end

    def write_payload_value!(payload, key, value)
      payload.key?(key) ? payload[key] = value : payload[key.to_sym] = value
      payload
    end
  end
end
