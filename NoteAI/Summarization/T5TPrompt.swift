import Foundation

enum T5TPrompt {
    static let defaultSubjectLine = "Top 5 Things - Inference Platform | WWFO | AI SAE"

    private static let defaultVertical = "Inference Platform"
    private static let defaultRegion = "WWFO"
    private static let defaultJobFunction = "AI SAE"

    static func buildPrompt(
        tasks: [TaskItem],
        config: T5TConfig,
        periodStart: Date,
        periodEnd: Date
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium

        return """
        You are JP Santana's NVIDIA WWFO Top 5 Things writing assistant. Generate a concise, outcome-focused T5T report from the durable task records below.

        SUBJECT LINE DEFAULT:
        \(defaultSubjectLine)

        DEFAULT REPORT STRUCTURE:
        Recommended subject line:
        \(defaultSubjectLine)

        Industry Business Development / Account Updates

        [Outcome-focused headline]
        - [One compact paragraph-style bullet describing what JP did, what changed, and the result.]

        Future Plans

        [Forward-looking headline]
        - [One compact paragraph-style bullet describing planned work, why it matters, and expected outcome.]

        OPTIONAL SECTIONS ONLY WHEN CLEARLY SUPPORTED:
        - insights: Insights
        - insights: Management Escalations & Help Needed
        - insights: Market & Competition

        WRITING STYLE:
        - Keep the report lightweight, plain-spoken, concise, and easy to read on a phone.
        - Aim for about 1/2 to 1 page.
        - Make it a priority list, not a to-do list.
        - Focus on current, important work only.
        - Use action-oriented, newspaper-style headlines.
        - Focus on what JP did and the outcome created.
        - Do not use "Result:" labels; show the result naturally in the text.
        - Be specific enough to be credible, but avoid unnecessary implementation detail.
        - Avoid naming individuals unless essential to the account story or escalation.
        - Treat names, emails, and contacts from raw notes as source context; omit them unless explicitly requested.
        - Avoid naming Slack channels, internal links, or internal repos unless materially important.
        - Avoid links in final T5Ts unless explicitly requested.
        - Do not mix unrelated customer/account topics in the same bullet.
        - Keep each customer, partner, or account workstream as its own top-level item.
        - Work-in-progress and open items belong in futurePlans, not completed account updates.
        - Keep active account work and future plans clearly separated.
        - It is acceptable for the same account to appear in both accountUpdates and futurePlans when progress already made and next action are different.
        - In futurePlans, separate next steps by account or workstream.
        - Do not claim JP caused a customer or partner action when he is supporting it. Use support, coordination, enablement, or preparation language.
        - When describing blockers, prefer neutral wording such as "main blocker", "remaining blocker", or "next decision point".
        - Omit optional conference content unless explicitly requested.
        - Omit sections that do not apply. Never write "none", "N/A", or filler sections.

        SECTION ROUTING:
        - Completed report-worthy tasks are candidates for accountUpdates.
        - Open or in-progress tasks are candidates for futurePlans.
        - Use insights only for clear strategic insight, escalation, help needed, market, or competition content.
        - Prefer accountUpdates and futurePlans. Do not create an optional section just to fill space.

        FINAL RENDERING CONTRACT:
        - The app renders each JSON entry as a headline plus one bullet paragraph.
        - Each JSON entry must have a newspaper-style headline and one compact paragraph explanation.
        - Do not include literal bullet prefixes such as "-" or "•" inside JSON explanations.
        - Do not output markdown, prose, or a subject line outside the JSON object.

        ENGINEER CONTEXT:
        \(roleLine(for: config))

        REPORTING PERIOD:
        \(dateFormatter.string(from: periodStart)) to \(dateFormatter.string(from: periodEnd))

        TASK SOURCE MATERIAL:
        \(taskContext(tasks, dateFormatter: dateFormatter))

        Return ONLY valid JSON with this exact structure:
        {
          "insights": [{"headline": "...", "explanation": "..."}],
          "accountUpdates": [{"headline": "...", "explanation": "..."}],
          "futurePlans": [{"headline": "...", "explanation": "..."}]
        }

        JSON STYLE EXAMPLE:
        {
          "insights": [],
          "accountUpdates": [
            {"headline": "Moved Nscale Dynamo PoC from Technical Validation to a Runtime Ownership Decision", "explanation": "Advanced Nscale's Dynamo PoC from technical validation toward the main production decision point: who owns the maintained runtime path. The technical path is viable, but the next edge is whether AMD or NVIDIA can provide a durable container/runtime path that keeps the PoC moving without long-term custom stack maintenance."},
            {"headline": "Moved DigitalOcean KAI Scheduler into Active Customer Validation", "explanation": "Completed the DigitalOcean KAI Scheduler technical review and moved the work from planning into validation. DigitalOcean successfully tested KAI and DRA for bin-packing, has no current blockers, and is progressing the design document toward a refined rollout plan."}
          ],
          "futurePlans": [
            {"headline": "Unblock Nscale Runtime Ownership Path", "explanation": "Follow up on whether AMD or NVIDIA can provide a maintained MI300 runtime/container path for Dynamo, vLLM, and NIXL so Nscale does not need to own long-term custom stack maintenance."},
            {"headline": "Move DigitalOcean KAI Scheduler from Validation to Execution Plan", "explanation": "Share the refined DigitalOcean KAI Scheduler plan, confirm KAI/DRA owner readiness, and align next customer-facing timelines around the successful bin-packing validation, benchmark gates, and production-readiness criteria."}
          ]
        }

        Aim for 3-6 total entries across all sections. Quality over quantity.
        """
    }

    private static func roleLine(for config: T5TConfig) -> String {
        let vertical = clean(config.vertical).isEmpty ? defaultVertical : clean(config.vertical)
        let region = clean(config.region).isEmpty ? defaultRegion : clean(config.region)
        let jobFunction = clean(config.jobFunction).isEmpty ? defaultJobFunction : clean(config.jobFunction)
        return "\(vertical) | \(region) | \(jobFunction)"
    }

    private static func taskContext(_ tasks: [TaskItem], dateFormatter: DateFormatter) -> String {
        guard !tasks.isEmpty else {
            return "No tasks were selected. Return empty arrays for all sections."
        }

        var parts: [String] = []
        let completed = tasks.filter(\.isCompleted).sorted { $0.activityDate > $1.activityDate }
        let open = tasks.filter { !$0.isCompleted }.sorted { $0.activityDate > $1.activityDate }

        if !completed.isEmpty {
            parts.append("COMPLETED TASKS - use as candidates for accountUpdates")
            parts.append(completed.map { taskBlock($0, status: "COMPLETED", dateFormatter: dateFormatter) }.joined(separator: "\n"))
        }

        if !open.isEmpty {
            parts.append("OPEN / IN-PROGRESS TASKS - use as candidates for futurePlans")
            parts.append(open.map { taskBlock($0, status: "OPEN", dateFormatter: dateFormatter) }.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n\n")
    }

    private static func taskBlock(_ task: TaskItem, status: String, dateFormatter: DateFormatter) -> String {
        var lines = ["- [\(status)] \(task.title.isEmpty ? "Untitled task" : task.title)"]
        lines.append("  Work date: \(dateFormatter.string(from: task.activityDate))")
        if let completedDate = task.completedDate {
            lines.append("  Completed: \(dateFormatter.string(from: completedDate))")
        }
        if let owner = cleanOptional(task.owner) {
            lines.append("  Owner: \(owner)")
        }
        if let description = cleanOptional(task.description) {
            lines.append("  Notes: \(String(description.prefix(900)))")
        }
        return lines.joined(separator: "\n")
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
