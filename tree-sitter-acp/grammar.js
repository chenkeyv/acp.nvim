/**
 * @file Tree-sitter grammar for acp.nvim chat transcripts
 * @author acp.nvim contributors
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

module.exports = grammar({
	name: "acp",

	extras: () => [],

	rules: {
		document: ($) =>
			repeat(
				choice(
					$.blank_line,
					$.fenced_code_block,
					$.command_action,
					$.tool_action,
					$.exploration_action,
					$.user_header,
					$.agent_header,
					$.plan_header,
					$.review_header,
					$.text_line,
				),
			),

		blank_line: ($) => $._newline,

		user_header: () => token(prec(3, /(U|) You[^\r\n]*\r?\n/)),
		agent_header: () => token(prec(3, /(A|󰚩) Codex[^\r\n]*\r?\n/)),
		plan_header: () => token(prec(3, /(#|) Plan[^\r\n]*\r?\n/)),
		review_header: () => token(prec(3, /(#|) Review[^\r\n]*\r?\n/)),

		command_action: ($) =>
			seq(
				field("state", $.command_marker),
				optional(seq(" ", field("subject", $.command_subject))),
				$._newline,
				repeat(choice($.command_continuation, $.action_result, $.action_result_continuation)),
			),

		tool_action: ($) =>
			seq(
				field("state", $.tool_marker),
				optional(seq(" ", field("subject", $.tool_subject))),
				$._newline,
				repeat(choice($.action_result, $.action_result_continuation)),
			),

		exploration_action: ($) =>
			seq(
				field("state", $.exploration_marker),
				$._newline,
				repeat(choice($.exploration_result, $.exploration_continuation)),
			),

		command_marker: ($) => choice($.command_active_marker, $.command_complete_marker),
		tool_marker: ($) => choice($.tool_active_marker, $.tool_complete_marker),
		exploration_marker: ($) => choice($.exploration_active_marker, $.exploration_complete_marker),
		command_active_marker: () => token(prec(6, "• Running")),
		command_complete_marker: () => token(prec(6, /• (You ran|Ran)/)),
		tool_active_marker: () => token(prec(6, "• Calling")),
		tool_complete_marker: () => token(prec(6, "• Called")),
		exploration_active_marker: () => token(prec(6, "• Exploring")),
		exploration_complete_marker: () => token(prec(6, "• Explored")),
		command_subject: () => token(prec(1, /[^\r\n]+/)),
		tool_subject: ($) =>
			seq(
				field("name", $.tool_name),
				optional(
					seq(
						field("open", $.tool_arguments_open),
						optional(field("arguments", $.tool_arguments)),
						field("close", $.tool_arguments_close),
					),
				),
			),
		tool_name: ($) =>
			seq(
				optional(field("namespace", $.tool_namespace)),
				field("method", $.tool_method),
			),
		tool_namespace: () => token(prec(3, /[^\s.(\r\n]+\./)),
		tool_method: () => token.immediate(prec(2, /[^\s.(\r\n]+/)),
		tool_arguments_open: () => token.immediate("("),
		tool_arguments: ($) => choice($.tool_json_arguments, $.tool_raw_arguments),
		tool_json_arguments: () =>
			token.immediate(prec(2, choice(/\{[^\r\n]*\}/, /\[[^\r\n]*\]/))),
		tool_raw_arguments: () => token.immediate(prec(1, /[^)\r\n]+/)),
		tool_arguments_close: () => token.immediate(")"),

		command_continuation: ($) =>
			seq($.action_pipe, optional(field("content", $.command_detail)), $._newline),
		action_result: ($) =>
			seq($.action_branch, optional(field("content", $.result_text)), $._newline),
		action_result_continuation: ($) =>
			seq($.action_indent, optional(field("content", $.result_text)), $._newline),
		exploration_result: ($) =>
			seq($.action_branch, optional(field("content", $.exploration_detail)), $._newline),
		exploration_continuation: ($) =>
			seq($.action_indent, optional(field("content", $.exploration_detail)), $._newline),

		action_pipe: () => token(prec(5, "  │ ")),
		action_branch: () => token(prec(5, "  └ ")),
		action_indent: () => token(prec(5, "    ")),
		command_detail: () => token(prec(1, /[^\r\n]+/)),
		result_text: () => token(prec(1, /[^\r\n]+/)),
		exploration_detail: ($) =>
			seq(
				field("verb", $.exploration_verb),
				optional(seq(" ", field("target", $.exploration_target))),
			),
		exploration_verb: () => token(prec(2, /(Read|List|Search)/)),
		exploration_target: () => token(prec(1, /[^\r\n]+/)),

		fenced_code_block: ($) => seq($.fence_start, optional($.code_fence_content), $.fence_end),
		fence_start: ($) =>
			seq(
				field("delimiter", $.fence_delimiter),
				optional(field("language", $.language)),
				optional($.fence_padding),
				$._newline,
			),
		fence_end: ($) =>
			seq(field("delimiter", $.fence_delimiter), optional($.fence_padding), $._newline),
		fence_delimiter: () => token(prec(4, /`{3,}/)),
		language: () => token.immediate(prec(3, /[A-Za-z0-9_+.-]+/)),
		fence_padding: () => token.immediate(/[ \t]+/),
		code_fence_content: ($) => repeat1($.code_line),
		code_line: () =>
			choice(token(prec(-2, /[^\r\n]*\r?\n/)), token(prec(-2, /[^\r\n]+/))),

		text_line: ($) => seq($.text, $._newline),
		text: () => token(prec(-3, /[^\r\n]+/)),
		_newline: () => /\r?\n/,
	},
});
