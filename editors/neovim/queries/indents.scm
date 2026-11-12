; Quartz TreeSitter indent queries for Neovim

; Indent after block openers
[
  (function_definition)
  (struct_definition)
  (enum_definition)
  (trait_definition)
  (impl_block)
  (extend_block)
  (if_statement)
  (while_statement)
  (for_statement)
  (match_expression)
  (arena_block)
  (macro_definition)
  (loop_statement)
  (select_statement)
  (do_block)
  (task_group_statement)
  (for_await_statement)
  (elsif_clause)
  (else_clause)
] @indent

; Dedent at 'end'
["end"] @dedent

; Brackets indent
["(" "[" "{"] @indent
[")" "]" "}"] @dedent
