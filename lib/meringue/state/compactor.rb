# frozen_string_literal: true

module Meringue
  module State
    module Compactor
      DEFAULT_STRING_MAX_BYTES = 100_000
      ERROR_STRING_MAX_BYTES = 2_000
      LOG_MESSAGE_MAX_BYTES = 4_000
      STDERR_MAX_BYTES = 4_000
      SESSION_TEXT_MAX_BYTES = 20_000
      # `harness_metadata.command` is the spawn argv kept for diagnostics, and one of
      # its elements is the whole `--append-system-prompt` payload: for a head that is
      # the entire kernel snapshot, tens of kilobytes, persisted forever. Argv was
      # measured at 29% of a real 1 MB state file, and every byte of it is re-read,
      # re-parsed, and re-serialized on every frame and every save. Keep enough to
      # identify the program and its flags; drop the prompt body.
      COMMAND_ARGUMENT_MAX_BYTES = 2_000

      KEY_LIMITS = {
        "error" => ERROR_STRING_MAX_BYTES,
        "error_message" => ERROR_STRING_MAX_BYTES,
        "original_error_message" => ERROR_STRING_MAX_BYTES,
        "repair_error_message" => ERROR_STRING_MAX_BYTES,
        "head_result_repair_error_message" => ERROR_STRING_MAX_BYTES,
        "message" => LOG_MESSAGE_MAX_BYTES,
        "stderr_tail" => STDERR_MAX_BYTES,
        "line" => STDERR_MAX_BYTES,
        "last_assistant_text" => SESSION_TEXT_MAX_BYTES
      }.freeze

      # Limits that apply only to strings held *inside* an array under this key.
      # `harness_metadata.command` is an argv array, while `goal.metric.command`,
      # `goal.guardrails[].command`, and a queued worker's
      # `deferred_spawn.command_gate.command` are single executable command strings.
      # Truncating a command Meringue still has to run would silently corrupt a goal loop
      # or poll a mangled gate forever, so the argv limit is deliberately scoped to the
      # array form and never reaches a scalar.
      ARRAY_ELEMENT_KEY_LIMITS = {
        "command" => COMMAND_ARGUMENT_MAX_BYTES
      }.freeze

      module_function

      def compact!(state)
        compact_value!(state, nil)
      end

      def compact_value!(value, key)
        case value
        when Hash
          compact_hash!(value)
        when Array
          compact_array!(value, key)
        else
          false
        end
      end

      def compact_hash!(hash)
        changed = false
        hash.keys.each do |key|
          string_key = key.to_s
          value = hash[key]
          if value.is_a?(String)
            compacted = compact_string(value, string_key)
            if compacted != value
              hash[key] = compacted
              changed = true
            end
          else
            changed = true if compact_value!(value, string_key)
          end
        end
        changed
      end

      def compact_array!(array, key)
        changed = false
        array.each_with_index do |value, index|
          if value.is_a?(String)
            compacted = compact_string(value, key.to_s, in_array: true)
            if compacted != value
              array[index] = compacted
              changed = true
            end
          else
            changed = true if compact_value!(value, key)
          end
        end
        changed
      end

      def compact_string(value, key, in_array: false)
        limit = limit_for_key(key, in_array: in_array)
        return value if value.bytesize <= limit

        suffix = "\n… [truncated #{value.bytesize - limit} bytes by Meringue state compaction]"
        value.byteslice(0, limit).to_s.scrub + suffix
      end

      def limit_for_key(key, in_array: false)
        string_key = key.to_s
        return ARRAY_ELEMENT_KEY_LIMITS.fetch(string_key) if in_array && ARRAY_ELEMENT_KEY_LIMITS.key?(string_key)

        KEY_LIMITS.fetch(string_key, DEFAULT_STRING_MAX_BYTES)
      end
    end
  end
end
