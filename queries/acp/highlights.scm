(user_header) @acp.user.header
(agent_header) @acp.agent.header
[
  (plan_header)
  (review_header)
] @acp.section.header

[
  (command_active_marker)
  (tool_active_marker)
  (exploration_active_marker)
] @acp.action.active

[
  (command_complete_marker)
  (tool_complete_marker)
  (exploration_complete_marker)
] @acp.action.success

((command_subject) @acp.action.command
  (#set! priority 90))

((command_detail) @acp.action.command
  (#set! priority 90))

(tool_namespace) @acp.action.namespace
(tool_method) @acp.action.tool
[
  (tool_arguments_open)
  (tool_arguments_close)
] @acp.action.punctuation
((tool_arguments) @acp.action.arguments
  (#set! priority 90))
(exploration_verb) @acp.action.verb
(exploration_target) @acp.action.command

[
  (action_pipe)
  (action_branch)
  (action_indent)
] @acp.action.tree

(result_text) @acp.action.output

((result_text) @acp.action.failure
  (#match? @acp.action.failure "^Error:"))

((result_text) @acp.action.meta
  (#match? @acp.action.meta "^(… \\+|\\(no output\\))"))

(fence_delimiter) @acp.code.fence
(language) @acp.code.language
