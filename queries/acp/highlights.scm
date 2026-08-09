(user_header) @acp.user.header
(agent_header) @acp.agent.header
[
  (plan_header)
  (review_header)
] @acp.section.header

[
  (command_marker)
  (tool_marker)
  (exploration_marker)
] @acp.action.title

(command_subject) @acp.action.command
(command_detail) @acp.action.command
(tool_subject) @acp.action.tool
(exploration_detail) @acp.action.command

[
  (action_pipe)
  (action_branch)
  (action_indent)
] @acp.action.tree

(result_text) @acp.action.output

(fence_delimiter) @acp.code.fence
(language) @acp.code.language
