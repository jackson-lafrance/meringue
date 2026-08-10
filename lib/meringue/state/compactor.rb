# frozen_string_literal: true

module Meringue
  module State
    module Compactor
      # `harness_metadata.command` is diagnostic spawn argv, not executable state. One
      # argument can contain the complete head system prompt and kernel snapshot, which
      # used to account for a large share of state.json. Omit that bounded diagnostic
      # field as a whole instead of keeping a misleading prefix of it.
      COMMAND_ARGUMENT_MAX_BYTES = 2_000
      COMMAND_ARGUMENT_OMISSION = "[omitted %<bytes>d-byte command argument by Meringue state compaction]"

      module_function

      # Message-bearing scalar values are deliberately never compacted here. Durable
      # logs reclaim space by evicting whole oldest records in Models, and routing
      # contexts select bounded sets of complete records. The only remaining deep-state
      # compaction is diagnostic command argv, whose oversized elements are replaced in
      # full rather than partially truncated.
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
        hash.each do |key, value|
          changed = true if compact_value!(value, key.to_s)
        end
        changed
      end

      def compact_array!(array, key)
        changed = false
        array.each_with_index do |value, index|
          if command_argument?(key, value)
            compacted = compact_command_argument(value)
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

      def command_argument?(key, value)
        key.to_s == "command" && value.is_a?(String)
      end

      def compact_command_argument(value)
        return value if value.bytesize <= COMMAND_ARGUMENT_MAX_BYTES
        return value if omitted_command_argument?(value)

        format(COMMAND_ARGUMENT_OMISSION, bytes: value.bytesize)
      end

      def omitted_command_argument?(value)
        /\A\[omitted \d+-byte command argument by Meringue state compaction\]\z/.match?(value)
      end
    end
  end
end
