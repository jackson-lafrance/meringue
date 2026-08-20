# frozen_string_literal: true

# Live proof that the Claude Code backend works through one interactive session for both
# autonomous driving and the focused session viewer.
#
# This talks to a real `claude` install and spends real tokens, so it is not part of `rake test`.
# Run it directly when changing the interactive transport:
#
#   ruby -Ilib test/e2e/claude_interactive_proof.rb
#
# It asserts the properties the design depends on:
#
#   1. Meringue can spawn a session, prompt it, and read a structured result back, with no
#      per-turn process and no `--print` invocation.
#   2. The focused viewer attaches to that same running process mid-turn, without interrupting it.
#   3. A prompt typed through the viewer lands in the same session Meringue is reading.

require "fileutils"
require "json"
require "tmpdir"
require "meringue"

$stdout.sync = true
$failures = []

def section(title)
  puts "\n=== #{title} ==="
end

def check(label, condition, detail = nil)
  puts "  [#{condition ? "PASS" : "FAIL"}] #{label}#{detail ? " — #{detail}" : ""}"
  $failures << label unless condition
  condition
end

def wait_for_settled(client, ref, timeout: 240)
  deadline = Time.now + timeout
  state = ref
  loop do
    client.read_events(state)
    state = client.get_state(state)
    return state unless state.fetch("is_streaming", false)
    raise "timed out waiting for the session to settle" if Time.now > deadline

    sleep 0.5
  end
end

# Waits for text to appear in the durable transcript. Used instead of waiting for "settled" when a
# prompt was typed straight into the PTY, because between the keystroke and the transcript record
# the session is legitimately still settled from the previous turn.
def wait_for_transcript(client, ref, needle, timeout: 240)
  deadline = Time.now + timeout
  loop do
    client.read_events(ref)
    records = client.open_session_view(ref).snapshot.fetch("items", [])
    return true if records.any? { |item| item["content"].to_s.include?(needle) }
    raise "#{needle} never reached the transcript" if Time.now > deadline

    sleep 0.5
  end
end

workspace = Dir.mktmpdir("meringue-claude-proof")
client = Meringue::Harness::ClaudeInteractiveClient.new(
  extra_args: ["--permission-mode", "bypassPermissions", "--model", "sonnet"]
)
session_ref = nil

begin
  Dir.chdir(workspace) do
    system("git", "init", "--quiet", ".", out: File::NULL, err: File::NULL)
    File.write("README.md", "proof workspace\n")
  end

  section "1. Autonomous spawn and first turn"
  started = Time.now
  session_ref = client.spawn_session(
    kind: "worker",
    cwd: workspace,
    prompt: "Reply with exactly MERINGUE_ONE and nothing else. Do not use any tools.",
    system_prompt: "You are a Meringue worker under test. Answer exactly as asked.",
    session_name: "Meringue proof"
  )
  puts "  spawned in #{(Time.now - started).round(1)}s pid=#{session_ref["pid"]} session=#{session_ref["session_id"]}"
  first_pid = session_ref["pid"]
  check("session ref carries a pid", !first_pid.nil?)
  check("session ref names a transcript", !session_ref["session_file"].to_s.empty?)

  settled = wait_for_settled(client, session_ref)
  check("first turn produced a result", client.last_assistant_text(settled).to_s.include?("MERINGUE_ONE"))
  outcome = client.turn_outcome(settled)
  check("turn outcome is completed", outcome && outcome["state"] == "completed", outcome.to_h["state"])

  section "2. Second turn on the same process"
  ref = client.prompt_session(settled, "Now reply with exactly MERINGUE_TWO and nothing else.", mode: "normal", delivery_id: "proof-2")
  check("no new process was started", ref["pid"] == first_pid, "pid #{ref["pid"]} vs #{first_pid}")
  settled = wait_for_settled(client, ref)
  check("second turn produced a result", client.last_assistant_text(settled).to_s.include?("MERINGUE_TWO"))
  receipt = client.prompt_delivery_status(settled, delivery_id: "proof-2", prompt: nil)
  check("prompt delivery receipt confirms delivery", receipt["status"] == "delivered", receipt["status"])

  section "3. Focusing mid-turn does not interrupt the work"
  # This is the property the whole design exists for: start real work, attach the viewer while the
  # agent is still running it, and confirm the turn completes anyway on the same process.
  ref = client.prompt_session(
    settled,
    "Read README.md with a tool, then reply with exactly MERINGUE_FOUR and nothing else.",
    mode: "normal",
    delivery_id: "proof-4"
  )
  streaming_seen = false
  8.times do
    client.read_events(ref)
    streaming_seen = client.get_state(ref).fetch("is_streaming", false)
    break if streaming_seen

    sleep 0.5
  end
  check("the worker is mid-turn before focusing", streaming_seen)

  terminal = client.live_terminal(ref)
  check("focus attached to the same process", terminal.pid == first_pid, "pid #{terminal.pid} vs #{first_pid}")
  check("focus did not stop the process", terminal.alive?)
  snapshot = terminal.snapshot(rows: 30, columns: 100)
  visible = Array(snapshot["lines"]).join("\n")
  check("viewer renders the agent's live screen", visible.strip.length.positive?, "#{visible.strip.length} chars")

  settled = wait_for_settled(client, ref)
  check("the interrupted-by-focus turn still finished", client.last_assistant_text(settled).to_s.include?("MERINGUE_FOUR"))
  check("still the same process after focusing", settled["pid"] == first_pid)

  section "4. A prompt typed in the viewer lands in the same session"
  terminal.write("\e[200~Reply with exactly MERINGUE_FIVE and nothing else.\e[201~")
  sleep 1
  terminal.write("\r")
  wait_for_transcript(client, settled, "MERINGUE_FIVE")
  settled = wait_for_settled(client, settled)
  check("viewer-typed prompt was answered", client.last_assistant_text(settled).to_s.include?("MERINGUE_FIVE"))
  check("still one process for the whole session", client.get_state(settled)["pid"] == first_pid)

  section "5. Session view snapshot for the transcript pane"
  view = client.open_session_view(settled).snapshot
  check("session view is live", view["availability"] == "live", view["availability"].to_s)
  items = Array(view["items"])
  roles = items.map { |item| item["role"] }.tally
  check("session view carries the whole conversation", items.length >= 8, roles.inspect)
  check("session view includes tool activity", roles.key?("tool"), roles.inspect)
ensure
  client.kill_session(session_ref) if session_ref
  client.shutdown
  FileUtils.remove_entry(workspace) if workspace && Dir.exist?(workspace)
end

puts "\n#{$failures.empty? ? "ALL CHECKS PASSED" : "FAILED: #{$failures.join(", ")}"}"
exit($failures.empty? ? 0 : 1)
