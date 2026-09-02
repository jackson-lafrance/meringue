# frozen_string_literal: true

module Meringue
  module TUI
    # Terminal cell arithmetic for rendered text.
    #
    # A terminal does not render one codepoint per column: East Asian wide
    # characters and most emoji take two cells, while combining marks, joiners,
    # and variation selectors take none. The canvas and the pane helpers measure
    # in cells through this module so a row containing a Japanese title or a
    # `✅` never exceeds the terminal width and displaces every border after it.
    #
    # The tables are a deliberately small, dependency-free approximation of
    # East Asian Width plus the emoji terminals draw wide. They are sorted
    # inclusive ranges searched by bisection.
    module DisplayWidth
      ZERO_WIDTH_RANGES = [
        [0x0300, 0x036F], # combining diacritical marks
        [0x1160, 0x11FF], # Hangul Jamo medial vowels and final consonants
        [0x1AB0, 0x1AFF], # combining diacritical marks extended
        [0x1DC0, 0x1DFF], # combining diacritical marks supplement
        [0x200B, 0x200D], # zero width space, non-joiner, joiner
        [0x20D0, 0x20FF], # combining marks for symbols
        [0xFE00, 0xFE0F], # variation selectors
        [0xFE20, 0xFE2F], # combining half marks
        [0xFEFF, 0xFEFF], # byte order mark
        [0x1F3FB, 0x1F3FF], # emoji skin tone modifiers
        [0xE0020, 0xE007F], # tag characters
        [0xE0100, 0xE01EF] # variation selectors supplement
      ].freeze

      WIDE_RANGES = [
        [0x1100, 0x115F], # Hangul Jamo initial consonants
        [0x231A, 0x231B], # watch, hourglass
        [0x23E9, 0x23EC], # fast-forward, rewind, up/down double triangles
        [0x23F0, 0x23F0], # alarm clock
        [0x23F3, 0x23F3], # hourglass with flowing sand
        [0x25FD, 0x25FE], # medium small squares
        [0x2614, 0x2615], # umbrella with rain drops, hot beverage
        [0x2648, 0x2653], # zodiac signs
        [0x267F, 0x267F], # wheelchair symbol
        [0x2693, 0x2693], # anchor
        [0x26A1, 0x26A1], # high voltage
        [0x26AA, 0x26AB], # medium circles
        [0x26BD, 0x26BE], # soccer ball, baseball
        [0x26C4, 0x26C5], # snowman, sun behind cloud
        [0x26CE, 0x26CE], # ophiuchus
        [0x26D4, 0x26D4], # no entry
        [0x26EA, 0x26EA], # church
        [0x26F2, 0x26F3], # fountain, flag in hole
        [0x26F5, 0x26F5], # sailboat
        [0x26FA, 0x26FA], # tent
        [0x26FD, 0x26FD], # fuel pump
        [0x2705, 0x2705], # check mark button
        [0x270A, 0x270B], # raised fist, raised hand
        [0x2728, 0x2728], # sparkles
        [0x274C, 0x274C], # cross mark
        [0x274E, 0x274E], # cross mark button
        [0x2753, 0x2755], # question and exclamation ornaments
        [0x2757, 0x2757], # heavy exclamation mark
        [0x2795, 0x2797], # heavy plus, minus, division
        [0x27B0, 0x27B0], # curly loop
        [0x27BF, 0x27BF], # double curly loop
        [0x2B1B, 0x2B1C], # large squares
        [0x2B50, 0x2B50], # star
        [0x2B55, 0x2B55], # heavy large circle
        [0x2E80, 0x303E], # CJK radicals, Kangxi radicals, CJK symbols and punctuation
        [0x3041, 0x33FF], # Hiragana, Katakana, Bopomofo, Hangul compatibility, enclosed CJK
        [0x3400, 0x4DBF], # CJK unified ideographs extension A
        [0x4E00, 0x9FFF], # CJK unified ideographs
        [0xA000, 0xA4CF], # Yi syllables and radicals
        [0xAC00, 0xD7A3], # Hangul syllables
        [0xF900, 0xFAFF], # CJK compatibility ideographs
        [0xFE30, 0xFE4F], # CJK compatibility forms
        [0xFF00, 0xFF60], # fullwidth forms
        [0xFFE0, 0xFFE6], # fullwidth signs
        [0x1F300, 0x1F64F], # miscellaneous symbols and pictographs, emoticons
        [0x1F680, 0x1F6FF], # transport and map symbols
        [0x1F900, 0x1F9FF], # supplemental symbols and pictographs
        [0x1FA70, 0x1FAFF], # symbols and pictographs extended-A
        [0x20000, 0x3FFFD] # CJK unified ideographs extensions B and later
      ].freeze

      ZERO_WIDTH_JOINER = "\u200D"

      module_function

      # 0, 1, or 2 terminal cells for one character.
      def char_width(char)
        char = char.to_s
        return 0 if char.empty?

        codepoint = char.ord
        return 0 if codepoint < 0x20 || (0x7F..0x9F).cover?(codepoint)
        # Everything below the first combining block is a plain one-cell glyph,
        # which keeps Latin text out of the table lookups entirely.
        return 1 if codepoint < 0x0300
        return 0 if in_ranges?(ZERO_WIDTH_RANGES, codepoint)
        return 2 if in_ranges?(WIDE_RANGES, codepoint)

        1
      end

      def width(text)
        text = text.to_s
        return text.length if text.ascii_only?

        total = 0
        each_cell_width(text) { |_char, char_cells| total += char_cells }
        total
      end

      # One string per terminal cell. A wide character is followed by "" for the
      # cell it spills into; a zero-width character rides along in the cell of
      # the character before it (or is dropped when nothing precedes it).
      def cells(text)
        text = text.to_s
        return text.chars if text.ascii_only?

        result = []
        each_cell_width(text) do |char, char_cells|
          case char_cells
          when 2 then result.push(char, "")
          when 1 then result << char
          else
            next if result.empty?

            # The continuation cell of a wide character is the empty marker, so
            # the mark attaches to the wide character itself, one cell back.
            target = result.last.empty? ? result.length - 2 : result.length - 1
            result[target] = result[target] + char
          end
        end
        result
      end

      # Longest prefix that fits in +cells+ without splitting a wide character.
      def truncate(text, cells)
        text = text.to_s
        text[0, fit_length(text, cells)]
      end

      # Number of leading characters that fit in +cells+: the character count of
      # `truncate`, for wrappers that slice by character offset but budget by
      # column. Zero-width characters ride with the character before them, so a
      # combining mark or variation selector is never split from its base.
      #
      # With +at_least_one+, a glyph too wide for the budget is still counted
      # (a wide character in a one-cell row), so a wrapper that must make
      # progress never gets 0 back for nonempty text and can never loop.
      def fit_length(text, cells, at_least_one: false)
        text = text.to_s
        limit = cells.to_i
        return 0 if text.empty? || (limit <= 0 && !at_least_one)
        return limit.clamp(at_least_one ? 1 : 0, text.length) if text.ascii_only?

        used = 0
        count = 0
        each_cell_width(text) do |_char, char_cells|
          break if char_cells.positive? && used + char_cells > limit && !(at_least_one && used.zero?)

          used += char_cells
          count += 1
        end
        count
      end

      # Hard-wraps +text+ into pieces of at most +cells+ columns, never splitting
      # a character; the cell-aware `text.scan(/.{1,cells}/)`.
      def slices(text, cells)
        text = text.to_s
        pieces = []
        until text.empty?
          take = fit_length(text, cells, at_least_one: true)
          pieces << text[0, take]
          text = text[take..].to_s
        end
        pieces
      end

      # Cells added by each character, in order, so a wrapper that tracks its
      # own character array (styled characters, say) can budget by column.
      def char_widths(text)
        text = text.to_s
        return Array.new(text.length, 1) if text.ascii_only?

        widths = []
        each_cell_width(text) { |_char, char_cells| widths << char_cells }
        widths
      end

      def ljust(text, cells, pad = " ")
        text = text.to_s
        limit = cells.to_i
        text = truncate(text, limit) if width(text) > limit
        pad = " " if pad.to_s.empty?
        text + pad.to_s * (limit - width(text))
      end

      # Character index of the character drawn at cell +cell+ (or the count of
      # characters when the cell lies past the text), so a mouse column maps
      # back to whole characters instead of landing inside a wide glyph.
      def char_index_at(text, cell)
        text = text.to_s
        target = cell.to_i
        return target.clamp(0, text.length) if text.ascii_only?

        used = 0
        index = 0
        each_cell_width(text) do |_char, char_cells|
          break if char_cells.positive? && used + char_cells > target

          used += char_cells
          index += 1
        end
        index
      end

      # Yields each character with the cells it adds to the line. A character
      # that follows a ZERO WIDTH JOINER is part of the previous glyph (a family
      # emoji is one two-cell glyph, not four), so it adds nothing.
      def each_cell_width(text)
        joined = false
        text.each_char do |char|
          yield char, joined ? 0 : char_width(char)
          joined = char == ZERO_WIDTH_JOINER
        end
      end
      private_class_method :each_cell_width

      def in_ranges?(ranges, codepoint)
        low = 0
        high = ranges.length - 1
        while low <= high
          middle = (low + high) / 2
          range = ranges[middle]
          if codepoint < range[0]
            high = middle - 1
          elsif codepoint > range[1]
            low = middle + 1
          else
            return true
          end
        end
        false
      end
      private_class_method :in_ranges?
    end
  end
end
