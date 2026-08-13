((command_subject) @injection.content
  (#set! injection.language "bash"))

((command_detail) @injection.content
  (#set! injection.language "bash"))

((tool_json_arguments) @injection.content
  (#set! injection.language "json"))

(fenced_code_block
  (fence_start
    language: (language) @injection.language)
  (code_fence_content) @injection.content
  (#set! injection.include-children))
