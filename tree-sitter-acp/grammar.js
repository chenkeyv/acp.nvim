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

		command_marker: () => token(prec(5, /• (You ran|Running|Ran)/)),
		tool_marker: () => token(prec(5, /• (Calling|Called)/)),
		exploration_marker: () => token(prec(5, /• (Exploring|Explored)/)),
		command_subject: () => token(prec(1, /[^\r\n]+/)),
		tool_subject: () => token(prec(1, /[^\r\n]+/)),

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
		exploration_detail: () => token(prec(1, /[^\r\n]+/)),

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
