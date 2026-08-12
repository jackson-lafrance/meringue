# frozen_string_literal: true

# Hermetic workload matching the state shape that exposed interactive typing lag:
# twenty tracked agents, ten concurrently streaming workers, a full retained log
# window, and a workspace failure whose diagnostic output is much larger than the
# durable diagnostic budget.
module ActiveWorkloadSupport
  AGENT_COUNT = 20
  WORKING_WORKER_COUNT = 10
  LOG_COUNT = 500
  BASE_TIME = "2026-08-12T12:00:00Z"

  module_function

  def state
    state = Meringue::State::Models.empty_state(now: BASE_TIME)
    state["projects"] << {
      "id" => "P1", "name" => "Active workload", "root_path" => ".", "status" => "working",
      "created_at" => BASE_TIME, "updated_at" => BASE_TIME
    }

    AGENT_COUNT.times do |index|
      number = index + 1
      issue_id = "P1-I#{number}"
      agent_id = "#{issue_id}-W1"
      working = index < WORKING_WORKER_COUNT
      state["issues"] << {
        "id" => issue_id, "project_id" => "P1", "parent_issue_id" => nil,
        "title" => "Active issue #{number}", "description" => "Representative active work",
        "status" => working ? "working" : "completed", "agent_ids" => [agent_id],
        "created_at" => BASE_TIME, "updated_at" => BASE_TIME
      }
      state["agents"] << {
        "id" => agent_id, "type" => "worker", "project_id" => "P1", "issue_id" => issue_id,
        "status" => working ? "working" : "completed", "harness" => "pi",
        "pid" => Process.pid.to_s, "harness_session_id" => (working ? "active-session-#{number}" : nil),
        "is_streaming" => working,
        "harness_metadata" => {
          "kind" => "worker", "title" => "Worker #{number}", "is_streaming" => working,
          "reconcile_state" => (working ? "healthy" : nil),
          "last_assistant_text" => (working ? nil : "Completed worker #{number}")
        }.compact,
        "created_at" => BASE_TIME, "updated_at" => BASE_TIME
      }.compact
    end

    (LOG_COUNT - 1).times do |index|
      state["logs"] << {
        "id" => "L#{index + 1}", "timestamp" => BASE_TIME, "source_type" => "worker",
        "source_id" => "P1-I#{(index % AGENT_COUNT) + 1}-W1", "level" => "info",
        "message" => "Representative retained workload log #{index + 1}",
        "details" => { "phase" => "active", "summary" => "concise lifecycle context" }
      }
    end
    state["logs"] << oversized_diagnostic_log
    state["counters"]["logs"] = LOG_COUNT
    state
  end

  def oversized_diagnostic_log
    stderr = "checkout failed at beginning\n#{"lock contention and retry output\n" * 12_000}lock remains at end"
    {
      "id" => "L#{LOG_COUNT}", "timestamp" => BASE_TIME, "source_type" => "kernel",
      "source_id" => "P1-I1-W1", "level" => "error",
      "message" => "Worker workspace provisioning failed. Prompt this worker to retry provisioning, or kill it.",
      "details" => {
        "issue_id" => "P1-I1", "provisioning_state" => "retry_exhausted",
        "recovery_guidance" => "Prompt this worker to retry provisioning, or kill it.",
        "workspace" => {
          "workspace_path" => "/tmp/hermetic-active-workload/P1-I1-W1", "workspace_strategy" => "git_worktree",
          "workspace_branch" => "meringue/reduce-interactive-typing-latency", "exit_status" => 128,
          "stderr" => stderr
        }
      }
    }
  end

  # Stateful fake: get_state changes heartbeat-only fields on every poll, while
  # read_events drains each event exactly once like the real transport cursor.
  class HeartbeatClient < Meringue::Harness::FakeClient
    attr_reader :read_counts

    def initialize(session_ids)
      @sessions = session_ids.to_h do |session_id|
        [session_id, { streaming: true, completed: false, events: [{ "type" => "rpc_parse_error", "id" => "#{session_id}-diagnostic", "error_message" => "recoverable malformed diagnostic" }], text: nil }]
      end
      @heartbeats = Hash.new(0)
      @read_counts = Hash.new(0)
    end

    def get_state(session_ref)
      session_id = session_ref.fetch("session_id")
      session = @sessions.fetch(session_id)
      @heartbeats[session_id] += 1
      session_ref.merge(
        "is_streaming" => session.fetch(:streaming),
        "last_event_at" => format("2026-08-12T12:00:%02dZ", @heartbeats.fetch(session_id) % 60),
        "metadata" => session_ref.fetch("metadata", {}).merge(
          "completed" => session.fetch(:completed),
          "messageCount" => @heartbeats.fetch(session_id)
        )
      )
    end

    def read_events(session_ref)
      session_id = session_ref.fetch("session_id")
      @read_counts[session_id] += 1
      @sessions.fetch(session_id).fetch(:events).shift(1)
    end

    def last_assistant_text(session_ref)
      @sessions.fetch(session_ref.fetch("session_id")).fetch(:text)
    end

    def complete!(session_id, text: "completed under concurrent reconciliation")
      session = @sessions.fetch(session_id)
      session[:streaming] = false
      session[:completed] = true
      session[:text] = text
      session[:events] << { "type" => "process_exit", "id" => "#{session_id}-end", "status" => "success" }
    end
  end
end
