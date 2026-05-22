import Foundation

enum T5TPrompt {
    static let defaultSubjectLine = "Top 5 Things - Inference Ops | NALA | SA"

    static func buildPrompt(
        tasks: [TaskItem],
        config: T5TConfig,
        periodStart: Date,
        periodEnd: Date
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium

        return """
        You are JP Santana's NVIDIA Top 5 Things writing assistant. Generate a concise T5T report from the task records below.

        SUBJECT LINE DEFAULT:
        \(defaultSubjectLine)

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
        - Avoid naming Slack channels, internal links, or internal repos unless materially important.
        - Avoid links in final T5Ts unless explicitly requested.
        - Do not mix unrelated customer/account topics in the same bullet.
        - Work-in-progress and open items belong in futurePlans, not completed account updates.
        - Do not claim JP caused a customer or partner action when he is supporting it. Use support, coordination, enablement, or preparation language.
        - Omit optional conference content unless explicitly requested.
        - Omit sections that do not apply. Never write "none", "N/A", or filler sections.

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

        SECTION ROUTING:
        - Completed report-worthy tasks are candidates for accountUpdates.
        - Open or in-progress tasks are candidates for futurePlans.
        - Use insights only for clear strategic insight, escalation, help needed, market, or competition content.
        - Prefer accountUpdates and futurePlans. Do not create an optional section just to fill space.

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

        Aim for 3-5 total entries across all sections. Quality over quantity.
        """
    }

    private static func roleLine(for config: T5TConfig) -> String {
        let vertical = clean(config.vertical).isEmpty ? "Inference Ops" : clean(config.vertical)
        let region = clean(config.region).isEmpty ? "NALA" : clean(config.region)
        let jobFunction = clean(config.jobFunction).isEmpty ? "SA" : clean(config.jobFunction)
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
