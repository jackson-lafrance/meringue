# frozen_string_literal: true

module Meringue
  module TUI
    # The searchable model list behind `/models`.
    #
    # `/models` used to dump the harness's whole catalog into the visible log:
    # over a hundred lines the user could not act on, truncated with a hint that
    # pointed at a different command. This module is the read-only view model for
    # the picker that replaced it. It answers three questions from persisted
    # state alone, so rendering a frame never starts a harness process:
    #
    # - which harness the picker is showing,
    # - which models that harness reported (kernel-cached snapshot), and
    # - what to say instead of an empty list when the harness could not answer.
    #
    # Selecting a row is applied by the TUI as the active mode's `/model` or
    # `/thinking` command, so the picker adds no second way to write session
    # defaults: the kernel's `SetDefaultSessionModel` and
    # `SetDefaultSessionThinkingLevel` remain the only writers.
    module ModelPicker
      module_function

      # Resolved harness for the picker: an explicit `/models <harness>`
      # argument, otherwise the active harness, otherwise the default provider.
      def harness_for(state, requested = nil)
        name = requested.to_s.strip
        name = (state || {}).dig("metadata", "active_harness").to_s.strip if name.empty?
        name = Meringue::Harness::Registry::DEFAULT_PROVIDER if name.empty?
        Meringue::Harness::Registry.public_provider_name(name)
      end

      # The kernel-cached snapshot for a harness. Coerced, so an absent snapshot
      # becomes an explicit "not fetched yet" catalog rather than nil.
      def catalog(state, harness)
        Meringue::Harness::ModelCatalog.coerce(snapshot_for(state, harness), harness: harness)
      end

      # The persisted snapshot exactly as the kernel wrote it, or nil when the
      # kernel has never fetched a catalog for this harness. "Never asked" and
      # "the harness cannot answer" are different sentences for the user, and a
      # coerced catalog cannot tell them apart.
      def snapshot_for(state, harness)
        value = (state || {}).dig("metadata", "harness_model_catalogs", harness)
        value.is_a?(Hash) ? value : nil
      end

      # Rows for the picker: the current default first, then every other model
      # grouped by provider and sorted by id, filtered by the typed query.
      #
      # This intentionally differs from `/model <Tab>` completion, which
      # interleaves providers because only three rows are visible there and one
      # provider would fill the whole window. The picker shows ten rows and is
      # searched rather than glanced at, so provider grouping is the easier list
      # to scan and `openai` narrows to one provider immediately.
      #
      # A stale list (latest refresh failed) is still the harness's own answer, so
      # it is offered in full and labelled instead of being hidden.
      def entries(state, harness: nil, query: nil, role: nil)
        harness = harness_for(state, harness)
        snapshot = catalog(state, harness)
        return [] unless snapshot.usable?

        default_reference = default_model_reference(state, role: role)
        rows = snapshot.models.map { |model| entry_for(model, default_reference) }
        current, rest = rows.partition { |row| row.fetch("current") }
        ordered = current + rest.sort_by { |row| [row.fetch("provider"), row.fetch("id")] }
        filter(ordered, query)
      end

      def entry_at(state, index, harness: nil, query: nil)
        rows = entries(state, harness: harness, query: query)
        return nil if rows.empty?

        rows[index.to_i.clamp(0, rows.length - 1)]
      end

      def count(state, harness: nil, query: nil, role: nil)
        entries(state, harness: harness, query: query, role: role).length
      end

      # The thinking picker uses the same catalog-aware descriptions as inline
      # `/thinking` completion, but owns its modal list and role tab. Keeping the
      # source in SlashCommandParser means the picker and command completion agree
      # on accepted levels and current-default labeling.
      def thinking_entries(state, role:, query: nil)
        role_name = role.to_s.strip.downcase
        return [] if !role_name.empty? && !%w[head worker].include?(role_name)

        input = if role_name.empty?
                  "/thinking #{query}"
                else
                  "/thinking #{role_name} #{query}"
                end
        Meringue::Input::SlashCommandParser.command_suggestion_records(input, limit: nil, state: state).filter_map.with_index do |record, index|
          next unless record.fetch("kind", nil) == "thinking_levels"

          level = record.fetch("usage")
          {
            "reference" => level,
            "level" => level,
            "name" => record.fetch("description", ""),
            "description" => record.fetch("description", ""),
            "current" => record.fetch("current", false),
            "index" => index
          }
        end
      end

      def default_model_reference(state, role: nil)
        defaults = (state || {}).dig("metadata", "pi_session_defaults") || {}
        role_name = role.to_s.strip.downcase
        reference = if %w[head worker].include?(role_name)
                      role_reference = defaults.dig("roles", role_name, "model").to_s.strip
                      role_reference.empty? ? defaults["model"] : role_reference
                    else
                      defaults["model"]
                    end
        reference.to_s
      end

      # Model ids commonly omit punctuation while they are being typed. Keep the
      # displayed/catalog reference intact, but make a query such as `gpt5`
      # equivalent to `gpt-5` for autocomplete and picker filtering.
      def model_search_text(value)
        value.to_s.downcase.delete("-")
      end

      # What the picker says when it has no rows. Never nil while the list is
      # empty, so the picker cannot render a blank box: an unavailable or
      # unsupported harness, a stale-but-empty snapshot, and a query that matched
      # nothing are all different sentences.
      def empty_message(state, harness: nil, query: nil)
        harness = harness_for(state, harness)
        return unfetched_message(harness) unless snapshot_for(state, harness)

        snapshot = catalog(state, harness)
        return degraded_message(snapshot, harness) unless snapshot.usable?

        query = query.to_s.strip
        return "#{harness} reported no models." if snapshot.models.empty?
        return "No #{harness} model matches “#{query}”." unless query.empty?

        "#{harness} reported no models."
      end

      def unfetched_message(harness)
        "Meringue has not fetched #{harness}'s model list yet. Press Ctrl-R to ask the harness now; " \
          "an exact provider/model id still works with /model."
      end

      # Why the list is missing, in the harness's own words when it gave us any.
      def degraded_message(snapshot, harness)
        note = snapshot.note.to_s.strip
        headline = if snapshot.unsupported?
                     "#{harness} does not expose a model catalog"
                   else
                     "#{harness} model catalog unavailable"
                   end
        note = "Meringue has not fetched #{harness}'s model list yet." if note.empty?
        note = "#{note}." unless note.end_with?(".", "!", "?")
        "#{headline}: #{note} An exact provider/model id still works with /model."
      end

      # Short label describing the snapshot's freshness, or nil when it is
      # simply current. Rendered next to the count, never per row.
      def state_label(state, harness: nil, now: Time.now)
        harness = harness_for(state, harness)
        snapshot = catalog(state, harness)
        return nil if snapshot.available?
        if snapshot.stale?
          timestamp = Timestamps.display(snapshot.fetched_at, now: now)
          return "last confirmed #{timestamp || snapshot.fetched_at}"
        end

        "unverified"
      end

      def entry_for(model, default_reference)
        reference = model.fetch("reference")
        {
          "reference" => reference,
          "provider" => model.fetch("provider"),
          "id" => model.fetch("id"),
          "name" => model["name"].to_s,
          "thinking_levels" => Array(model["thinking_levels"]),
          "context_window" => model["context_window"],
          "current" => !default_reference.to_s.empty? && reference.casecmp?(default_reference.to_s)
        }
      end

      # Space separated tokens all have to match somewhere in the row, so
      # "openai high" narrows without forcing the user to remember id order.
      def filter(rows, query)
        tokens = query.to_s.split(/\s+/).reject(&:empty?).map { |token| model_search_text(token) }
        return rows if tokens.empty?

        rows.select do |row|
          haystack = model_search_text([
            row.fetch("reference"),
            row.fetch("name"),
            row.fetch("provider"),
            row.fetch("thinking_levels").join(" ")
          ].join(" "))
          tokens.all? { |token| haystack.include?(token) }
        end
      end
    end
  end
end
