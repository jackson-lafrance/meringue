# frozen_string_literal: true

require "fileutils"
require "json"

module Meringue
  class Config
    DEFAULT_PATH = File.expand_path(ENV.fetch("MERINGUE_CONFIG", "~/.meringue/config.toml"))

    class ParseError < StandardError; end

    attr_reader :path, :data, :loaded

    def self.load(path: DEFAULT_PATH)
      expanded_path = File.expand_path(path.to_s)
      return new({}, path: expanded_path, loaded: false) unless File.file?(expanded_path)

      new(parse(File.read(expanded_path), path: expanded_path), path: expanded_path, loaded: true)
    end

    def self.parse(source, path: nil)
      parser = TomlParser.new(source.to_s, path: path)
      parser.parse
    end

    def self.save_tui_theme!(theme, path: DEFAULT_PATH)
      expanded_path = File.expand_path(path.to_s)
      config = load(path: expanded_path)
      data = config.to_h
      data["tui"] = {} unless data["tui"].is_a?(Hash)
      data.fetch("tui").delete("color_scheme")
      data.fetch("tui")["colorscheme"] = theme.to_s
      write_toml(expanded_path, data)
      new(data, path: expanded_path, loaded: true)
    end

    def self.write_toml(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      temp_path = "#{path}.tmp.#{$$}"
      File.write(temp_path, TomlWriter.new(data).to_s)
      File.rename(temp_path, path)
    ensure
      File.delete(temp_path) if temp_path && File.exist?(temp_path)
    end

    def initialize(data, path:, loaded: false)
      @data = deep_stringify(data || {})
      @path = File.expand_path(path.to_s)
      @loaded = loaded
    end

    def loaded?
      !!loaded
    end

    def section(*keys)
      keys.reduce(data) do |current, key|
        return {} unless current.is_a?(Hash)

        current.fetch(key.to_s, {})
      end
    end

    def value(*keys)
      keys.reduce(data) do |current, key|
        return nil unless current.is_a?(Hash)

        current.fetch(key.to_s, nil)
      end
    end

    def with_overrides(overrides)
      self.class.new(deep_merge(data, deep_stringify(overrides || {})), path: path, loaded: loaded?)
    end

    def to_h
      deep_copy(data)
    end

    def self.deep_stringify(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), result| result[key.to_s] = deep_stringify(child) }
      when Array
        value.map { |child| deep_stringify(child) }
      else
        value
      end
    end

    def self.deep_merge(left, right)
      left = deep_stringify(left || {})
      right = deep_stringify(right || {})

      left.merge(right) do |_key, old_value, new_value|
        if old_value.is_a?(Hash) && new_value.is_a?(Hash)
          deep_merge(old_value, new_value)
        else
          new_value
        end
      end
    end

    def self.deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def deep_stringify(value)
      self.class.deep_stringify(value)
    end

    def deep_merge(left, right)
      self.class.deep_merge(left, right)
    end

    def deep_copy(value)
      self.class.deep_copy(value)
    end

    class TomlWriter
      def initialize(data)
        @data = Config.deep_stringify(data || {})
      end

      def to_s
        lines = []
        emit_table(data, [], lines)
        lines << "" unless lines.empty? || lines.last == ""
        lines.join("\n")
      end

      private

      attr_reader :data

      def emit_table(table, path, lines)
        scalars, children = table.partition { |_key, value| !value.is_a?(Hash) }
        unless path.empty?
          lines << "" unless lines.empty?
          lines << "[#{path.join(".")}]"
        end
        scalars.each do |key, value|
          next if value.nil?

          lines << "#{key} = #{format_value(value)}"
        end
        children.each do |key, child|
          emit_table(child, path + [key], lines)
        end
      end

      def format_value(value)
        case value
        when String
          JSON.generate(value)
        when TrueClass, FalseClass
          value ? "true" : "false"
        when Integer
          value.to_s
        when Array
          "[#{value.map { |child| format_value(child) }.join(", ")}]"
        else
          JSON.generate(value.to_s)
        end
      end
    end

    class TomlParser
      def initialize(source, path: nil)
        @source = source
        @path = path
        @root = {}
        @section_path = []
      end

      def parse
        source.each_line.with_index(1) do |line, line_number|
          parse_line(line, line_number)
        end
        root
      end

      private

      attr_reader :source, :path, :root

      def parse_line(line, line_number)
        stripped = strip_comment(line).strip
        return if stripped.empty?

        if stripped.start_with?("[")
          parse_section(stripped, line_number)
        else
          parse_assignment(stripped, line_number)
        end
      end

      def parse_section(text, line_number)
        unless text.end_with?("]") && text.count("[") == 1 && text.count("]") == 1
          raise parse_error(line_number, "invalid section header")
        end

        section = text[1...-1].strip
        raise parse_error(line_number, "empty section header") if section.empty?

        @section_path = section.split(".").map(&:strip)
        raise parse_error(line_number, "invalid section header") if @section_path.any?(&:empty?)

        ensure_section(@section_path, line_number)
      end

      def parse_assignment(text, line_number)
        key, raw_value = split_assignment(text)
        raise parse_error(line_number, "expected key = value") unless key && raw_value

        key_path = key.split(".").map(&:strip)
        raise parse_error(line_number, "invalid key") if key_path.any?(&:empty?)

        target_path = @section_path + key_path[0...-1]
        target = ensure_section(target_path, line_number)
        leaf_key = key_path.last
        target[leaf_key] = parse_value(raw_value.strip, line_number)
      end

      def split_assignment(text)
        in_string = false
        quote = nil
        escaped = false

        text.chars.each_with_index do |char, index|
          if in_string
            if escaped
              escaped = false
            elsif char == "\\" && quote == '"'
              escaped = true
            elsif char == quote
              in_string = false
              quote = nil
            end
            next
          end

          case char
          when '"', "'"
            in_string = true
            quote = char
          when "="
            return [text[0...index].strip, text[(index + 1)..].strip]
          end
        end

        nil
      end

      def parse_value(value, line_number)
        case value
        when /\A".*"\z/m
          parse_double_quoted_string(value, line_number)
        when /\A'.*'\z/m
          value[1...-1]
        when /\A\[(.*)\]\z/m
          parse_array(Regexp.last_match(1), line_number)
        when "true"
          true
        when "false"
          false
        when /\A-?\d+\z/
          value.to_i
        else
          raise parse_error(line_number, "unsupported value #{value.inspect}")
        end
      end

      def parse_double_quoted_string(value, line_number)
        JSON.parse(value)
      rescue JSON::ParserError => e
        raise parse_error(line_number, "invalid string: #{e.message}")
      end

      def parse_array(value, line_number)
        items = split_array_items(value)
        items.map { |item| parse_value(item, line_number) }
      end

      def split_array_items(value)
        items = []
        current = +""
        in_string = false
        quote = nil
        escaped = false

        value.chars.each do |char|
          if in_string
            current << char
            if escaped
              escaped = false
            elsif char == "\\" && quote == '"'
              escaped = true
            elsif char == quote
              in_string = false
              quote = nil
            end
            next
          end

          case char
          when '"', "'"
            in_string = true
            quote = char
            current << char
          when ","
            items << current.strip unless current.strip.empty?
            current = +""
          else
            current << char
          end
        end

        items << current.strip unless current.strip.empty?
        items
      end

      def strip_comment(line)
        in_string = false
        quote = nil
        escaped = false

        line.chars.each_with_index do |char, index|
          if in_string
            if escaped
              escaped = false
            elsif char == "\\" && quote == '"'
              escaped = true
            elsif char == quote
              in_string = false
              quote = nil
            end
            next
          end

          case char
          when '"', "'"
            in_string = true
            quote = char
          when "#"
            return line[0...index]
          end
        end

        line
      end

      def ensure_section(path_parts, line_number)
        path_parts.reduce(root) do |current, part|
          existing = current[part]
          if existing && !existing.is_a?(Hash)
            raise parse_error(line_number, "#{part.inspect} is already set to a non-table value")
          end

          current[part] ||= {}
        end
      end

      def parse_error(line_number, message)
        location = path ? "#{path}:#{line_number}" : "line #{line_number}"
        ParseError.new("#{location}: #{message}")
      end
    end
  end
end
