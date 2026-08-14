# frozen_string_literal: true

require "test_helper"
require "timeout"

class TuiAppReconciliationPriorityTest < Minitest::Test
  def test_background_reconciliation_yields_gvl_priority_to_input_rendering
    observed_priorities = Queue.new
    app = Meringue::App.new(
      reconciler: -> { observed_priorities << Thread.current.priority },
      reconcile_interval: 60
    )

    app.send(:start_reconciliation)

    priority = Timeout.timeout(1) { observed_priorities.pop }
    assert_equal Meringue::App::RECONCILE_THREAD_PRIORITY, priority
    assert_operator priority, :<, Thread.current.priority
  ensure
    app&.send(:stop_reconciliation)
  end
end
