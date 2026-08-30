# frozen_string_literal: true

module Meringue
  # One policy for values that can escape orchestration and become part of a git
  # branch, worktree, commit, harness session label, or pull request. Internal
  # records may still use orchestration ids; delivery artifacts may not.
  module DeliveryArtifactPolicy
    MAX_SLUG_LENGTH = 48
    # Allocator branches are task slugs with deterministic numeric collision
    # suffixes. Pure Git object SHAs and the retired hash-suffixed format are
    # deliberately not managed branches.
    MANAGED_BRANCH_PATTERN = %r{\A(?![0-9a-f]{8}\z)(?![0-9a-f]{40}\z)(?![a-z0-9-]+-[0-9a-f]{8}(?:-\d+)?\z)[a-z0-9][a-z0-9-]*(?:-\d+)?\z}.freeze

    # Includes punctuation/case variants such as P5-I2-W3, p5_i2_w3,
    # P5/I2/W3, P5 I2 W3, and the shorter project/issue forms.
    ORCHESTRATION_ID_PATTERN = %r{
      (?<![a-z0-9])
      p\s*\d+
      (?:\s*[-_/.:\s]\s*i\s*\d+)?
      (?:\s*[-_/.:\s]\s*w\s*\d+)?
      (?![a-z0-9])
    }ix.freeze
    SHORT_ID_PATTERN = /(?<![a-z0-9])(?:h|q)\s*[-_#:]?\s*\d+(?![a-z0-9])/i.freeze
    BRAND_PATTERN = /(?<![a-z0-9])meringue(?![a-z0-9])/i.freeze
    IDENTITY_LABEL_PATTERN = %r{
      (?<![a-z0-9])
      (?:pi\s+)?(?:agent|worker|session)[\s_-]*(?:id|identity)?\s*[:#=]?\s*
      (?:[a-z]*[-_])?\d+(?:[-_][a-z0-9]+)*
      (?![a-z0-9])
    }ix.freeze
    CONFIDENCE_LINE_PATTERN = /\b(?:ai\s+)?confidence(?:\s+score)?\s*[:=\-]?\s*(?:\d+(?:\.\d+)?%?|high|medium|low)\b/i.freeze
    AGENT_ATTRIBUTION_LINE_PATTERN = %r{
      \b(?:
        (?:co-?)?(?:authored|generated|prepared|implemented|written|worked\s+on)\s+by\s+(?:an?\s+)?(?:ai|agent|worker|session)|
        agents?\s+(?:involved|used|who\s+worked|contributors?)\s*[:\-]
      )
    }ix.freeze

    module_function

    def human_title(value)
      text = value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: " ")
      text = text.gsub(BRAND_PATTERN, " ")
                 .gsub(ORCHESTRATION_ID_PATTERN, " ")
                 .gsub(SHORT_ID_PATTERN, " ")
                 .gsub(IDENTITY_LABEL_PATTERN, " ")
                 .gsub(CONFIDENCE_LINE_PATTERN, " ")
      text.gsub(/[\s\-_:|\/]+/, " ").strip
    end

    def slug(value, fallback: "change")
      text = human_title(value).downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      text = text[0, MAX_SLUG_LENGTH].to_s.gsub(/-+\z/, "")
      text.empty? ? fallback : text
    end

    # Use for supplied prose that may be copied into a commit or PR. Unsafe
    # attribution/confidence lines are removed; ids and branding elsewhere are
    # redacted without changing the product explanation around them.
    def delivery_text(value)
      value.to_s.lines.filter_map do |line|
        next if line.match?(CONFIDENCE_LINE_PATTERN) || line.match?(AGENT_ATTRIBUTION_LINE_PATTERN)

        cleaned = line.gsub(BRAND_PATTERN, "")
                      .gsub(ORCHESTRATION_ID_PATTERN, "")
                      .gsub(SHORT_ID_PATTERN, "")
                      .gsub(IDENTITY_LABEL_PATTERN, "")
                      .gsub(/[ \t]+/, " ")
                      .gsub(/ +([,.;!?])/, "\\1")
                      .strip
        cleaned unless cleaned.empty?
      end.join("\n")
    end

    def managed_branch?(branch)
      branch.to_s.match?(MANAGED_BRANCH_PATTERN)
    end
  end
end
