# frozen_string_literal: true

module Meringue
  module Harness
    # One place that decides what a `provider/model` reference looks like.
    #
    # Meringue used to spell this rule as `%r{\A[^/\s]+/[^/\s]+\z}` in the kernel
    # and again as a three-way `split("/", 3)` in the Pi client. Both encoded
    # "exactly one slash", which is not the grammar any harness actually uses. A
    # real Fireworks router model is
    # `fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast`: the provider
    # is `fireworks` and the model id is an account/router path with four more
    # slashes and a colon. Pi lists that model in `get_available_models`, accepts
    # it on `--model`, and reports it back from `get_state`, so Meringue refusing
    # it made a model the user could run unreachable from `/model` and from the
    # picker.
    #
    # The rule here is Pi's own (`findExactModelReferenceMatch` /
    # `resolveModel` in pi's model-resolver: split on the *first* slash), stated
    # harness-neutrally:
    #
    #   <provider>/<model-id>
    #
    # - the provider is everything before the first `/` and may not be empty
    # - the model id is everything after the first `/` and may not be empty
    # - the model id may contain further `/` and `:` characters
    #
    # What is still rejected is deliberately limited to shapes that cannot be a
    # model reference at all, so a typo or a shell-mangled argument does not
    # silently become the default model:
    #
    # - an empty value
    # - whitespace or control characters anywhere (two arguments, or a quoted
    #   phrase, is not one id)
    # - no `/` at all (a bare model id is ambiguous across providers)
    # - an empty provider (`/model-id`) or an empty model id (`provider/`)
    # - a leading `-` (a mangled command-line flag)
    # - a `.` or `..` provider (a mangled filesystem path)
    #
    # Validity of the *values* is not decided here. Whether a well-formed id
    # names a model that exists is the harness's answer, reported by the model
    # catalog and finally by the harness itself when a session starts; the
    # catalog labels an id as unverified rather than refusing it.
    module ModelReference
      EXAMPLE = "openai/gpt-5.6-sol"
      # The reference from the bug report, kept in messages because "the model id
      # may itself contain slashes" is much easier to believe with an example.
      MULTI_SEGMENT_EXAMPLE = "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast"
      FORMAT_HINT = "Use <provider>/<model-id>, for example #{EXAMPLE}; " \
                    "the model id may itself contain / and :, as in #{MULTI_SEGMENT_EXAMPLE}."

      module_function

      # `{ "provider" =>, "id" =>, "reference" => }` for a well-formed reference,
      # nil otherwise. The returned reference is the trimmed input, so callers can
      # persist exactly what they validated.
      def parse(value)
        text = normalize(value)
        return nil unless rejection_reason(text).nil?

        provider, id = split(text)
        { "provider" => provider, "id" => id, "reference" => text }
      end

      def valid?(value)
        rejection_reason(value).nil?
      end

      # Why `value` is not a model reference, phrased for the user-visible log
      # line, or nil when it is one.
      def rejection_reason(value)
        text = normalize(value)
        return "a model id is required" if text.empty?
        return "#{text.inspect} contains whitespace, so it is not a single model id" if whitespace?(value)
        return "#{text.inspect} contains control characters" if control_characters?(text)
        return "#{text.inspect} looks like a command-line flag, not a model id" if text.start_with?("-")
        return "#{text.inspect} has no provider prefix" unless text.include?("/")

        provider, id = split(text)
        return "#{text.inspect} has an empty provider" if provider.empty?
        return "#{text.inspect} has an empty model id" if id.empty?
        return "#{text.inspect} looks like a filesystem path, not a model id" if %w[. ..].include?(provider)

        nil
      end

      # Everything before the first slash, and everything after it. Splitting on
      # the last slash, or refusing more than one, is the bug this module exists
      # to prevent.
      def split(value)
        text = normalize(value)
        index = text.index("/")
        return [text, ""] if index.nil?

        [text[0...index], text[(index + 1)..].to_s]
      end

      def provider_of(value)
        split(value).first
      end

      def id_of(value)
        split(value).last
      end

      def normalize(value)
        value.to_s.strip
      end

      def whitespace?(value)
        normalize(value).match?(/\s/)
      end

      def control_characters?(value)
        value.to_s.match?(/[\u0000-\u001f\u007f]/)
      end
    end
  end
end
