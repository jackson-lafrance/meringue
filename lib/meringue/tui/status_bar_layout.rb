# frozen_string_literal: true

require "json"
require_relative "style"

module Meringue
  module TUI
    # The durable, presentation-neutral description of the three status bars.
    #
    # An absent layout is intentional: it means "use the hand-tuned renderer"
    # rather than "use an empty layout". This lets old configurations retain
    # byte-for-byte-compatible rendering while still giving the composer a
    # small, versioned document to save.
    class StatusBarLayout
      VERSION = 1
      STATE_KEY = "_status_bar_layout"
      CONFIG_PATH = %w[tui status_bar_layout].freeze

      BAR_IDS = %w[bottom agent_information focused_worker].freeze
      BAR_LABELS = {
        "bottom" => "Bottom status bar",
        "agent_information" => "Agent-information bar",
        "focused_worker" => "Focused-worker bar"
      }.freeze

      # These are deliberately semantic slots, not strings copied from the
      # current UI. Renderers can change their wording without invalidating a
      # user's layout. Aliases make early experimental configuration and the
      # pre-composer names safe to migrate.
      ITEMS = {
        "bottom" => %w[context status].freeze,
        "agent_information" => %w[identity controls].freeze,
        "focused_worker" => %w[status controls].freeze
      }.freeze
      ITEM_LABELS = {
        "context" => "Context and actions",
        "status" => "Live status",
        "identity" => "Worker identity",
        "controls" => "Controls and commands"
      }.freeze
      ITEM_ALIASES = {
        "hint" => "context",
        "commands" => "controls",
        "actions" => "controls",
        "worker" => "identity",
        "agent" => "identity",
        "agent_info" => "identity",
        "agent-information" => "identity",
        "worker_status" => "status",
        "model_status" => "status",
        "session_status" => "status",
        "worker_controls" => "controls"
      }.freeze
      BAR_ALIASES = {
        "bottom_bar" => "bottom",
        "footer" => "bottom",
        "agent-info" => "agent_information",
        "agent_information_bar" => "agent_information",
        "worker" => "focused_worker",
        "focused-worker" => "focused_worker",
        "focused_worker_bar" => "focused_worker"
      }.freeze

      DEFAULTS = {
        "version" => VERSION,
        "bars" => ITEMS.transform_values(&:dup)
      }.freeze

      class << self
        def default_configuration
          deep_copy(DEFAULTS)
        end

        def default_items(bar)
          ITEMS.fetch(canonical_bar(bar), []).dup
        end

        def bar_label(bar)
          BAR_LABELS.fetch(canonical_bar(bar), bar.to_s)
        end

        def item_label(item)
          ITEM_LABELS.fetch(canonical_item(item), item.to_s.tr("_", " ").capitalize)
        end

        def canonical_bar(bar)
          key = bar.to_s.strip.downcase.tr(" ", "_")
          BAR_ALIASES.fetch(key, key)
        end

        def canonical_item(item)
          key = item.to_s.strip.downcase.tr(" ", "_")
          ITEM_ALIASES.fetch(key, key)
        end

        # Returns a complete, canonical document or nil. A malformed document
        # must never result in a partially applied bar: the caller can simply
        # fall back to the existing renderer.
        def normalize(value)
          value = value.data if value.respond_to?(:data)
          document = parse(value)
          return nil unless document.is_a?(Hash)

          version = document["version"] || document["schema_version"] || VERSION
          return nil unless version == VERSION || version == VERSION.to_s

          source = document["bars"]
          source = document unless source.is_a?(Hash)
          return nil unless source.is_a?(Hash)

          bars = {}
          BAR_IDS.each do |bar|
            raw_items = source[bar]
            if raw_items.nil?
              alias_key = BAR_ALIASES.keys.find { |candidate| BAR_ALIASES[candidate] == bar && source.key?(candidate) }
              raw_items = source[alias_key] if alias_key
            end
            raw_items = default_items(bar) if raw_items.nil?
            return nil unless raw_items.is_a?(Array)

            items = []
            raw_items.each do |item|
              item = item["id"] || item[:id] if item.is_a?(Hash)
              canonical = canonical_item(item)
              # Unknown entries are not migrations: reject the document so the
              # renderer can use its complete built-in bar instead.
              return nil unless ITEMS.fetch(bar).include?(canonical)
              items << canonical unless items.include?(canonical)
            end
            # Empty, partial, and duplicate-only lists are not useful layouts
            # and are usually the result of a failed migration. Restore that
            # bar's defaults instead of silently hiding its controls.
            items = default_items(bar) if items.empty? || items.sort != default_items(bar).sort
            bars[bar] = items
          end

          { "version" => VERSION, "bars" => bars }
        rescue JSON::ParserError, TypeError, NoMethodError
          nil
        end

        def from_config(config)
          return nil unless config.respond_to?(:value)

          candidates = [
            config.value("tui", "status_bar_layout"),
            config.value("tui", "status_bars"),
            config.value("tui", "status_bar"),
            config.value("status_bar_layout"),
            config.value("status_bars")
          ]
          raw = candidates.find { |candidate| !candidate.nil? && candidate != "" }
          normalize(raw)
        end

        def from_state(state)
          normalize((state || {})[STATE_KEY])
        end

        def configured?(state)
          data = from_state(state)
          !data.nil? && data != default_configuration
        end

        def custom_from_state(state)
          data = from_state(state)
          return nil if data.nil? || data == default_configuration

          data
        end

        def custom_for_state(state, bar)
          data = from_state(state)
          return nil if data.nil?
          return nil if data.fetch("bars").fetch(canonical_bar(bar)) == default_items(bar)

          data
        end

        def serialized(value)
          normalized = normalize(value)
          return "" unless normalized

          JSON.generate(normalized)
        end

        def valid_serialized?(value)
          value.to_s.empty? || !normalize(value).nil?
        end

        # Compose only the slots that have content. A stable separator gives
        # custom layouts the same scanning rhythm as the stock bars and makes
        # narrow-terminal truncation deterministic.
        def compose(layout, bar, components, separator: " · ")
          layout = layout.data if layout.respond_to?(:data)
          normalized = normalize(layout) || default_configuration
          order = normalized.fetch("bars").fetch(canonical_bar(bar))
          output = []
          order.each do |item|
            segments = components[ item ] || components[item.to_sym]
            next if Array(segments).empty?

            output << [separator, Style::DIM] unless output.empty? || separator.to_s.empty?
            output.concat(Array(segments))
          end
          output
        end

        def preview_components(bar)
          case canonical_bar(bar)
          when "bottom"
            {
              "context" => [["Esc clears", Style::MUTED]],
              "status" => [["● 2 workers", Style::WORKING]]
            }
          when "agent_information"
            {
              "identity" => [["focused worker · W1", Style::TITLE]],
              "controls" => [["Ctrl-Space  [t Terminal]", Style::ACCENT_BOLD]]
            }
          when "focused_worker"
            {
              "status" => [["● working", Style::WORKING]],
              "controls" => [["Ctrl-Space  T terminal/agent · Q quit", Style::ACCENT_BOLD]]
            }
          else
            {}
          end
        end

        private

        def parse(value)
          return value if value.is_a?(Hash)
          return JSON.parse(value.to_s) if value.is_a?(String) && !value.empty?

          nil
        end

        def deep_copy(value)
          JSON.parse(JSON.generate(value))
        end
      end

      attr_reader :data

      def initialize(value = nil)
        @data = self.class.normalize(value) || self.class.default_configuration
      end

      def bars
        JSON.parse(JSON.generate(data.fetch("bars")))
      end

      def items(bar)
        data.fetch("bars").fetch(self.class.canonical_bar(bar), []).dup
      end

      def configured?(value = data)
        self.class.normalize(value) != self.class.default_configuration
      end

      def to_h
        JSON.parse(JSON.generate(data))
      end

      def serialized
        self.class.serialized(data)
      end

      def compose(bar, components, separator: " · ")
        self.class.compose(data, bar, components, separator: separator)
      end
    end

    # In-memory composer draft. It deliberately has no file I/O; the App emits
    # its changes through the same kernel SaveConfiguration command as Settings.
    class StatusBarComposer
      STATE_KEY = "_status_bar_composer"

      class Draft
        attr_reader :baseline_fingerprint, :errors, :global_error

        def initialize(config, initial_value: nil)
          @config = config
          @baseline_fingerprint = config.fingerprint
          @original = if initial_value.nil?
                        StatusBarLayout.from_config(config) || StatusBarLayout.new
                      else
                        StatusBarLayout.new(initial_value)
                      end
          @layout = StatusBarLayout.new(@original.to_h)
          @bar_index = 0
          @item_indices = StatusBarLayout::BAR_IDS.to_h { |bar| [bar, 0] }
          @errors = {}
          @global_error = nil
        end

        def layout
          StatusBarLayout.new(@layout.to_h)
        end

        def bars
          StatusBarLayout::BAR_IDS
        end

        def bar
          bars.fetch(@bar_index.clamp(0, bars.length - 1))
        end

        def bar_index
          @bar_index
        end

        def items
          @layout.items(bar)
        end

        def item_index
          @item_indices.fetch(bar, 0).clamp(0, [items.length - 1, 0].max)
        end

        def selected_item
          items[item_index]
        end

        def select_bar(index)
          @bar_index = index.to_i.clamp(0, bars.length - 1)
          @item_indices[bar] = item_index
        end

        def cycle_bar(delta)
          select_bar(@bar_index + delta.to_i)
        end

        def select_item(index)
          @item_indices[bar] = index.to_i.clamp(0, [items.length - 1, 0].max)
        end

        def move_selected(delta)
          from = item_index
          to = (from + delta.to_i).clamp(0, [items.length - 1, 0].max)
          move_item(from, to)
        end

        def move_item(from, to)
          current = @layout.items(bar)
          return false if current.empty?

          from = from.to_i.clamp(0, current.length - 1)
          to = to.to_i.clamp(0, current.length - 1)
          item = current.delete_at(from)
          current.insert(to, item)
          replace_items(bar, current)
          @item_indices[bar] = to
          true
        end

        def reset!
          @layout = StatusBarLayout.new
          @item_indices = StatusBarLayout::BAR_IDS.to_h { |bar| [bar, 0] }
          clear_save_failure
        end

        def dirty?
          @layout.to_h != @original.to_h
        end

        def changes
          return {} unless dirty?

          value = @layout.configured? ? @layout.serialized : ""
          { "appearance.status_bar_layout" => value }
        end

        def validate
          @errors = {}
          serialized = @layout.serialized
          raise ArgumentError, "layout is invalid" unless StatusBarLayout.valid_serialized?(serialized)

          true
        rescue ArgumentError => e
          @errors["appearance.status_bar_layout"] = e.message
          false
        end

        def clear_save_failure
          @errors = {}
          @global_error = nil
        end

        def apply_save_failure(message, field_errors = nil)
          @global_error = message.to_s
          @errors.merge!(Config.deep_stringify(field_errors || {}))
        end

        def saving_snapshot(saving: false)
          {
            "active" => true,
            "bars" => bars.map { |candidate| { "id" => candidate, "label" => StatusBarLayout.bar_label(candidate) } },
            "bar" => bar,
            "bar_index" => bar_index,
            "items" => items.map { |item| { "id" => item, "label" => StatusBarLayout.item_label(item) } },
            "item_index" => item_index,
            "selected_item" => selected_item,
            "dirty" => dirty?,
            "saving" => saving,
            "error_count" => errors.length,
            "global_error" => global_error
          }.compact
        end

        private

        def replace_items(candidate_bar, items)
          data = @layout.to_h
          data.fetch("bars")[candidate_bar] = items
          @layout = StatusBarLayout.new(data)
        end
      end

      class Pane
        MIN_WIDTH = 48
        MIN_HEIGHT = 12
        FOOTER = "Tab bar · ↑↓ select · ←→ move"
        FOOTER_ACTIONS = "R reset · Ctrl-S save · Esc cancel"
        FOOTER_CANCEL = "Esc cancel"
        FOOTER_SAVE = "Ctrl-S save"
        FOOTER_RESET = "R reset"
        FOOTER_SEPARATOR = " · "

        def geometry(width:, height:)
          width = [width.to_i, 1].max
          height = [height.to_i, 1].max
          return { too_small: true, width: width, height: height } if width < MIN_WIDTH || height < MIN_HEIGHT

          rail_width = [[width / 3, 25].max, 34].min
          {
            too_small: false,
            footer_y: height - 1,
            body_y: 2,
            body_height: [height - 3, 1].max,
            rail: { x: 1, y: 2, width: rail_width, height: [height - 3, 1].max },
            preview: { x: rail_width + 2, y: 2, width: [width - rail_width - 3, 1].max, height: [height - 3, 1].max }
          }
        end

        def hit(snapshot, width:, height:, x:, y:)
          geometry = geometry(width: width, height: height)
          return :cancel if geometry.fetch(:too_small) && y.to_i == height.to_i - 1
          return :inert if geometry.fetch(:too_small)

          if y.to_i == geometry.fetch(:footer_y)
            cancel_start = width.to_i - FOOTER_CANCEL.length - 1
            save_end = cancel_start - FOOTER_SEPARATOR.length
            save_start = save_end - FOOTER_SAVE.length
            reset_end = save_start - FOOTER_SEPARATOR.length
            reset_start = reset_end - FOOTER_RESET.length
            return :cancel if x.to_i >= cancel_start
            return :save if x.to_i >= save_start && x.to_i < save_end
            return :reset if x.to_i >= reset_start && x.to_i < reset_end
          end

          rail = geometry.fetch(:rail)
          if inside?(x, y, rail)
            index = y.to_i - rail.fetch(:y) - 1
            return [:bar, index] if index.between?(0, Array(snapshot["bars"]).length - 1)
          end
          preview = geometry.fetch(:preview)
          return :inert unless inside?(x, y, preview)

          item_start = preview.fetch(:y) + 3
          index = y.to_i - item_start
          return [:item, index] if index.between?(0, Array(snapshot["items"]).length - 1)

          :inert
        end

        def render(snapshot, width:, height:, color: false)
          width = [width.to_i, 1].max
          height = [height.to_i, 1].max
          canvas = Canvas.new(width: width, height: height)
          geometry = geometry(width: width, height: height)
          if geometry.fetch(:too_small)
            message = "Terminal too small for Status bar composer (need #{MIN_WIDTH}×#{MIN_HEIGHT})"
            canvas.write_segments([(width - message.length) / 2, 0].max, [height / 2, 0].max, [[message, Style::WARNING]], max_width: width)
            canvas.write_segments(1, [height - 1, 0].max, [["Esc cancel", Style::ACCENT_BOLD]], max_width: [width - 2, 1].max)
            return canvas.render(color: color)
          end

          title = "meringue · status bar composer"
          canvas.write_segments([(width - title.length) / 2, 0].max, 0, [[title, Style::TITLE]], max_width: width)
          rail = geometry.fetch(:rail)
          bars = Array(snapshot["bars"])
          selected_bar = snapshot["bar_index"].to_i
          bar_lines = bars.map.with_index do |bar, index|
            marker = index == selected_bar ? "› " : "  "
            style = index == selected_bar ? Style::ACCENT_BOLD : Style::MUTED
            [["#{marker}#{bar.fetch("label", bar.fetch("id", "bar"))}", style]]
          end
          draw_box(canvas, rail, "bars", bar_lines, active: true)

          preview = geometry.fetch(:preview)
          items = Array(snapshot["items"])
          selected_item = snapshot["item_index"].to_i
          lines = [["#{StatusBarLayout.bar_label(snapshot.fetch("bar", "bottom"))} layout", Style::PANEL_TITLE]]
          lines << ["Drag an item, or use ←→ to reorder.", Style::DIM]
          items.each_with_index do |item, index|
            marker = index == selected_item ? "› " : "  "
            style = index == selected_item ? Style::ACCENT_BOLD : Style::TEXT
            lines << ["#{marker}#{item.fetch("label", item.fetch("id", "item"))}", style]
          end
          lines << ["", Style::DIM]
          lines << ["Live preview", Style::PANEL_TITLE]
          sample = StatusBarLayout.preview_components(snapshot.fetch("bar", "bottom"))
          ordered = StatusBarLayout.compose(snapshot_to_layout(snapshot), snapshot.fetch("bar", "bottom"), sample)
          preview_text = ordered.map { |segment| segment.fetch(0, "").to_s }.join
          lines << [preview_text, Style::TEXT]
          error = snapshot.fetch("global_error", "").to_s
          lines << ["! #{error}", Style::ERROR] unless error.empty?
          draw_box(canvas, preview, "preview", lines.map { |text, style| [[text, style]] }, active: true)

          footer = snapshot.fetch("saving", false) ? "Saving…" : FOOTER
          footer = "#{footer} · unsaved" if snapshot.fetch("dirty", false) && !snapshot.fetch("saving", false)
          action_x = [width - FOOTER_ACTIONS.length - 1, 1].max
          canvas.write_segments(1, geometry.fetch(:footer_y), [[footer, Style::DIM]], max_width: [action_x - 2, 1].max)
          canvas.write_segments(action_x, geometry.fetch(:footer_y), [[FOOTER_ACTIONS, Style::DIM]], max_width: [width - action_x - 1, 1].max)
          canvas.render(color: color)
        end

        private

        def snapshot_to_layout(snapshot)
          bars = StatusBarLayout.default_configuration.fetch("bars")
          bars[snapshot.fetch("bar", "bottom")] = Array(snapshot.fetch("items", [])).map { |item| item.fetch("id") }
          { "version" => StatusBarLayout::VERSION, "bars" => bars }
        end

        def inside?(x, y, bounds)
          x.to_i >= bounds.fetch(:x) && x.to_i < bounds.fetch(:x) + bounds.fetch(:width) &&
            y.to_i >= bounds.fetch(:y) && y.to_i < bounds.fetch(:y) + bounds.fetch(:height)
        end

        def draw_box(canvas, bounds, title, lines, active: false)
          canvas.draw_box(bounds.fetch(:x), bounds.fetch(:y), bounds.fetch(:width), bounds.fetch(:height), title: title, style: active ? Style::BORDER_ACTIVE : Style::BORDER)
          lines.first([bounds.fetch(:height) - 2, 0].max).each_with_index do |line, index|
            canvas.write_segments(bounds.fetch(:x) + 2, bounds.fetch(:y) + 1 + index, line, max_width: [bounds.fetch(:width) - 4, 1].max)
          end
        end
      end

      def self.snapshot(state)
        value = (state || {})[STATE_KEY]
        value.is_a?(Hash) ? value : { "active" => false }
      end

      def self.enabled?(state)
        snapshot(state).fetch("active", false) == true
      end
    end
  end
end
