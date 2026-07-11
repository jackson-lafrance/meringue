# frozen_string_literal: true

require "time"

module Meringue
  module State
    module Models
      SCHEMA_VERSION = 1

      LIFECYCLE_STATUSES = %w[queued working idle blocked completed errored killed].freeze
      QUESTION_STATUSES = %w[open answered dismissed].freeze
      LOG_LEVELS = %w[info warning error].freeze
      LOG_SOURCE_TYPES = %w[user kernel head worker harness system].freeze

      module_function

      def empty_state(now: Time.now.utc.iso8601)
        {
          "schema_version" => SCHEMA_VERSION,
          "projects" => [],
          "issues" => [],
          "agents" => [],
          "questions" => [],
          "logs" => [],
          "counters" => {
            "projects" => 0,
            "heads" => 0,
            "questions" => 0,
            "logs" => 0,
            "issues_by_project" => {},
            "workers_by_issue" => {}
          },
          "metadata" => {
            "created_at" => now,
            "updated_at" => now
          }
        }
      end
    end
  end
end
