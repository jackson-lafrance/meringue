# frozen_string_literal: true

require "json"
require_relative "style"

module Meringue
  module TUI
    # Versioned description of the configurable dashboard footer. The focused
    # worker's two status surfaces intentionally do not participate: they keep
    # their hand-tuned renderers and defaults regardless of this document.
    class StatusBarLayout
      VERSION = 2
      STATE_KEY = "_status_bar_layout"
      CONFIG_PATH = %w[tui status_bar_layout].freeze
      ZONES = %w[left right].freeze
      COMPONENT_IDS = %w[open_pull_requests workers heads harness model thinking].freeze
      COMPONENT_LABELS = {
        "open_pull_requests" => "Open PRs",
        "workers" => "Workers",
        "heads" => "Heads",
        "harness" => "Harness",
        "model" => "Model",
        "thinking" => "Thinking"
      }.freeze
      COMPONENT_DESCRIPTIONS = {
        "open_pull_requests" => "Open pull requests across the AgentTree",
        "workers" => "Currently working workers",
        "heads" => "Currently working heads",
        "harness" => "Shared or role-specific harnesses",
        "model" => "Shared or role-specific model defaults",
        "thinking" => "Shared or role-specific thinking defaults"
      }.freeze
      COMPONENT_ALIASES = {
        "prs" => "open_pull_requests",
        "pull_requests" => "open_pull_requests",
        "worker_count" => "workers",
        "head_count" => "heads",
        "reasoning" => "thinking",
        "thinking_level" => "thinking"
      }.freeze
      DEFAULTS = {
        "version" => VERSION,
        "bottom" => {
          "left" => %w[open_pull_requests workers heads],
          "right" => %w[harness model thinking]
        }
      }.freeze

      class << self
        def default_configuration
          deep_copy(DEFAULTS)
        end

        def default_items(zone)
          DEFAULTS.fetch("bottom").fetch(canonical_zone(zone), []).dup
        end

        def component_label(component)
          COMPONENT_LABELS.fetch(canonical_component(component), component.to_s.tr("_", " ").capitalize)
        end

        def component_description(component)
          COMPONENT_DESCRIPTIONS.fetch(canonical_component(component), "Bottom status-bar component")
        end

        def canonical_zone(zone)
          zone.to_s.strip.downcase == "right" ? "right" : "left"
        end

        def canonical_component(component)
          key = component.to_s.strip.downcase.tr(" -", "__").gsub(/_+/, "_")
          COMPONENT_ALIASES.fetch(key, key)
        end

        # Returns one complete bottom-only document or nil. Version-one layouts
        # are migrated by reading only their bottom bar; customizations of the
        # focused-worker surfaces are deliberately retired.
        def normalize(value)
          value = value.data if value.respond_to?(:data)
          document = parse(value)
          return nil unless document.is_a?(Hash)

          version = document["version"] || document["schema_version"] || 1
          return migrate_version_one(document) if version == 1 || version == "1"
          return nil unless version == VERSION || version == VERSION.to_s

          bottom = document["bottom"]
          bottom = document.dig("bars", "bottom") unless bottom.is_a?(Hash)
          return nil unless bottom.is_a?(Hash)

          seen = []
          zones = ZONES.to_h do |zone|
            raw = bottom[zone]
            raw = [] if raw.nil?
            return nil unless raw.is_a?(Array)

            components = raw.map do |entry|
              entry = entry["id"] || entry[:id] if entry.is_a?(Hash)
              canonical_component(entry)
            end
            return nil unless components.all? { |component| COMPONENT_IDS.include?(component) }
            return nil unless components.uniq.length == components.length
            return nil unless (seen & components).empty?

            seen.concat(components)
            [zone, components]
          end
          { "version" => VERSION, "bottom" => zones }
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

        def serialized(value)
          normalized = normalize(value)
          normalized ? JSON.generate(normalized) : ""
        end

        def valid_serialized?(value)
          value.to_s.empty? || !normalize(value).nil?
        end

        def compose_zone(layout, zone, components, separator: " · ")
          normalized = normalize(layout) || default_configuration
          output = []
          normalized.dig("bottom", canonical_zone(zone)).each do |component|
            segments = components[component] || components[component.to_sym]
            next if Array(segments).empty?

            output << [separator, Style::DIM] unless output.empty? || separator.to_s.empty?
            output.concat(Array(segments))
          end
          output
        end

        private

        def migrate_version_one(document)
          source = document["bars"].is_a?(Hash) ? document["bars"] : document
          old_bottom = source["bottom"] || source["bottom_bar"] || source["footer"]
          return default_configuration if old_bottom.nil?
          return nil unless old_bottom.is_a?(Array)
          return default_configuration if old_bottom.empty?

          blocks = old_bottom.filter_map do |entry|
            key = entry.is_a?(Hash) ? (entry["id"] || entry[:id]) : entry
            case key.to_s.strip.downcase
            when "context", "hint"
              %w[open_pull_requests workers heads]
            when "status", "live_status", "model_status"
              %w[harness model thinking]
            end
          end
          return nil if blocks.length != old_bottom.length

          left = blocks.fetch(0, []).dup
          right = blocks.drop(1).flatten
          migrated = { "version" => VERSION, "bottom" => { "left" => left, "right" => right } }
          normalize(migrated)
        end

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

      def zones
        ZONES.to_h { |zone| [zone, items(zone)] }
      end

      def items(zone)
        data.dig("bottom", self.class.canonical_zone(zone)).dup
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

      def compose(zone, components, separator: " · ")
        self.class.compose_zone(data, zone, components, separator: separator)
      end
    end

    # Pure in-memory layout draft shared by the inline Setup page and the direct
    # /status-bar editor. It owns no persistence and never mutates kernel state.
    class StatusBarComposer
      STATE_KEY = "_status_bar_composer"

      class Draft
        attr_reader :baseline_fingerprint, :errors, :global_error

        def initialize(config, initial_value: nil)
          @baseline_fingerprint = config.fingerprint
          @original = initial_value.nil? ? (StatusBarLayout.from_config(config) || StatusBarLayout.new) : StatusBarLayout.new(initial_value)
          @layout = StatusBarLayout.new(@original.to_h)
          @component_index = 0
          @errors = {}
          @global_error = nil
        end

        def layout
          StatusBarLayout.new(@layout.to_h)
        end

        def components
          StatusBarLayout::COMPONENT_IDS
        end

        def component_index
          @component_index.to_i.clamp(0, components.length - 1)
        end

        def selected_component
          components.fetch(component_index)
        end

        def select_component(index)
          @component_index = index.to_i.clamp(0, components.length - 1)
        end

        def select_component_id(component)
          index = components.index(StatusBarLayout.canonical_component(component))
          select_component(index) if index
        end

        def zone_for(component)
          id = StatusBarLayout.canonical_component(component)
          StatusBarLayout::ZONES.find { |zone| @layout.items(zone).include?(id) }
        end

        def item_index(component = selected_component)
          zone = zone_for(component)
          zone ? @layout.items(zone).index(StatusBarLayout.canonical_component(component)) : nil
        end

        def place(component, zone, index = nil)
          id = StatusBarLayout.canonical_component(component)
          return false unless components.include?(id)

          data = @layout.to_h
          StatusBarLayout::ZONES.each { |candidate| data.dig("bottom", candidate).delete(id) }
          unless zone.to_s == "palette"
            destination = StatusBarLayout.canonical_zone(zone)
            target = data.dig("bottom", destination)
            position = index.nil? ? target.length : index.to_i.clamp(0, target.length)
            target.insert(position, id)
          end
          @layout = StatusBarLayout.new(data)
          select_component_id(id)
          clear_save_failure
          true
        end

        def remove(component = selected_component)
          place(component, "palette")
        end

        # Horizontal movement follows the visible bar. At a zone boundary the
        # component crosses alignment; palette components enter the requested edge.
        def nudge_selected(delta)
          direction = delta.to_i.negative? ? -1 : 1
          component = selected_component
          zone = zone_for(component)
          return place(component, direction.negative? ? "left" : "right") unless zone

          current = @layout.items(zone)
          index = current.index(component)
          if direction.negative?
            return place(component, "left", @layout.items("left").length) if zone == "right" && index.zero?
            return place(component, zone, index - 1) if index.positive?
          else
            return place(component, "right", 0) if zone == "left" && index == current.length - 1
            return place(component, zone, index + 1) if index < current.length - 1
          end
          false
        end

        def move_to_edge(edge)
          component = selected_component
          edge.to_s == "right" ? place(component, "right", @layout.items("right").length) : place(component, "left", 0)
        end

        def cycle_selected_location
          case zone_for(selected_component)
          when nil then place(selected_component, "left")
          when "left" then place(selected_component, "right")
          else remove(selected_component)
          end
        end

        def reset!
          @layout = StatusBarLayout.new
          @component_index = 0
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
          raise ArgumentError, "layout is invalid" unless StatusBarLayout.valid_serialized?(@layout.serialized)

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

        def saving_snapshot(saving: false, preview_components: nil, inline: false)
          zones = StatusBarLayout::ZONES.to_h do |zone|
            [zone, @layout.items(zone).map { |component| component_record(component) }]
          end
          {
            "active" => true,
            "inline" => inline == true,
            "layout" => @layout.to_h,
            "zones" => zones,
            "palette" => components.map { |component| component_record(component).merge("zone" => zone_for(component)) },
            "component_index" => component_index,
            "selected_component" => selected_component,
            "preview_components" => preview_components || {},
            "dirty" => dirty?,
            "saving" => saving,
            "error_count" => errors.length,
            "global_error" => global_error
          }.compact
        end

        private

        def component_record(component)
          {
            "id" => component,
            "label" => StatusBarLayout.component_label(component),
            "description" => StatusBarLayout.component_description(component)
          }
        end
      end

      class Pane
        MIN_WIDTH = 48
        MIN_HEIGHT = 12
        FOOTER_SAVE = "Ctrl-S save"
        FOOTER_RESET = "R reset"
        FOOTER_CANCEL = "Esc cancel"
        FOOTER_ACTIONS = [FOOTER_RESET, FOOTER_SAVE, FOOTER_CANCEL].join(" · ")

        def geometry(width:, height:, bounds: nil)
          width = [width.to_i, 1].max
          height = [height.to_i, 1].max
          return { too_small: true, width: width, height: height } if bounds.nil? && (width < MIN_WIDTH || height < MIN_HEIGHT)

          outer = bounds || { x: 2, y: 2, width: [width - 4, 1].max, height: [height - 4, 1].max }
          x = outer.fetch(:x)
          y = outer.fetch(:y)
          available_width = outer.fetch(:width)
          available_height = outer.fetch(:height)
          if bounds && (available_width < 34 || available_height < 8)
            return { too_small: false, compact: true, outer: outer, footer_y: height - 1 }
          end

          preview_width = [available_width, 72].min
          preview = { x: x + [(available_width - preview_width) / 2, 0].max, y: y, width: preview_width, height: 3 }
          spacious = available_height >= 12
          palette_y = y + (spacious ? 4 : 3)
          palette_height = spacious ? 4 : 3
          palette = { x: x, y: palette_y, width: available_width, height: palette_height }
          zones_y = palette_y + palette_height + (spacious ? 1 : 0)
          zones_height = [y + available_height - zones_y, 1].max
          left_width = [available_width / 2, 1].max
          {
            too_small: false,
            outer: outer,
            preview: preview,
            palette: palette,
            left_zone: { x: x, y: zones_y, width: left_width, height: zones_height },
            right_zone: { x: x + left_width + 1, y: zones_y, width: [available_width - left_width - 1, 1].max, height: zones_height },
            footer_y: height - 1
          }
        end

        def hit(snapshot, width:, height:, x:, y:, bounds: nil)
          geometry = geometry(width: width, height: height, bounds: bounds)
          return :cancel if geometry.fetch(:too_small) && y.to_i == height.to_i - 1
          return :inert if geometry.fetch(:too_small)

          return :inert if geometry.fetch(:compact, false)

          if bounds.nil? && y.to_i == geometry.fetch(:footer_y)
            starts = footer_action_starts(width)
            return :reset if within_text?(x, starts.fetch(:reset), FOOTER_RESET)
            return :save if within_text?(x, starts.fetch(:save), FOOTER_SAVE)
            return :cancel if within_text?(x, starts.fetch(:cancel), FOOTER_CANCEL)
          end

          palette_records = Array(snapshot["palette"])
          palette_regions(palette_records, geometry.fetch(:palette)).each do |record|
            return [:component, "palette", record.fetch(:index)] if inside?(x, y, record.fetch(:bounds))
          end
          return [:drop, "palette", palette_records.length] if inside_content?(x, y, geometry.fetch(:palette))

          %w[left right].each do |zone|
            bounds_for_zone = geometry.fetch("#{zone}_zone".to_sym)
            records = Array(snapshot.dig("zones", zone))
            zone_regions(records, bounds_for_zone).each do |record|
              return [:component, zone, record.fetch(:index)] if inside?(x, y, record.fetch(:bounds))
            end
            if inside_content?(x, y, bounds_for_zone)
              index = (y.to_i - bounds_for_zone.fetch(:y) - 1).clamp(0, records.length)
              return [:drop, zone, index]
            end
          end
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
            canvas.write_segments(1, [height - 1, 0].max, [[FOOTER_CANCEL, Style::ACCENT_BOLD]], max_width: [width - 2, 1].max)
            return canvas.render(color: color)
          end

          title = "meringue · bottom status bar"
          canvas.write_segments([(width - title.length) / 2, 0].max, 0, [[title, Style::TITLE]], max_width: width)
          draw_composer(canvas, snapshot, geometry)
          footer = snapshot.fetch("saving", false) ? "Saving…" : "↑↓ select · ←→ move/align · Space place/remove · drag components"
          footer = "#{footer} · unsaved" if snapshot.fetch("dirty", false) && !snapshot.fetch("saving", false)
          starts = footer_action_starts(width)
          canvas.write_segments(1, geometry.fetch(:footer_y), [[footer, Style::DIM]], max_width: [starts.fetch(:reset) - 2, 1].max)
          canvas.write_segments(starts.fetch(:reset), geometry.fetch(:footer_y), [[FOOTER_ACTIONS, Style::DIM]], max_width: [width - starts.fetch(:reset) - 1, 1].max)
          canvas.render(color: color)
        end

        def draw_inline(canvas, snapshot, bounds:)
          geometry = geometry(width: canvas.width, height: canvas.height, bounds: bounds)
          draw_composer(canvas, snapshot, geometry)
        end

        private

        def draw_composer(canvas, snapshot, geometry)
          if geometry.fetch(:compact, false)
            outer = geometry.fetch(:outer)
            lines = ["Bottom bar composer", "Resize to 36+ columns to drag; arrows still work."]
            lines.first(outer.fetch(:height)).each_with_index do |line, index|
              canvas.write_segments(outer.fetch(:x), outer.fetch(:y) + index, [[line, index.zero? ? Style::PANEL_TITLE : Style::DIM]], max_width: outer.fetch(:width))
            end
            return
          end

          selected = snapshot.fetch("selected_component", "").to_s
          draw_preview(canvas, snapshot, geometry.fetch(:preview))

          palette = geometry.fetch(:palette)
          canvas.draw_box(palette.fetch(:x), palette.fetch(:y), palette.fetch(:width), palette.fetch(:height), title: "components · drag to place", style: Style::BORDER)
          palette_regions(Array(snapshot["palette"]), palette).each do |record|
            component = record.fetch(:record)
            active = component.fetch("id") == selected
            placed = !component.fetch("zone", nil).to_s.empty?
            text = "#{placed ? "✓" : "+"} #{component.fetch("label")}"
            canvas.write_segments(record.dig(:bounds, :x), record.dig(:bounds, :y), [[text, active ? Style::ACCENT_BOLD : (placed ? Style::SUCCESS : Style::MUTED)]], max_width: record.dig(:bounds, :width))
          end

          draw_zone(canvas, snapshot, geometry.fetch(:left_zone), "left aligned", "left", selected)
          draw_zone(canvas, snapshot, geometry.fetch(:right_zone), "right aligned", "right", selected)
          error = snapshot.fetch("global_error", "").to_s
          unless error.empty?
            outer = geometry.fetch(:outer)
            canvas.write_segments(outer.fetch(:x), outer.fetch(:y) + outer.fetch(:height) - 1, [["! #{error}", Style::ERROR]], max_width: outer.fetch(:width))
          end
        end

        def draw_preview(canvas, snapshot, bounds)
          canvas.draw_box(bounds.fetch(:x), bounds.fetch(:y), bounds.fetch(:width), bounds.fetch(:height), title: "live bottom bar", style: Style::BORDER_ACTIVE, title_style: Style::PANEL_TITLE)
          components = snapshot.fetch("preview_components", {}) || {}
          layout = snapshot.fetch("layout", StatusBarLayout.default_configuration)
          left = StatusBarLayout.compose_zone(layout, "left", components)
          right = StatusBarLayout.compose_zone(layout, "right", components)
          content_width = [bounds.fetch(:width) - 4, 1].max
          right_width = segment_width(right)
          visible_right = [right_width, content_width].min
          left_width = [content_width - visible_right - (right_width.positive? ? 2 : 0), 0].max
          canvas.write_segments(bounds.fetch(:x) + 2, bounds.fetch(:y) + 1, left, max_width: left_width, default_style: Style::MUTED) if left_width.positive?
          canvas.write_segments(bounds.fetch(:x) + 2 + content_width - visible_right, bounds.fetch(:y) + 1, right, max_width: visible_right, default_style: Style::MUTED) if visible_right.positive?
        end

        def draw_zone(canvas, snapshot, bounds, title, zone, selected)
          canvas.draw_box(bounds.fetch(:x), bounds.fetch(:y), bounds.fetch(:width), bounds.fetch(:height), title: title, style: Style::BORDER_ACTIVE)
          records = Array(snapshot.dig("zones", zone))
          if records.empty?
            canvas.write_segments(bounds.fetch(:x) + 2, bounds.fetch(:y) + 1, [["drop components here", Style::DIM]], max_width: [bounds.fetch(:width) - 4, 1].max)
            return
          end
          zone_regions(records, bounds).each do |record|
            component = record.fetch(:record)
            active = component.fetch("id") == selected
            marker = active ? "› " : "  "
            canvas.write_segments(record.dig(:bounds, :x), record.dig(:bounds, :y), [["#{marker}#{component.fetch("label")}", active ? Style::ACCENT_BOLD : Style::TEXT]], max_width: record.dig(:bounds, :width))
          end
        end

        def palette_regions(records, bounds)
          x = bounds.fetch(:x) + 2
          y = bounds.fetch(:y) + 1
          max_x = bounds.fetch(:x) + bounds.fetch(:width) - 2
          max_y = bounds.fetch(:y) + bounds.fetch(:height) - 1
          records.each_with_index.filter_map do |record, index|
            width = [record.fetch("label", record.fetch("id", "item")).to_s.length + 4, [bounds.fetch(:width) - 4, 1].max].min
            if x + width > max_x
              x = bounds.fetch(:x) + 2
              y += 1
            end
            next if y >= max_y

            region = { index: index, record: record, bounds: { x: x, y: y, width: width, height: 1 } }
            x += width + 1
            region
          end
        end

        def zone_regions(records, bounds)
          records.each_with_index.filter_map do |record, index|
            y = bounds.fetch(:y) + 1 + index
            next if y >= bounds.fetch(:y) + bounds.fetch(:height) - 1

            { index: index, record: record, bounds: { x: bounds.fetch(:x) + 2, y: y, width: [bounds.fetch(:width) - 4, 1].max, height: 1 } }
          end
        end

        def footer_action_starts(width)
          reset = [width.to_i - FOOTER_ACTIONS.length - 1, 1].max
          save = reset + FOOTER_RESET.length + 3
          cancel = save + FOOTER_SAVE.length + 3
          { reset: reset, save: save, cancel: cancel }
        end

        def within_text?(x, start, text)
          x.to_i >= start && x.to_i < start + text.length
        end

        def inside?(x, y, bounds)
          x.to_i >= bounds.fetch(:x) && x.to_i < bounds.fetch(:x) + bounds.fetch(:width) &&
            y.to_i >= bounds.fetch(:y) && y.to_i < bounds.fetch(:y) + bounds.fetch(:height)
        end

        def inside_content?(x, y, bounds)
          x.to_i >= bounds.fetch(:x) + 1 && x.to_i < bounds.fetch(:x) + bounds.fetch(:width) - 1 &&
            y.to_i >= bounds.fetch(:y) + 1 && y.to_i < bounds.fetch(:y) + bounds.fetch(:height) - 1
        end

        def segment_width(segments)
          Array(segments).sum { |segment| segment.is_a?(Array) ? segment.fetch(0, "").to_s.length : segment.to_s.length }
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
