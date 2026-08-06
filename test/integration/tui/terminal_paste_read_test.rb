# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "stringio"

# The bracketed-paste reader is the first place a paste can cost real time: one
# `getch` per character is one syscall per byte, which is ~0.5s of latency
# before the app has even seen a 3000-line paste. These cover the chunked read
# and the pushback that keeps it lossless.
class TuiTerminalPasteReadTest < Minitest::Test
  Terminal = Meringue::TUI::Terminal

  # An IO-backed input shaped like a raw tty: IO.select accepts it through
  # #to_io, and it can serve both a bulk read and a single character.
  class PipeInput
    def initialize(io, bulk: true)
      @io = io
      @bulk = bulk
    end

    def to_io
      @io
    end

    def tty?
      true
    end

    def getch
      @io.readpartial(1)
    end

    def read_nonblock(length, exception: true)
      raise NoMethodError, "bulk reads disabled" unless @bulk

      @io.read_nonblock(length, exception: exception)
    end

    def respond_to_missing?(name, include_private = false)
      return false if name == :read_nonblock && !@bulk

      super
    end

    def respond_to?(name, include_private = false)
      return false if name.to_sym == :read_nonblock && !@bulk

      super
    end
  end

  def test_a_large_bracketed_paste_arrives_as_one_paste_event
    text = Array.new(3_000) { |index| "line #{index} of a pasted blob that is long enough to matter for the read path" }.join("\n")

    key = read_key_after("\e[200~#{text}\e[201~")

    assert_equal "paste", key.fetch("type")
    assert_equal text, key.fetch("text")
    assert_operator text.length, :>, 100_000, "the payload has to exceed one pipe buffer to exercise chunked reads"
  end

  def test_bytes_typed_after_the_paste_terminator_are_not_swallowed
    terminal, writer = terminal_with_input
    write_async(writer, "\e[200~pasted body\e[201~hi")

    paste = terminal.read_key(timeout: 1)
    assert_equal({ "type" => "paste", "text" => "pasted body" }, paste)
    assert_equal "hi", terminal.read_key(timeout: 1)
  end

  def test_an_escape_sequence_after_the_paste_is_parsed_as_its_own_key
    terminal, writer = terminal_with_input
    write_async(writer, "\e[200~body\e[201~\e[D")

    assert_equal({ "type" => "paste", "text" => "body" }, terminal.read_key(timeout: 1))
    assert_equal "\e[D", terminal.read_key(timeout: 1)
  end

  def test_a_second_paste_in_the_same_burst_is_still_delivered
    terminal, writer = terminal_with_input
    write_async(writer, "\e[200~first\e[201~\e[200~second\e[201~")

    assert_equal({ "type" => "paste", "text" => "first" }, terminal.read_key(timeout: 1))
    assert_equal({ "type" => "paste", "text" => "second" }, terminal.read_key(timeout: 1))
  end

  def test_an_unterminated_paste_falls_back_to_the_raw_sequence
    key = read_key_after("\e[200~half a paste")

    assert_equal "\e[200~half a paste", key
  end

  def test_a_paste_split_across_writes_is_reassembled
    terminal, writer = terminal_with_input
    write_async(writer, "\e[200~first chunk ")
    write_async(writer, "second chunk\e[201~", delay: 0.01)

    assert_equal({ "type" => "paste", "text" => "first chunk second chunk" }, terminal.read_key(timeout: 1))
  end

  def test_inputs_without_a_bulk_read_still_work_one_character_at_a_time
    key = read_key_after("\e[200~small paste\e[201~", bulk: false)

    assert_equal({ "type" => "paste", "text" => "small paste" }, key)
  end

  def test_utf8_pasted_content_survives_the_chunked_read
    text = "héllo → wörld ✓"

    key = read_key_after("\e[200~#{text}\e[201~")

    assert_equal text, key.fetch("text")
    assert_equal Encoding::UTF_8, key.fetch("text").encoding
  end

  def test_a_plain_text_burst_is_read_in_one_pass
    terminal, writer = terminal_with_input
    write_async(writer, "#{"pasted without brackets " * 100}\e[D")

    assert_equal "pasted without brackets " * 100, terminal.read_key(timeout: 1)
    assert_equal "\e[D", terminal.read_key(timeout: 1)
  end

  private

  def terminal_with_input(bulk: true)
    reader, writer = IO.pipe
    @pipes ||= []
    @pipes << [reader, writer]
    terminal = Terminal.new(input: PipeInput.new(reader, bulk: bulk), output: StringIO.new)
    terminal.define_singleton_method(:interactive?) { true }
    [terminal, writer]
  end

  # A paste larger than the pipe buffer blocks the writer until the reader
  # drains it, which is exactly the streaming case worth covering.
  def write_async(writer, payload, delay: 0)
    @writers ||= []
    @writers << Thread.new do
      sleep delay if delay.positive?
      writer.write(payload)
    end
  end

  def read_key_after(payload, bulk: true)
    terminal, writer = terminal_with_input(bulk: bulk)
    write_async(writer, payload)
    terminal.read_key(timeout: 1)
  end

  def teardown
    Array(@writers).each { |thread| thread.join(2) }
    Array(@pipes).each do |reader, writer|
      writer.close unless writer.closed?
      reader.close unless reader.closed?
    end
  end
end
