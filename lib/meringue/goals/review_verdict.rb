# frozen_string_literal: true

require "digest"
require "json"

module Meringue
  module Goals
    # The contract between a reviewer session and the kernel.
    #
    # A reviewer-judged goal only works if the reviewer's answer is machine-readable: the
    # kernel has to decide "stop" or "iterate again with this critique" without a human in
    # the middle. So a reviewer turn must end with one JSON object:
    #
    #     { "approved": false,
    #       "rationale": "why, in a sentence or two",
    #       "critique": ["specific actionable change", "..."] }
    #
    # Parsing is deliberately tolerant about *where* that object is (fenced, trailing, or
    # the whole message) and strict about *what* it contains: an answer with no boolean
    # approval, or a rejection with nothing actionable in it, is unusable rather than
    # silently read as "not approved". An unusable verdict is a broken probe, not a
    # verdict, and the kernel handles it the same way it handles a metric command that
    # cannot be read.
    #
    # Pure: no clock, no I/O, no state mutation.
    module ReviewVerdict
      MAX_CRITIQUE_ITEMS = 5
      CRITIQUE_ITEM_LIMIT = 400
      RATIONALE_LIMIT = 600
      RAW_TAIL_LIMIT = 400

      APPROVAL_KEY_PATTERN = /approv|verdict|decision/i.freeze
      APPROVED_WORDS = %w[true yes y approve approved approves accept accepted pass passed ship met ok].freeze
      REJECTED_WORDS = %w[false no n reject rejected rejects deny denied fail failed not_approved changes_requested request_changes needs_work not_met].freeze
      CRITIQUE_KEYS = %w[critique critiques required_changes changes actionable_critique action_items issues feedback next_steps blockers].freeze
      RATIONALE_KEYS = %w[rationale reason reasoning summary explanation assessment why].freeze
      ITEM_KEYS = %w[item text change critique description detail title issue].freeze

      module_function

      # Reads one reviewer turn's final message. Always returns a normalized verdict hash;
      # `usable` says whether the kernel may act on it.
      def parse(text)
        document = extract_document(text)
        return unusable("the reviewer did not end its turn with a JSON verdict object", text) unless document

        approved = approval(document)
        return unusable("the reviewer's JSON had no true/false \"approved\" field", text) if approved.nil?

        critique = critique_items(document)
        rationale = rationale_text(document)
        if !approved && critique.empty? && rationale.nil?
          return unusable("the reviewer withheld approval without a rationale or any actionable critique", text)
        end

        normalize(
          "usable" => true,
          "approved" => approved,
          "rationale" => rationale,
          "critique" => critique
        )
      end

      # Durable shape enforcement for a verdict read back from state.
      def normalize(review)
        return nil unless review.is_a?(Hash)

        usable = review.fetch("usable", false) ? true : false
        {
          "usable" => usable,
          "approved" => usable && review.fetch("approved", false) ? true : false,
          "rationale" => truncate(review["rationale"], RATIONALE_LIMIT),
          "critique" => Array(review["critique"]).filter_map { |item| truncate(item, CRITIQUE_ITEM_LIMIT) }.first(MAX_CRITIQUE_ITEMS),
          "error" => usable ? nil : (truncate(review["error"], RATIONALE_LIMIT) || "the reviewer verdict could not be read"),
          "raw_tail" => truncate(review["raw_tail"], RAW_TAIL_LIMIT),
          "review_worker_id" => present(review["review_worker_id"]),
          "reviewed_at" => present(review["reviewed_at"]),
          "attempt" => review["attempt"].nil? ? nil : review["attempt"].to_i
        }.compact
      end

      def unusable(error, text = nil)
        normalize(
          "usable" => false,
          "approved" => false,
          "error" => error,
          "raw_tail" => tail(text)
        )
      end

      # A stable identity for "the reviewer is asking for the same thing again". Case,
      # punctuation, whitespace, and the order of the critique items are all ignored, so a
      # reworded-but-identical list still counts as a repeat.
      def critique_fingerprint(review)
        return nil unless review.is_a?(Hash) && review.fetch("usable", false)

        items = Array(review.fetch("critique", []))
        items = [review.fetch("rationale", nil)].compact if items.empty?
        normalized = items.map { |item| item.to_s.downcase.gsub(/[^a-z0-9]+/, " ").strip }.reject(&:empty?).sort
        return nil if normalized.empty?

        Digest::SHA256.hexdigest(normalized.join(" | "))[0, 16]
      end

      def critique_text(review)
        Array(review.is_a?(Hash) ? review.fetch("critique", []) : []).map(&:to_s).reject(&:empty?)
      end

      # --- parsing helpers -------------------------------------------------------

      # The verdict is the *last* JSON object in the turn that looks like a verdict: a
      # reviewer may quote the contract, or show an example, before answering. A trailing
      # object with no decision in it is still returned, so the caller can say "your JSON
      # had no approved field" instead of "you returned no JSON".
      def extract_document(text)
        fallback = nil
        parsed_candidates(text).each do |parsed|
          return parsed if approval_key(parsed)

          fallback ||= parsed
        end
        fallback
      end

      def parsed_candidates(text)
        candidates(text).filter_map do |candidate|
          parsed = begin
            JSON.parse(candidate)
          rescue JSON::ParserError, TypeError
            nil
          end
          parsed.is_a?(Hash) ? parsed : nil
        end
      end

      # Ordered latest-first: the answer is at the end of the turn, the preamble is not.
      def candidates(text)
        body = text.to_s.strip
        return [] if body.empty?

        positioned = (json_objects(body) + fenced_blocks(body)).map { |candidate| [body.index(candidate) || 0, candidate] }
        positioned << [-1, body]
        positioned.sort_by { |position, _| -position }.map(&:last).uniq
      end

      def fenced_blocks(text)
        text.scan(/```(?:json)?\s*(.*?)```/m).flatten.map(&:strip).reject(&:empty?)
      end

      # Every balanced top-level `{...}` run in the text, string-aware so a brace inside a
      # quoted critique does not end the object early.
      def json_objects(text)
        objects = []
        depth = 0
        start_index = nil
        in_string = false
        escaped = false

        text.each_char.with_index do |char, index|
          if in_string
            if escaped
              escaped = false
            elsif char == "\\"
              escaped = true
            elsif char == '"'
              in_string = false
            end
            next
          end

          case char
          when '"' then in_string = true
          when "{"
            start_index = index if depth.zero?
            depth += 1
          when "}"
            next if depth.zero?

            depth -= 1
            if depth.zero? && start_index
              objects << text[start_index..index]
              start_index = nil
            end
          end
        end
        objects
      end

      def approval_key(document)
        document.keys.find { |key| key.to_s.match?(APPROVAL_KEY_PATTERN) && !approval_word(document[key]).nil? } ||
          document.keys.find { |key| key.to_s.match?(APPROVAL_KEY_PATTERN) }
      end

      def approval(document)
        key = approval_key(document)
        return nil unless key

        approval_word(document[key])
      end

      def approval_word(value)
        return true if value == true
        return false if value == false

        word = value.to_s.strip.downcase.gsub(/[^a-z_]+/, "_").gsub(/\A_+|_+\z/, "")
        return true if APPROVED_WORDS.include?(word)
        return false if REJECTED_WORDS.include?(word)

        nil
      end

      def critique_items(document)
        key = CRITIQUE_KEYS.find { |candidate| document.key?(candidate) && !Array(document[candidate]).empty? }
        return [] unless key

        items_from(document[key]).filter_map { |item| truncate(item, CRITIQUE_ITEM_LIMIT) }.first(MAX_CRITIQUE_ITEMS)
      end

      def items_from(value)
        case value
        when Array then value.flat_map { |item| items_from(item) }
        when Hash then [ITEM_KEYS.filter_map { |key| present(value[key]) }.first || nil].compact
        when String then value.split(/\r?\n/).map { |line| line.sub(/\A\s*(?:[-*\u2022]|\d+[.)])\s*/, "").strip }.reject(&:empty?)
        else value.nil? ? [] : [value.to_s]
        end
      end

      def rationale_text(document)
        key = RATIONALE_KEYS.find { |candidate| present(document[candidate]) }
        return nil unless key

        truncate(document[key], RATIONALE_LIMIT)
      end

      def present(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def truncate(value, limit)
        text = present(value)
        return nil unless text

        text.length <= limit ? text : "#{text[0, limit - 1]}\u2026"
      end

      def tail(text)
        body = present(text)
        return nil unless body

        body.length <= RAW_TAIL_LIMIT ? body : "\u2026#{body[-RAW_TAIL_LIMIT..]}"
      end
    end
  end
end
