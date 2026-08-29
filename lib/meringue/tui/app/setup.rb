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
        return setup_status_bar_rows if step == Settings::SetupFlow::STATUS_BAR

        expanded = @settings_expanded_advanced.fetch(step, false)
        rows = Settings::SetupFlow.setting_ids(step, draft: @settings_draft).filter_map do |id|
          setup_definition_row(id)
        end
        rows << setup_harness_check_row if step == Settings::SetupFlow::HARNESS
        advanced = Settings::SetupFlow.advanced_setting_ids(step)
        return rows if advanced.empty?

        # The card shows one wrapped line of the selected row's description, so
        # the way back out has to fit on it.
        description = if expanded
                        "Enter or A puts model and reasoning back out of the way."
                      else
                        "Harness defaults already work. Enter or A opens them anyway."
                      end
        # The reveal is a disclosure, not a door. It stays on the card once it is
        # open, in the same place, because the row someone pressed to get here is
        # the row they look for to get back — and setup has no category rail to
        # leave through.
        rows << synthetic_settings_row(
          "_show_advanced",
          expanded ? "Hide model and reasoning" : "Model and reasoning",
          description,
          expanded ? "hide" : "#{advanced.length} settings"
        )
        rows.concat(advanced.filter_map { |id| setup_definition_row(id) }) if expanded
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

      # Availability is a property of this machine at this moment, so it is
      # attached where the row is rendered rather than frozen into the schema.
      # A backend Meringue cannot find is never hidden — someone may be
      # configuring a machine they are about to install it on — it just says so.
      def decorate_setup_row(row)
        return row unless %w[agent.head_harness agent.worker_harness].include?(row.fetch("id", nil))
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

      # The composer is a real editing surface and it used to be the whole step,
      # so a first run made everyone lay out a bar they had never seen in use.
      # The default is shown live above; customizing is a deliberate choice.
      def setup_status_bar_rows
        return [] if @settings_status_bar_customizing

        [synthetic_settings_row(
          "setup.customize_status_bar",
          "Customize layout",
          "Drag the open-PR, worker/head count, harness, model, and reasoning components between the left and right sides.",
          "Enter"
        )]
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
      # heads on this". The other role follows while it is still unset, so the
      # step is one decision; a value already chosen is never overwritten, so
      # deliberately splitting the roles still works.
      def pair_setup_harness(id, value)
        partner = {
          "agent.head_harness" => "agent.worker_harness",
          "agent.worker_harness" => "agent.head_harness"
        }[id.to_s]
        return unless partner
        return unless @settings_draft.value(partner).to_s.strip.empty?

        @settings_draft.set(partner, value)
      rescue KeyError
        nil
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
        return "#{Harness::Registry.provider_label(head)} for heads and workers" if head == worker

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
