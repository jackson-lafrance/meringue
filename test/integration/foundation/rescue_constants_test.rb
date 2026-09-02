# frozen_string_literal: true

require "test_helper"
require "support/foundation_support"

# Ruby resolves the constants in `rescue A, B` lazily, only when an exception reaches the clause
# and did not match an earlier entry, and `raise X, "msg"` only checks that `X` is an exception
# class at the moment it runs. A misspelled or mis-namespaced constant in either place therefore
# loads and passes every test that never exercises the failure path, then raises `NameError` (or
# `TypeError`, when the constant is a module) at exactly the moment the code was written to handle
# a failure. That is how a `rescue Shellwords::ParseError` turned a config typo into a failed kernel
# command, and how two supervisor adapters raised a marker module instead of their transient error.
#
# This test resolves every such constant from the lexical scope of its line, the same way Ruby
# would, so the mistake fails here instead of in the one failure path nobody hit.
class FoundationRescueConstantsTest < Minitest::Test
  SCOPE_LINE = /\A(\s*)(?:module|class)\s+([A-Z][\w:]*)\s*(?:<\s*[\w:]+)?\s*\z/
  END_LINE = /\A(\s*)end\b/
  RESCUE_CLAUSE = /\brescue\s+([A-Z][\w:]*(?:\s*,\s*[A-Z][\w:]*)*)(?=\s*(?:=>|then|\z|;))/
  RAISE_CLAUSE = /\braise\s+([A-Z][\w:]*)(?=\s*(?:,|\(|\.new\b|\z|;))/

  def test_every_rescued_and_raised_constant_resolves_from_its_lexical_scope
    offenders = []
    scanned = 0

    FoundationSupport.library_files.each do |path|
      scan_file(path) do |line_number, kind, constant, nesting|
        scanned += 1
        resolved = resolve(constant, nesting)
        location = "#{relative(path)}:#{line_number} #{kind} #{constant}"
        if resolved.nil?
          offenders << "#{location} does not resolve, so the clause raises NameError instead of handling the failure"
        elsif kind == "raise" && !(resolved.is_a?(Class) && resolved <= Exception)
          offenders << "#{location} is #{resolved.inspect}, not an exception class, so raise fails with TypeError"
        elsif !resolved.is_a?(Module)
          offenders << "#{location} is #{resolved.inspect}, which rescue cannot match"
        end
      end
    end

    # Guard against the scan itself silently matching nothing after a refactor of the patterns.
    assert_operator scanned, :>, 100, "expected the scan to find rescue/raise constants across lib/"
    assert_empty offenders, "fix the constant path or point at the exception class:\n  #{offenders.join("\n  ")}"
  end

  private

  # Yields [line_number, kind, constant, nesting] for every constant named by a `rescue` list or a
  # `raise` first argument. A `rescue` may name any module (`IO::WaitReadable` is a module that
  # exception classes include), so only `raise` demands an exception class. `nesting` is the list of enclosing `module`/`class` names, outermost
  # first, tracked from indentation: this codebase indents consistently, so a scope closes at the
  # first later `end` at the same or lower indentation. One-line `class X < Y; end` never opens one.
  def scan_file(path)
    scopes = []
    File.foreach(path).with_index(1) do |raw, line_number|
      line = raw.chomp
      if (closing = END_LINE.match(line))
        scopes.pop while scopes.any? && scopes.last[:indent] >= closing[1].length
      end
      if (opening = SCOPE_LINE.match(line))
        scopes << { indent: opening[1].length, name: opening[2] }
        next
      end

      code = strip_comment(line)
      nesting = scopes.map { |scope| scope[:name] }
      if (rescued = RESCUE_CLAUSE.match(code))
        rescued[1].split(",").map(&:strip).each { |constant| yield line_number, "rescue", constant, nesting }
      end
      if (raised = RAISE_CLAUSE.match(code))
        yield line_number, "raise", raised[1], nesting
      end
    end
  end

  # Try the constant as written from the innermost scope outward, mirroring lexical lookup:
  # `A::B::X`, `A::X`, then `X` at the top level.
  def resolve(constant, nesting)
    candidates = nesting.length.downto(0).map do |depth|
      [*nesting.first(depth), constant].join("::")
    end
    candidates.each do |candidate|
      return Object.const_get(candidate)
    rescue NameError
      next
    end
    nil
  end

  # Drop a trailing `# ...` comment without disturbing `#{}` interpolation or quoted `#`.
  def strip_comment(line)
    in_string = nil
    line.each_char.with_index do |char, index|
      if in_string
        in_string = nil if char == in_string
      elsif char == '"' || char == "'"
        in_string = char
      elsif char == "#"
        return line[0...index]
      end
    end
    line
  end

  def relative(path)
    path.delete_prefix("#{FoundationSupport::REPO_ROOT}/")
  end
end
