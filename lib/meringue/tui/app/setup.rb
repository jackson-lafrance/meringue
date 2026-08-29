# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # The first-run surface: which controls each setup step shows, what the
      # machine can actually run, and the repository setup offers to adopt.
      #
      # Setup is still a curated Settings::Draft over the same schema, editors,
      # and save transaction as /config — only the rows and the copy differ, and
      # they differ enough to be worth their own file.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def setup_rows
        step = settings_category
        return [] if Settings::SetupFlow.narrative?(step)

        rows = Settings::SetupFlow.setting_ids(step, draft: @settings_draft).filter_map do |id|
          setup_definition_row(id)
        end
        rows << setup_harness_check_row if step == Settings::SetupFlow::HARNESS
        rows
      end

      def setup_definition_row(id)
        definition = @settings_draft.definitions.find { |candidate| candidate.id == id }
        return unless definition

        decorate_setup_row(@settings_draft.row(definition))
      end

      # Locating an executable and running it are different questions, and only
      # the second one tells you whether Meringue can start a session. The check
      # is bounded and read-only, and it happens because someone asked for it.
      def setup_harness_check_row
        result = @harness_check_result
        display = if result.nil?
                    "Run check"
                  else
                    result.fetch("summary", "checked")
                  end
        description = if result.nil?
                        "Starts each selected harness once and asks for its version. Nothing else is run."
                      else
                        result.fetch("detail", "")
                      end
        synthetic_settings_row("setup.check_harness", "Check harness", description, display)
      end

      # The harness row is one decision about the whole install, so in setup it
      # loses the role in its name: "Head harness" is a distinction the flow no
      # longer draws, and drawing it here invites someone to go looking for the
      # other half.
      SETUP_HARNESS_LABEL = "Harness"
      # Only the first wrapped line of a description is rendered, so it has to be
      # one line's worth or it dangles mid-sentence.
      SETUP_HARNESS_DESCRIPTION = "The coding agent Meringue drives. Split the roles later in /config."

      # Availability is a property of this machine at this moment, so it is
      # attached where the row is rendered rather than frozen into the schema.
      # A backend Meringue cannot find is never hidden — someone may be
      # configuring a machine they are about to install it on — it just says so.
      def decorate_setup_row(row)
        return row unless %w[agent.head_harness agent.worker_harness].include?(row.fetch("id", nil))

        row = row.merge("label" => SETUP_HARNESS_LABEL, "description" => SETUP_HARNESS_DESCRIPTION)
        return row unless @harness_availability

        labels = row.fetch("option_labels", {}) || {}
        annotated = labels.to_h do |value, label|
          located = @harness_availability.fetch(value, nil)
          [value, located ? "#{label} · #{Harness::Availability.summary(located)}" : label]
        end
        current = row.fetch("value", "").to_s
        located = @harness_availability.fetch(current, nil)
        display = row.fetch("display_value", "").to_s
        display = "#{display} · #{Harness::Availability.summary(located)}" if located && !display.empty?
        row.merge("option_labels" => annotated, "display_value" => display)
      end

      # Setup preselects a harness only when the machine leaves no ambiguity.
      # With several installed, or none, it still asks — guessing which backend
      # someone meant is exactly the mistake the registry refuses to make.
      def preselect_detected_harnesses
        return unless @settings_draft
        return unless @harness_availability

        installed = @harness_availability.select { |_provider, located| Harness::Availability.installed?(located) }.keys
        return unless installed.length == 1

        %w[agent.head_harness agent.worker_harness].each do |id|
          next unless @settings_draft.value(id).to_s.strip.empty?

          @settings_draft.set(id, installed.first)
        end
      rescue ArgumentError, KeyError
        nil
      end

      # Choosing a harness during setup means "run Meringue on this", not "run
      # heads on this". A first run asks once and applies the answer to both
      # roles, so the mirror is unconditional: setup no longer shows the roles
      # separately, and a partner left behind at an older value would be a split
      # nobody asked for and cannot see. Splitting the roles deliberately is what
      # /config is for.
      def pair_setup_harness(id, value)
        partner = {
          "agent.head_harness" => "agent.worker_harness",
          "agent.worker_harness" => "agent.head_harness"
        }[id.to_s]
        return unless partner

        @settings_draft.set(partner, value)
      rescue KeyError
        nil
      end

      # What this step will not let you walk past, as {setting_id => message}.
      # Empty for every step that has no required settings, which is all of them
      # but Harness.
      def setup_step_blockers(step = settings_category)
        return {} unless @settings_draft

        Settings::SetupFlow.required_setting_ids(step).each_with_object({}) do |id, blockers|
          next unless @settings_draft.value(id).to_s.strip.empty?

          # The name the row is rendered under, not the schema's role-specific
          # one, or the error names a control that is not on screen.
          label = id == "agent.head_harness" ? SETUP_HARNESS_LABEL : Config::Schema.fetch(id).label
          blockers[id] = "#{label} is required — Meringue cannot start an agent without it."
        end
      rescue KeyError
        {}
      end

      # Refuses a forward move and shows why, on the control that is missing.
      # Backwards navigation is never gated: going back to re-read something is
      # not a way to dodge the requirement.
      def block_setup_advance?
        blockers = setup_step_blockers
        return false if blockers.empty?

        @settings_draft.errors.merge!(blockers)
        # Land the cursor on the control that is missing rather than leaving it
        # on the action that was just refused.
        @settings_footer_focus = false
        focus_setup_setting(blockers.keys.first)
        @force_full_redraw = true
        true
      end

      def harness_availability_snapshot
        return nil unless @harness_availability_provider

        result = @harness_availability_provider.call
        result.is_a?(Hash) ? result : nil
      rescue StandardError
        nil
      end

      # Runs each selected harness once. Bounded by the probe itself, and only
      # ever reached from the row the user activated.
      def check_harness_from_settings
        unless @harness_probe
          @harness_check_result = { "summary" => "unavailable", "detail" => "This session cannot run a harness check." }
          return true
        end

        providers = %w[agent.head_harness agent.worker_harness]
                    .map { |id| @settings_draft.value(id).to_s.strip }
                    .reject(&:empty?)
                    .uniq
        if providers.empty?
          @harness_check_result = { "summary" => "pick one first", "detail" => "Choose a harness above, then run the check." }
          return true
        end

        results = providers.to_h { |provider| [provider, @harness_probe.call(provider)] }
        @harness_check_result = harness_check_summary(results)
        true
      rescue StandardError => e
        @harness_check_result = { "summary" => "check failed", "detail" => e.message.to_s }
        true
      end

      def harness_check_summary(results)
        failures = results.reject { |_provider, located| located.fetch("status", nil) == Harness::Availability::RUNNABLE }
        if failures.empty?
          detail = results.map { |provider, located| "#{Harness::Registry.provider_label(provider)} #{located.fetch("detail", "runs")}" }.join(" · ")
          return { "summary" => "ready", "detail" => detail }
        end

        detail = failures.map do |provider, located|
          "#{Harness::Registry.provider_label(provider)}: #{located.fetch("detail", Harness::Availability.summary(located))}"
        end.join(" · ")
        { "summary" => failures.length == results.length ? "not ready" : "partly ready", "detail" => detail }
      end

      # What finishing will do, in the order the steps asked it. Rendered on the
      # last card so Complete is checkable instead of hopeful.
      def setup_summary_entries
        return [] unless @settings_draft

        entries = []
        head = @settings_draft.value("agent.head_harness").to_s
        worker = @settings_draft.value("agent.worker_harness").to_s
        entries << { "label" => "Harness", "value" => setup_harness_summary(head, worker) }
        entries << { "label" => "Theme", "value" => @settings_draft.value("appearance.theme").to_s }
        entries << { "label" => "Xtras", "value" => setup_experiments_summary }
        entries
      rescue KeyError
        entries || []
      end

      def setup_harness_summary(head, worker)
        return "not chosen yet" if head.empty? && worker.empty?
        return Harness::Registry.provider_label(head).to_s if head == worker

        "#{Harness::Registry.provider_label(head)} heads · #{Harness::Registry.provider_label(worker)} workers"
      end

      def setup_experiments_summary
        enabled = Experiments::Registry.all.select do |experiment|
          @settings_draft.value("experiments.#{experiment.id}") == true
        end
        return "all off" if enabled.empty?

        enabled.map(&:label).join(", ")
      rescue KeyError
        "all off"
      end
    end
  end
end
