# frozen_string_literal: true

module Meringue
  module TUI
    # Every delivery PR in the tree that is still live, as one flat list.
    #
    # Unscoped dashboard chat is not about one worker, so pinning one PR number
    # under the chat bar was arbitrary (it was whichever worker had last been
    # focused). This is the honest answer for that state: how many PRs are open
    # across the whole tree, and a list the user can pick from.
    #
    # Read-only and state-only on purpose. Every fact here is already persisted by
    # the kernel's delivery-PR refresh (`delivery_pull_requests` on each issue), so
    # rendering never shells out to `gh` and never blocks a frame. A record the
    # kernel has not verified yet is listed as `unverified` rather than hidden,
    # because a PR the user just opened is exactly what they want to reach.
    module OpenPullRequests
      module_function

      # Live PRs, newest number first. Deduplicated by URL, because the same PR
      # can be attached to more than one issue record.
      def entries(state)
        Array((state || {}).fetch("issues", []))
          .select { |issue| issue.is_a?(Hash) }
          .flat_map { |issue| issue_entries(issue) }
          .uniq { |entry| entry.fetch("url") }
          .sort_by { |entry| [-entry.fetch("number").to_i, entry.fetch("issue_id")] }
      end

      def count(state)
        entries(state).length
      end

      # Whether the tree has ever tracked a delivery PR, settled ones included.
      # A tree with no PRs at all has nothing to say about them.
      def tracked?(state)
        Array((state || {}).fetch("issues", [])).any? do |issue|
          next false unless issue.is_a?(Hash)

          DeliveryPullRequest.pull_request_records(issue).any? do |record|
            DeliveryPullRequest.valid_url?(DeliveryPullRequest.pull_request_url(record))
          end
        end
      end

      def entry_at(state, index)
        list = entries(state)
        return nil if list.empty?

        list[index.to_i.clamp(0, list.length - 1)]
      end

      # Bottom hint line wording for the unscoped state. Plain English, and it
      # says "none" instead of the old "PR unavailable", which read like an error.
      def summary_label(state)
        total = count(state)
        return "no open PRs" if total.zero?

        "#{total} open PR#{total == 1 ? "" : "s"}"
      end

      def issue_entries(issue)
        DeliveryPullRequest.pull_request_records(issue).filter_map do |record|
          url = DeliveryPullRequest.pull_request_url(record)
          next unless DeliveryPullRequest.valid_url?(url)

          # A PR URL the user mentioned in a request is stored on the routed
          # issue as a `matched_by: "user_request"` delivery record so the link
          # is visible immediately, but it has NOT been verified against a
          # worker's delivery branch by the kernel. Surfacing every user-reported
          # PR as a delivery PR of whatever issue the head routed to made
          # unrelated open PRs render as triplicate delivery PRs under one issue.
          # The `/prs` panel lists kernel-verified delivery PRs only; user-reported
          # links remain on the issue record and in `reported_pr_urls`.
          next if user_reported?(record)

          status = DeliveryPullRequest.record_state(record)
          next if DeliveryPullRequest::SETTLED_STATES.include?(status)

          {
            "url" => url,
            "number" => url[DeliveryPullRequest::GITHUB_PULL_REQUEST_URL, 1].to_s,
            "issue_id" => issue.fetch("id", "").to_s,
            # Delivery PR records carry no PR title of their own until the kernel
            # refreshes them from the forge, so the issue title is the name
            # Meringue falls back to. Once refreshed the record carries its own
            # PR title and that wins.
            "title" => title_for(issue, record),
            "status" => status == "open" ? "open" : "unverified"
          }
        end
      end

      def user_reported?(record)
        record.is_a?(Hash) && record["matched_by"].to_s == "user_request"
      end

      def title_for(issue, record)
        pr_title = record.is_a?(Hash) ? record["title"].to_s.strip : ""
        return pr_title unless pr_title.empty?

        issue.fetch("title", "").to_s.strip
      end
    end
  end
end
