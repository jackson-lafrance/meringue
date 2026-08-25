# frozen_string_literal: true

require "json"
require "stringio"

# Shared, hermetic helpers for the TUI integration tests.
#
# Everything here renders into an in-memory Canvas/StringIO: no TTY is claimed,
# no raw mode is entered, no harness process is started, and nothing outside of a
# caller-provided Dir.mktmpdir is written.
module TUISupport
  DEMO_STATE_PATH = File.expand_path("../../fixtures/demo_state.json", __dir__)
  ANSI_PATTERN = /\e\[[0-9;]*[A-Za-z]/

  # A non-interactive stand-in for TUI::Terminal. App#run takes the
  # render-once path with this, so no test ever touches a real terminal.
  class FakeTerminal
    attr_reader :frames, :output

    def initialize(width: 100, height: 32, keys: [], interactive: false, output: StringIO.new)
      @width = width
      @height = height
      @keys = keys.dup
      @interactive = interactive
      @output = output
      @frames = []
    end

    def interactive?
      @interactive
    end

    def dimensions
      [@width, @height]
    end

    def with_screen
      yield
    end

    def raw
      yield
    end

    def write_frame(frame)
      @frames << frame
      @output.write(frame)
    end

    def invalidate_frame!
      @frames << :invalidated
    end

    def read_key(timeout: nil)
      _ = timeout
      @keys.shift
    end
  end

  # Records every state handed to it so tests can assert the TUI never mutates
  # the kernel snapshot it was given.
  class RecordingStateProvider
    attr_reader :calls

    def initialize(state)
      @serialized = JSON.generate(state)
      @calls = 0
    end

    def call
      @calls += 1
      JSON.parse(@serialized)
    end

    def to_proc
      method(:call).to_proc
    end

    def original_state
      JSON.parse(@serialized)
    end
  end

  module_function

  # Fresh, mutable copy of the shipped demo fixture on every call.
  def demo_state
    JSON.parse(File.read(DEMO_STATE_PATH))
  end

  def empty_state
    Meringue::State::Models.empty_state(now: "2026-07-11T00:00:00Z")
  end

  # State shaped the way TUI::App#compose_state shapes it, without running the
  # interactive loop.
  def composed_state(state, chat: {}, navigation: nil, scroll: nil, selection: nil, workspace: nil)
    composed = state.dup
    composed["_chat"] = default_chat_snapshot.merge(stringify(chat))
    composed["_agent_tree_navigation"] = stringify(navigation) if navigation
    composed["_scroll"] = stringify(scroll) if scroll
    composed["_selection"] = stringify(selection) if selection
    composed["_agent_workspace"] = stringify(workspace) if workspace
    composed
  end

  def default_chat_snapshot
    {
      "messages" => [],
      "input_buffer" => "",
      "input_cursor" => 0,
      "pending_count" => 0,
      "slash_suggestion_index" => -1
    }
  end

  def stringify(value)
    case value
    when Hash then value.each_with_object({}) { |(key, entry), result| result[key.to_s] = stringify(entry) }
    when Array then value.map { |entry| stringify(entry) }
    else value
    end
  end

  def layout
    Meringue::TUI::Layout.new
  end

  def render_frame(state, width: 100, height: 32, color: false, layout: nil)
    (layout || Meringue::TUI::Layout.new).render(state, width: width, height: height, color: color)
  end

  def render_lines(state, width: 100, height: 32, color: false, layout: nil)
    render_frame(state, width: width, height: height, color: color, layout: layout).split("\n", -1)
  end

  # Plain text of one pane line (an Array of [text, style] segments).
  def plain_line(line)
    return line.to_s unless line.is_a?(Array)

    line.map { |segment| segment.is_a?(Array) ? segment.fetch(0, "").to_s : segment.to_s }.join
  end

  def plain_lines(lines)
    Array(lines).map { |line| plain_line(line) }
  end

  def strip_ansi(text)
    text.to_s.gsub(ANSI_PATTERN, "")
  end

  def styles_in(line)
    Array(line).filter_map { |segment| segment.is_a?(Array) ? segment.fetch(1, nil) : nil }
  end

  def agent_record(id, overrides = {})
    {
      "id" => id,
      "type" => id.to_s.start_with?("H") ? "head" : "worker",
      "status" => "working",
      "project_id" => nil,
      "issue_id" => nil,
      "harness" => "fake",
      "harness_metadata" => { "title" => "#{id} session" },
      "created_at" => "2026-07-11T00:00:00Z",
      "updated_at" => "2026-07-11T00:00:00Z"
    }.merge(stringify(overrides))
  end

  def issue_record(id, overrides = {})
    {
      "id" => id,
      "project_id" => id.to_s.split("-").first,
      "parent_issue_id" => nil,
      "title" => "Issue #{id}",
      "status" => "working",
      "agent_ids" => [],
      "created_at" => "2026-07-11T00:00:00Z",
      "updated_at" => "2026-07-11T00:00:00Z"
    }.merge(stringify(overrides))
  end

  def project_record(id, overrides = {})
    {
      "id" => id,
      "name" => "Project #{id}",
      "root_path" => ".",
      "status" => "working",
      "created_at" => "2026-07-11T00:00:00Z",
      "updated_at" => "2026-07-11T00:00:00Z"
    }.merge(stringify(overrides))
  end

  def log_record(id, overrides = {})
    {
      "id" => id,
      "timestamp" => "2026-07-11T00:00:00Z",
      "source_type" => "kernel",
      "source_id" => nil,
      "level" => "info",
      "message" => "log #{id}",
      "details" => {}
    }.merge(stringify(overrides))
  end

  def tree_state(projects: [], issues: [], agents: [], selected_agent_id: nil, navigation_active: false)
    state = empty_state.merge(
      "projects" => projects,
      "issues" => issues,
      "agents" => agents
    )
    navigation = if selected_agent_id || navigation_active
                   { "active" => navigation_active, "selected_agent_id" => selected_agent_id }
                 end
    composed_state(state, navigation: navigation)
  end

  # An App wired entirely to in-memory doubles.
  def build_app(terminal: FakeTerminal.new, layout: Meringue::TUI::Layout.new, out: StringIO.new)
    Meringue::TUI::App.new(layout: layout, out: out, terminal: terminal)
  end

  # App#compose_state without the interactive loop; the App keeps this private,
  # and the shipped typing benchmark reaches it the same way.
  def compose_app_state(app, provider, input_buffer = "", slash_index = -1, cursor = nil)
    app.send(:compose_state, provider.respond_to?(:call) ? provider : -> { provider }, input_buffer, slash_index, cursor || input_buffer.length)
  end

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def with_colorscheme(name)
    previous = Meringue::TUI::Style.current_colorscheme
    Meringue::TUI::Style.configure!(name)
    yield
  ensure
    Meringue::TUI::Style.configure!(previous)
  end
end
