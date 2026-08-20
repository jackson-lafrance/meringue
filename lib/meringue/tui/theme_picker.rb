# frozen_string_literal: true

module Meringue
  module TUI
    # The transient list behind bare `/theme` and `/themes`.
    #
    # Theme changes are process-local previews while the picker is open. The
    # App owns the preview/restore lifecycle; this module keeps the list and
    # index calculations in one small, state-free view model like ModelPicker.
    module ThemePicker
      module_function

      def names
        Style.colorschemes
      end

      def entries
        names.map do |name|
          {
            "name" => name,
            "current" => name == Style.current_colorscheme
          }
        end
      end

      def entry_at(index)
        return nil if names.empty?

        name = names[index.to_i.clamp(0, names.length - 1)]
        name && { "name" => name, "current" => name == Style.current_colorscheme }
      end

      def index_for(name = Style.current_colorscheme)
        index = names.index(name.to_s)
        index || 0
      end
    end
  end
end
