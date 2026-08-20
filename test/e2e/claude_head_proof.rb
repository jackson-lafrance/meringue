# frozen_string_literal: true

# Live proof that a Meringue head runs autonomously on the Claude Code backend.
#
# A head is the harder half of the integration: it must receive a large context prompt, work
# read-only, and come back with a single valid HeadResult JSON object that the kernel can apply.
# This exercises the real registry wiring — the same head runner and client the dashboard builds —
# against a real `claude` install, so it spends real tokens and is not part of `rake test`:
#
#   ruby -Ilib test/e2e/claude_head_proof.rb

require "fileutils"
require "json"
require "tmpdir"
require "meringue"

$stdout.sync = true
$failures = []

def check(label, condition, detail = nil)
  puts "  [#{condition ? "PASS" : "FAIL"}] #{label}#{detail ? " — #{detail}" : ""}"
  $failures << label unless condition
  condition
end

root = Dir.mktmpdir("meringue-claude-head")
workspace = File.join(root, "ledger")
FileUtils.mkdir_p(workspace)
# The config lives outside the repository so it cannot show up as a repository change itself.
config_path = File.join(root, "config.toml")
File.write(config_path, <<~TOML)
  [harness]
  provider = "claude"
TOML

Dir.chdir(workspace) do
  system("git", "init", "--quiet", ".", out: File::NULL, err: File::NULL)
  FileUtils.mkdir_p("lib")
  File.write("README.md", "# Ledger\n\nA small billing service.\n")
  File.write("lib/invoice.rb", "class Invoice\n  def total = @lines.sum(&:amount)\nend\n")
  # Committed, so "no repository changes" means what it says instead of just meaning "untracked".
  system("git", "add", "-A", out: File::NULL, err: File::NULL)
  system("git", "-c", "user.email=proof@meringue.test", "-c", "user.name=Proof",
         "commit", "--quiet", "-m", "fixture", out: File::NULL, err: File::NULL)
end

registry = Meringue::Harness::Registry.new(config: Meringue::Config.load(path: config_path))
runner = registry.head_runner(cwd: workspace)
client = runner.harness_client
session_ref = nil

begin
  puts "=== Head runs on the Claude Code backend ==="
  check("registry built the interactive client", client.is_a?(Meringue::Harness::ClaudeInteractiveClient), client.class.name)
  check("head argv is read-only", client.extra_args.each_cons(2).include?(["--tools", "Read,Glob,Grep"]), client.extra_args.inspect)

  snapshot = {
    "projects" => [{ "id" => "P1", "name" => "ledger", "path" => workspace }],
    "issues" => [],
    "agents" => [],
    "questions" => []
  }

  started = Time.now
  session_ref = runner.spawn_head_session(
    user_message: "Add a currency field to invoices so totals can be reported per currency.",
    snapshot: snapshot
  )
  check("head session started", !session_ref.fetch("pid", nil).nil?, "pid #{session_ref["pid"]}")

  result = runner.await_head_result(session_ref)
  puts "  head answered in #{(Time.now - started).round(1)}s"

  check("result is a HeadResult object", result.is_a?(Hash))
  check("result carries the required keys", (%w[title summary commands questions] - result.keys).empty?, result.keys.inspect)
  check("title is present", !result.fetch("title", "").to_s.strip.empty?, result["title"].to_s[0, 80])
  routed = Array(result.fetch("commands", [])).map { |command| command["type"] }
  asked = Array(result.fetch("questions", [])).length
  check("head either routed work or asked a question", routed.any? || asked.positive? || !result["response"].to_s.strip.empty?,
        "commands=#{routed.inspect} questions=#{asked}")

  puts "\n  title:    #{result["title"]}"
  puts "  summary:  #{result["summary"].to_s[0, 160]}"
  puts "  commands: #{routed.inspect}"

  puts "\n=== The head's workspace was not modified ==="
  status = Dir.chdir(workspace) { `git status --porcelain`.strip }
  check("head made no repository changes", status.empty?, status.empty? ? "clean" : status[0, 200])
ensure
  runner.close_head_session(session_ref) if session_ref
  client.shutdown
  FileUtils.remove_entry(root) if root && Dir.exist?(root)
end

puts "\n#{$failures.empty? ? "ALL CHECKS PASSED" : "FAILED: #{$failures.join(", ")}"}"
exit($failures.empty? ? 0 : 1)
