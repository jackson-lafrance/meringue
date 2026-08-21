# frozen_string_literal: true

# Compatibility entry point for integrations that name the editor separately
# from its persisted layout document. The model, draft, and pane live together
# so preview and persistence cannot drift apart.
require_relative "status_bar_layout"
