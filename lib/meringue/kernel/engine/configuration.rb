# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Configuration the user owns: GitHub access checks, saved settings, theme, onboarding, and
      # harness selection.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def test_github_access(command_id, command_type, payload)
        enabled = synchronized_state { github_support_enabled?(normalized_state) }
        unless enabled
          result = {
            "outcome" => "unavailable",
            "message" => "Enable GitHub support in Settings → Experiments before testing access."
          }
          return accepted_result(command_id, command_type, nil, result.fetch("message"), result, [])
        end

        repository, remote_error = github_access_repository(payload)
        unless repository
          result = {
            "outcome" => "malformed_remote",
            "message" => remote_error || "The current repository does not have a supported GitHub origin remote."
          }
          return record_github_access_result(command_id, command_type, result)
        end

        result = if forge_client.respond_to?(:test_access)
                   invoke_forge_access_test(repository)
                 else
                   {
                     "outcome" => "unavailable",
                     "message" => "The configured GitHub client cannot run an access check.",
                     "repository" => repository
                   }
                 end
        record_github_access_result(command_id, command_type, result.merge("repository" => repository).compact)
      rescue StandardError => e
        record_github_access_result(
          command_id,
          command_type,
          {
            "outcome" => "unavailable",
            "message" => "GitHub access test was unavailable: #{e.message}",
            "repository" => repository
          }.compact
        )
      end

      def github_access_repository(payload)
        requested = present_string(value_at(payload, "repository", "Repository"))
        if requested
          return [requested, "The requested GitHub repository is malformed."] unless requested.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z})

          return [requested, nil]
        end

        remote = present_string(value_at(payload, "remote", "Remote"))
        if remote.nil?
          stdout, _stderr, status = Open3.capture3("git", "-C", cwd, "remote", "get-url", "origin")
          return [nil, "Could not read the current repository's origin remote."] unless status.success?

          remote = present_string(stdout)
        end
        repository = Forge::GitHubClient.repository_from_remote(remote)
        return [repository, nil] if repository

        [nil, "The current origin remote is not a supported GitHub repository URL."]
      rescue Errno::ENOENT
        [nil, "Git is unavailable, so the current repository origin could not be checked."]
      rescue StandardError => e
        [nil, "The current repository origin could not be checked: #{e.message}"]
      end

      def invoke_forge_access_test(repository)
        method = forge_client.method(:test_access)
        if forge_method_accepts_timeout?(method)
          method.call(repository: repository, timeout: GITHUB_ACCESS_TEST_BUDGET_SECONDS)
        else
          method.call(repository: repository)
        end
      end

      def record_github_access_result(command_id, command_type, result)
        normalized = result.is_a?(Hash) ? result.compact : {}
        outcome = normalized.fetch("outcome", normalized.fetch("status", "unavailable")).to_s
        normalized["outcome"] = outcome
        message = normalized.fetch("message", "GitHub access test was unavailable.").to_s
        log_ids = synchronized_state do
          state = normalized_state
          ids = append_log(
            state,
            source_type: "kernel",
            source_id: nil,
            level: %w[success].include?(outcome) ? "info" : "warning",
            message: message,
            details: {
              "kind" => "github_access_test",
              "outcome" => outcome,
              "repository" => normalized["repository"],
              "identity" => normalized["identity"]
            }.compact
          )
          touch_state!(state)
          store.save(state)
          ids
        end
        accepted_result(command_id, command_type, normalized["repository"], message, normalized, log_ids)
      end

      def no_op(command_id, command_type, payload)
        state = normalized_state
        reason = present_string(value_at(payload, "reason", "Reason", "message", "Message", "summary", "Summary", "note", "Note")) || "No work was needed."
        head_id = present_string(value_at(payload, "_head_id", "head_id", "HeadID", "headId"))
        now = timestamp
        message = head_id ? "Head #{head_id} intentionally routed no work: #{reason}" : "No-op: #{reason}"
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: head_id,
          level: "info",
          message: message,
          details: {
            "kind" => "no_op",
            "head_id" => head_id,
            "reason" => reason
          }.compact
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, head_id, message, { "reason" => reason }.compact, log_ids)
      end

      def save_configuration(command_id, command_type, payload)
        baseline = value_at(payload, "base_fingerprint", "BaseFingerprint")
        changes = value_at(payload, "changes", "Changes")
        onboarding_outcome = value_at(payload, "onboarding_outcome", "OnboardingOutcome")
        unless baseline.is_a?(String) && changes.is_a?(Hash)
          return rejected_result(
            command_id,
            command_type,
            "Configuration was not saved because the Settings draft is invalid.",
            ["base_fingerprint and changes are required"]
          )
        end

        unless onboarding_outcome.nil? || Config::ONBOARDING_OUTCOMES.include?(onboarding_outcome.to_s)
          return configuration_rejected_result(
            command_id,
            command_type,
            "Configuration was not saved because the setup outcome is invalid.",
            { "setup.outcome" => "must be one of: #{Config::ONBOARDING_OUTCOMES.join(", ")}" }
          )
        end

        transaction = Config::Store.new(path: config_path).save(
          base_fingerprint: baseline,
          changes: changes,
          onboarding_outcome: onboarding_outcome
        )
        saved_file_config = transaction.fetch("config")
        @config = config_with_runtime_overrides(saved_file_config)
        apply_runtime_config_update(@config, transaction.fetch("changed_ids"))

        overridden_settings = transaction.fetch("changed_ids").filter_map do |id|
          source = @config.setting_source(id)
          [id, source] unless %w[file default].include?(source)
        end.to_h
        theme = @config.setting("appearance.theme")
        apply_tui_theme(theme) if transaction.fetch("changed_ids").include?("appearance.theme")
        state = synchronized_state do
          current = normalized_state
          metadata = current.fetch("metadata")
          head_provider = normalized_configured_provider(@config.setting("agent.head_harness"))
          worker_provider = normalized_configured_provider(@config.setting("agent.worker_harness"))
          metadata["active_head_harness"] = Meringue::Harness::Registry.public_provider_name(head_provider)
          metadata["active_worker_harness"] = Meringue::Harness::Registry.public_provider_name(worker_provider)
          metadata["active_head_harness_label"] = Meringue::Harness::Registry.provider_label(head_provider)
          metadata["active_worker_harness_label"] = Meringue::Harness::Registry.provider_label(worker_provider)
          # Keep the old shared key as the worker-side compatibility fallback.
          metadata["active_harness"] = metadata.fetch("active_worker_harness")
          metadata["active_harness_label"] = metadata.fetch("active_worker_harness_label")
          metadata["harness_generation"] = metadata.fetch("harness_generation", 0).to_i + 1
          metadata["agent_session_defaults"] = configured_session_defaults
          metadata["settings_schema_version"] = Config::Schema::VERSION
          metadata["config_fingerprint"] = transaction.fetch("fingerprint")

          changed_ids = transaction.fetch("changed_ids")
          outcome = transaction["onboarding_outcome"]
          log_message = "Saved #{changed_ids.length} configuration setting#{changed_ids.length == 1 ? "" : "s"}"
          log_message = "#{log_message}: #{changed_ids.join(", ")}" unless changed_ids.empty?
          log_message = "#{log_message}; setup #{outcome}" if outcome
          log_ids = append_log(
            current,
            source_type: "kernel",
            source_id: nil,
            level: "info",
            message: "#{log_message}.",
            # IDs only: provider environment values must never enter logs.
            details: {
              "changed_setting_ids" => changed_ids,
              "restart_required" => transaction.fetch("restart_required"),
              "config_path" => config_path,
              "onboarding_outcome" => outcome,
              "onboarding_version" => transaction["onboarding_version"]
            }.compact
          )
          touch_state!(current)
          store.save(current)
          [current, log_ids]
        end

        accepted_result(
          command_id,
          command_type,
          config_path,
          configuration_saved_message(transaction, overridden_settings: overridden_settings),
          {
            "changed_setting_ids" => transaction.fetch("changed_ids"),
            "restart_required" => transaction.fetch("restart_required"),
            "live_applied" => transaction.fetch("live_applied"),
            "config_path" => config_path,
            "fingerprint" => transaction.fetch("fingerprint"),
            "theme" => theme,
            "github_support" => github_support_enabled?(state.first),
            "saved_but_overridden" => overridden_settings,
            "onboarding_outcome" => transaction["onboarding_outcome"],
            "onboarding_version" => transaction["onboarding_version"]
          }.compact,
          state.last
        )
      rescue Config::StaleRevisionError => e
        configuration_rejected_result(command_id, command_type, e.message, { "_stale" => e.message })
      rescue Config::ValidationError => e
        configuration_rejected_result(command_id, command_type, "Configuration has #{e.field_errors.length} invalid setting#{e.field_errors.length == 1 ? "" : "s"}.", e.field_errors)
      rescue Config::ParseError, Config::LockError, Config::PersistenceError => e
        configuration_rejected_result(command_id, command_type, "Configuration was not saved: #{e.message}", { "_configuration" => e.message })
      end

      def configuration_rejected_result(command_id, command_type, message, field_errors)
        result = rejected_result(command_id, command_type, message, field_errors.map { |id, error| "#{id}: #{error}" })
        result["result"] = { "field_errors" => field_errors }
        result
      end

      def configuration_saved_message(transaction, overridden_settings: {})
        count = transaction.fetch("changed_ids").length
        restart = transaction.fetch("restart_required")
        message = "Saved #{count} configuration setting#{count == 1 ? "" : "s"} atomically to #{config_path}."
        if transaction["onboarding_outcome"]
          message = "#{message} Setup #{transaction.fetch("onboarding_outcome")}."
        end
        message = "#{message} Restart Meringue to apply: #{restart.join(", ")}." unless restart.empty?
        unless overridden_settings.empty?
          badges = overridden_settings.map { |id, source| "#{id} by #{source}" }.join(", ")
          message = "#{message} Saved but overridden: #{badges}."
        end
        message
      end

      def config_with_runtime_overrides(saved_file_config)
        return saved_file_config unless config.respond_to?(:overrides) && !config.overrides.empty?

        Config.new(
          Config.deep_merge(saved_file_config.to_file_h, config.overrides),
          path: saved_file_config.path,
          loaded: true,
          file_data: saved_file_config.to_file_h,
          overrides: config.overrides,
          override_sources: config.override_sources
        )
      end

      def apply_runtime_config_update(updated_config, changed_ids)
        return unless @runtime_config_updater

        parameters = @runtime_config_updater.respond_to?(:parameters) ? @runtime_config_updater.parameters : []
        accepts_keywords = parameters.any? { |kind, name| kind == :keyrest || (%i[key keyreq].include?(kind) && name == :changed_ids) }
        if accepts_keywords
          @runtime_config_updater.call(updated_config, changed_ids: changed_ids)
        else
          @runtime_config_updater.call(updated_config)
        end
      end

      def normalized_configured_provider(provider)
        Meringue::Harness::Registry.normalize_provider!(provider)
      rescue ArgumentError
        Meringue::Harness::Registry::DEFAULT_PROVIDER
      end

      def set_theme(command_id, command_type, payload)
        requested_theme = value_at(payload, "theme", "Theme", "name", "Name")
        return rejected_result(command_id, command_type, "Theme was not changed.", ["theme is required"]) if blank?(requested_theme)

        theme = normalized_theme_name(requested_theme)
        unless theme_names.include?(theme)
          return rejected_result(
            command_id,
            command_type,
            "Unknown theme: #{requested_theme}",
            ["available themes: #{theme_names.join(", ")}"]
          )
        end

        saved = Config.save_tui_theme!(theme, path: config_path)
        @config = config_with_runtime_overrides(saved)
        apply_tui_theme(theme)

        state = normalized_state
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: "info",
          message: "Set TUI theme to #{theme}.",
          details: { "theme" => theme, "config_path" => config_path }
        )
        touch_state!(state)
        store.save(state)

        accepted_result(
          command_id,
          command_type,
          theme,
          "Set TUI theme to #{theme} and saved it to #{config_path}.",
          { "theme" => theme, "config_path" => config_path, "available_themes" => theme_names },
          log_ids
        )
      rescue Config::ParseError => e
        rejected_result(command_id, command_type, "Theme was not changed because config could not be read.", [e.message])
      end

      # Records that first-run setup finished (or was skipped) so the TUI stops
      # opening it by itself. The flow itself writes nothing: it applies each
      # choice as an ordinary kernel command and ends with this one, so the kernel
      # stays the only writer of the config file and the marker is journaled and
      # logged like every other command.
      #
      # Deliberately not head-proposable: it is UI lifecycle, like `/jump` and the
      # pickers, and a head has no way to know whether a human saw the flow.
      def complete_onboarding(command_id, command_type, payload)
        requested = value_at(payload, "outcome", "Outcome")
        outcome = requested.to_s.strip.downcase
        outcome = "completed" if outcome.empty?
        unless Config::ONBOARDING_OUTCOMES.include?(outcome)
          return rejected_result(
            command_id,
            command_type,
            "First-run setup was not recorded.",
            ["outcome must be one of: #{Config::ONBOARDING_OUTCOMES.join(", ")}"]
          )
        end

        version = Config::ONBOARDING_VERSION
        Config.save_onboarding!(outcome: outcome, version: version, path: config_path)

        state = normalized_state
        message = if outcome == "skipped"
                    "Skipped first-run setup. It will not open again; run /setup any time."
                  else
                    "Completed first-run setup."
                  end
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: "info",
          message: message,
          details: { "outcome" => outcome, "onboarding_version" => version, "config_path" => config_path }
        )
        touch_state!(state)
        store.save(state)

        accepted_result(
          command_id,
          command_type,
          outcome,
          "#{message} Saved to #{config_path}.",
          { "outcome" => outcome, "onboarding_version" => version, "config_path" => config_path },
          log_ids
        )
      rescue Config::ParseError => e
        rejected_result(command_id, command_type, "First-run setup was not recorded because config could not be read.", [e.message])
      end

      def set_harness(command_id, command_type, payload)
        requested_provider = value_at(payload, "provider", "Provider", "harness", "Harness")
        return synchronized_state { rejected_result(command_id, command_type, "Harness was not changed.", ["provider is required"]) } if blank?(requested_provider)

        provider = normalize_selectable_harness_provider(requested_provider)
        unless provider
          supported = Meringue::Harness::Registry.supported_provider_names.join(", ")
          return synchronized_state do
            rejected_result(command_id, command_type, "Unsupported harness provider #{requested_provider.inspect}. Choose one of: #{supported}.", ["unsupported_harness_provider"])
          end
        end
        role = value_at(payload, "role", "Role").to_s.strip.downcase
        unless role.empty? || %w[head worker].include?(role)
          return synchronized_state { rejected_result(command_id, command_type, "Harness was not changed.", ["role must be head or worker"]) }
        end

        proposing_head_id = present_string(value_at(payload, "_head_id", "head_id", "HeadID", "headId"))
        initial = synchronized_state do
          state = normalized_state
          blockers = active_harness_selection_blockers(state) - [proposing_head_id].compact
          {
            "blockers" => blockers,
            "head" => active_harness_provider(state, role: "head"),
            "worker" => active_harness_provider(state, role: "worker")
          }
        end
        if initial.fetch("blockers").any?
          active_agents = initial.fetch("blockers")
          return synchronized_state do
            rejected_result(command_id, command_type, "Harness was not changed because #{active_agents.length} agent#{active_agents.length == 1 ? " is" : "s are"} active or working: #{active_agents.join(", ")}.", ["active_agents", *active_agents])
          end
        end

        head_provider = role == "worker" ? initial.fetch("head") : provider
        worker_provider = role == "head" ? initial.fetch("worker") : provider
        session_default_changes = harness_switch_session_default_changes(
          head_provider: head_provider,
          worker_provider: worker_provider
        )
        saved = Config.save_harness_defaults!(
          head_provider: head_provider,
          worker_provider: worker_provider,
          session_default_changes: session_default_changes,
          path: config_path
        )
        @config = config_with_runtime_overrides(saved)
        role_ids = role.empty? ? %w[agent.head_harness agent.worker_harness] : ["agent.#{role}_harness"]
        apply_runtime_config_update(@config, role_ids)
        runtime_head_provider = normalized_configured_provider(@config.setting("agent.head_harness"))
        runtime_worker_provider = normalized_configured_provider(@config.setting("agent.worker_harness"))

        synchronized_state do
          state = normalized_state
          previous = role == "head" ? active_harness_provider(state, role: "head") : active_harness_provider(state, role: "worker")
          now = timestamp
          metadata = state.fetch("metadata")
          public_head = Meringue::Harness::Registry.public_provider_name(runtime_head_provider)
          public_worker = Meringue::Harness::Registry.public_provider_name(runtime_worker_provider)
          metadata["active_head_harness"] = public_head
          metadata["active_worker_harness"] = public_worker
          metadata["active_head_harness_label"] = Meringue::Harness::Registry.provider_label(runtime_head_provider)
          metadata["active_worker_harness_label"] = Meringue::Harness::Registry.provider_label(runtime_worker_provider)
          metadata["active_harness"] = public_worker
          metadata["active_harness_label"] = metadata.fetch("active_worker_harness_label")
          # Keep status and `/config` on the same effective role-aware defaults immediately after
          # a harness switch; reconciliation should not be the first place this becomes visible.
          metadata["agent_session_defaults"] = configured_session_defaults
          metadata["harness_selected_at"] = now
          changed = previous != provider
          metadata["harness_generation"] = metadata.fetch("harness_generation", 0).to_i + (changed ? 1 : 0)
          scope = role.empty? ? "future heads and workers" : "future #{role}s"
          label = Meringue::Harness::Registry.provider_label(provider)
          log_ids = append_log(state, source_type: "kernel", source_id: nil, level: "info", message: "Selected #{label} harness for #{scope}.", details: { "active_head_harness" => public_head, "active_worker_harness" => public_worker, "config_path" => config_path })
          touch_state!(state, now)
          store.save(state)
          accepted_result(command_id, command_type, Meringue::Harness::Registry.public_provider_name(provider), "Selected #{label} for #{scope} and saved it to #{config_path}.", { "active_harness" => metadata.fetch("active_harness"), "active_head_harness" => public_head, "active_worker_harness" => public_worker, "role" => role.empty? ? nil : role, "config_path" => config_path }, log_ids)
        end
      rescue Config::ParseError, Config::ValidationError, Config::LockError => e
        synchronized_state { rejected_result(command_id, command_type, "Harness was not changed: #{e.message}", [e.message]) }
      end

      # A harness owns the valid thinking vocabulary, while model references remain deliberately
      # catalog-independent (a cached catalog may be stale and exact provider references are a
      # supported escape hatch). Re-save the effective future role values alongside a harness
      # change so an old `off`/`ultra` value cannot survive in config and poison the next spawn.
      # Existing agent records are never touched: their session settings are already effective.
      def harness_switch_session_default_changes(head_provider:, worker_provider:)
        current = Config.load(path: config_path)
        data = current.to_h
        data["harness"] = {} unless data["harness"].is_a?(Hash)
        data["harness"]["head_provider"] = head_provider
        data["harness"]["worker_provider"] = worker_provider
        candidate = Config.new(data, path: current.path, loaded: current.loaded?, file_data: current.to_file_h)
        registry = Meringue::Harness::Registry.new(config: candidate)
        providers = { "head" => head_provider.to_s, "worker" => worker_provider.to_s }

        values = providers.each_with_object({}) do |(role, provider), changes|
          defaults = begin
            registry.session_defaults(provider: provider)
          rescue ArgumentError, Meringue::Harness::MissingProviderError
            # A future harness may have no model/thinking argv contract. Preserve its neutral
            # values rather than trying the same unsupported provider lookup a second time.
            nil
          end
          role_defaults = defaults&.fetch("roles", {})&.fetch(role, {}) || {}
          configured_model = candidate.setting("agent.#{role}_model", env: {})
          configured_thinking = candidate.setting("agent.#{role}_thinking", env: {})
          configured_model_source = Meringue::Config::Schema.fetch("agent.#{role}_model").source(candidate, env: {})
          configured_thinking_source = Meringue::Config::Schema.fetch("agent.#{role}_thinking").source(candidate, env: {})
          model = if configured_model_source == "file" && Meringue::Harness::ModelReference.valid?(configured_model)
                    configured_model
                  else
                    role_defaults.fetch("model", configured_model)
                  end
          thinking = if configured_thinking_source == "file" && Meringue::Harness::Registry.thinking_levels_for(provider).include?(configured_thinking.to_s)
                       configured_thinking
                     else
                       role_defaults.fetch("thinking_level", configured_thinking)
                     end
          model = Meringue::Harness::Registry::DEFAULT_MODEL unless Meringue::Harness::ModelReference.valid?(model)
          thinking = Meringue::Harness::Registry::DEFAULT_THINKING_LEVEL unless Meringue::Harness::Registry.thinking_levels_for(provider).include?(thinking.to_s)
          changes["agent.#{role}_model"] = model
          changes["agent.#{role}_thinking"] = thinking
          changes
        end
        values
      rescue Config::ParseError
        {}
      end
    end
  end
end
