// TreeSitter grammar for the Quartz programming language
// Reference: editors/vscode/syntaxes/quartz.tmLanguage.json, docs/QUARTZ_REFERENCE.md

module.exports = grammar({
  name: 'quartz',

  extras: $ => [/\s/, $.comment, $.doc_comment, $.module_doc_comment],

  word: $ => $.identifier,

  rules: {
    source_file: $ => repeat($._definition),

    _definition: $ => choice(
      $.function_definition,
      $.struct_definition,
      $.enum_definition,
      $.trait_definition,
      $.impl_block,
      $.extend_block,
      $.type_alias,
      $.newtype_definition,
      $.import_statement,
      $.const_declaration,
      $.global_var_declaration,
      $.extern_declaration,
      $.macro_definition,
      $.static_assert,
      $.attribute,
      $._statement
    ),

    // Comments
    comment: $ => token(seq('#', /(?!#)/, /.*/)),
    doc_comment: $ => token(seq('##', /(?!!)/, /.*/)),
    module_doc_comment: $ => token(seq('##!', /.*/)),

    // Import
    import_statement: $ => choice(
      seq('import', '*', 'from', $.identifier),
      seq('import', $.import_path),
      seq('import', $.identifier)
    ),

    import_path: $ => seq($.identifier, repeat1(seq('/', $.identifier))),

    // Function definition
    function_definition: $ => seq(
      optional('const'),
      'def',
      field('name', $.identifier),
      optional($.type_parameters),
      '(',
      optional($.parameter_list),
      ')',
      optional(seq(':', field('return_type', $.type))),
      choice(
        seq(optional('='), $._expression),
        seq(repeat($._statement), 'end')
      )
    ),

    // Struct definition
    struct_definition: $ => seq(
      optional($.attribute),
      optional('linear'),
      'struct',
      field('name', $.type_identifier),
      optional($.type_parameters),
      repeat($.field_definition),
      'end'
    ),

    field_definition: $ => seq(
      field('name', $.identifier),
      ':',
      field('type', $.type)
    ),

    // Enum definition
    enum_definition: $ => seq(
      'enum',
      field('name', $.type_identifier),
      optional($.type_parameters),
      repeat($.variant_definition),
      'end'
    ),

    variant_definition: $ => seq(
      field('name', $.type_identifier),
      optional(seq('(', commaSep($.type), ')'))
    ),

    // Trait definition
    trait_definition: $ => seq(
      'trait',
      field('name', $.type_identifier),
      optional($.type_parameters),
      repeat($.function_definition),
      'end'
    ),

    // Impl block
    impl_block: $ => choice(
      seq(
        'impl',
        field('trait', $.type_identifier),
        optional($.type_parameters),
        'for',
        field('type', $.type_identifier),
        repeat($.function_definition),
        'end'
      ),
      seq(
        'impl',
        field('type', $.type_identifier),
        repeat($.function_definition),
        'end'
      )
    ),

    // Extend block
    extend_block: $ => seq(
      'extend',
      field('type', $.type),
      repeat($.function_definition),
      'end'
    ),

    // Type alias
    type_alias: $ => seq('type', $.type_identifier, '=', $.type),

    // Newtype
    newtype_definition: $ => seq('newtype', $.type_identifier, '=', $.type),

    // Extern declaration
    extern_declaration: $ => seq(
      'extern', '"C"', choice('def', 'fn'),
      field('name', $.identifier),
      '(',
      optional($.parameter_list),
      ')',
      optional(seq(':', $.type))
    ),

    // Macro definition
    macro_definition: $ => seq(
      'macro',
      field('name', $.identifier),
      '(',
      optional($.parameter_list),
      ')',
      repeat($._statement),
      'end'
    ),

    // Const declaration
    const_declaration: $ => seq(
      'const',
      field('name', $.identifier),
      '=',
      $._expression
    ),

    // Global variable
    global_var_declaration: $ => seq(
      field('name', $.identifier),
      '=',
      $._expression
    ),

    // Static assert
    static_assert: $ => seq(
      'static_assert',
      $._expression,
      optional(seq(',', $.string))
    ),

    // Attribute
    attribute: $ => seq('@', $.identifier, optional(seq('(', commaSep($._expression), ')'))),

    // Type parameters
    type_parameters: $ => seq('<', commaSep($.type_identifier), '>'),

    // Parameters
    parameter_list: $ => commaSep1($.parameter),
    parameter: $ => seq(
      field('name', $.identifier),
      optional(seq(':', field('type', $.type))),
      optional(seq('=', $._expression))
    ),

    // Types
    type: $ => choice(
      $.type_identifier,
      $.generic_type,
      $.function_type,
      $.reference_type,
      $.never_type,
      $.record_type
    ),

    type_identifier: $ => /[A-Z][a-zA-Z0-9_]*/,

    generic_type: $ => seq($.type_identifier, '<', commaSep($.type), '>'),

    function_type: $ => seq('Fn', '(', commaSep($.type), ')', optional(seq(':', $.type))),

    reference_type: $ => seq('&', optional('mut'), $.type),

    never_type: $ => '!',

    record_type: $ => seq('{', commaSep(seq($.identifier, ':', $.type)), '}'),

    // Statements
    _statement: $ => choice(
      $.let_statement,
      $.var_statement,
      $.assignment,
      $.return_statement,
      $.if_statement,
      $.while_statement,
      $.for_statement,
      $.for_await_statement,
      $.loop_statement,
      $.match_expression,
      $.select_statement,
      $.yield_statement,
      $.cimport_statement,
      $.task_group_statement,
      $.break_statement,
      $.continue_statement,
      $.defer_statement,
      $.arena_block,
      $.expression_statement
    ),

    let_statement: $ => seq(
      optional('var'),
      field('name', $.identifier),
      optional(seq(':', $.type)),
      '=',
      $._expression
    ),

    var_statement: $ => seq(
      'var',
      field('name', $.identifier),
      optional(seq(':', $.type)),
      '=',
      $._expression
    ),

    assignment: $ => seq(
      $._expression,
      choice('=', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '<<=', '>>='),
      $._expression
    ),

    return_statement: $ => seq('return', optional($._expression)),

    if_statement: $ => seq(
      'if',
      field('condition', $._expression),
      repeat($._statement),
      repeat($.elsif_clause),
      optional($.else_clause),
      'end'
    ),

    elsif_clause: $ => seq('elsif', $._expression, repeat($._statement)),

    else_clause: $ => seq('else', repeat($._statement)),

    while_statement: $ => seq(
      'while',
      field('condition', $._expression),
      repeat($._statement),
      'end'
    ),

    for_statement: $ => seq(
      'for',
      field('variable', $.identifier),
      'in',
      field('iterable', $._expression),
      repeat($._statement),
      'end'
    ),

    for_await_statement: $ => seq(
      'for', 'await',
      field('variable', $.identifier),
      'in',
      field('channel', $._expression),
      repeat($._statement),
      'end'
    ),

    loop_statement: $ => seq(
      'loop',
      repeat($._statement),
      'end'
    ),

    select_statement: $ => seq(
      'select',
      repeat($.select_arm),
      'end'
    ),

    select_arm: $ => seq(
      $._expression,
      '=>',
      choice(
        $._expression,
        seq(repeat1($._statement))
      )
    ),

    yield_statement: $ => seq('yield', optional($._expression)),

    cimport_statement: $ => seq('cimport', $.string),

    task_group_statement: $ => seq(
      'task_group', '|', field('variable', $.identifier), '|',
      repeat($._statement),
      'end'
    ),

    match_expression: $ => seq(
      'match',
      field('subject', $._expression),
      repeat($.match_arm),
      'end'
    ),

    match_arm: $ => seq(
      $._pattern,
      optional(seq('if', $._expression)),
      '=>',
      choice(
        $._expression,
        seq('{', repeat($._statement), '}')
      )
    ),

    _pattern: $ => choice(
      $.identifier,
      $.integer,
      $.string,
      $.boolean,
      $.nil,
      $.wildcard_pattern,
      $.enum_pattern,
      $.range_pattern
    ),

    wildcard_pattern: $ => '_',
    enum_pattern: $ => seq($.type_identifier, '::', $.type_identifier, optional(seq('(', commaSep($.identifier), ')'))),
    range_pattern: $ => seq($._expression, choice('..', '...', '..='), $._expression),

    break_statement: $ => seq('break', optional($.identifier)),
    continue_statement: $ => seq('continue', optional($.identifier)),

    defer_statement: $ => seq('defer', $._expression),

    arena_block: $ => seq('arena', $.identifier, 'do', repeat($._statement), 'end'),

    expression_statement: $ => $._expression,

    // Expressions
    _expression: $ => choice(
      $.binary_expression,
      $.unary_expression,
      $.call_expression,
      $.index_expression,
      $.field_expression,
      $.lambda_expression,
      $.if_expression,
      $.match_expression,
      $.async_expression,
      $.await_expression,
      $.go_expression,
      $.do_block,
      $.array_literal,
      $.struct_literal,
      $.symbol,
      $.integer,
      $.float,
      $.string,
      $.interpolated_string,
      $.boolean,
      $.nil,
      $.identifier,
      $.qualified_identifier,
      $.enum_access,
      $.parenthesized_expression,
      $.function_reference,
      $.range_expression
    ),

    binary_expression: $ => choice(
      ...[['+', 6], ['-', 6], ['*', 7], ['/', 7], ['%', 7],
          ['==', 4], ['!=', 4], ['<', 5], ['>', 5], ['<=', 5], ['>=', 5],
          ['and', 2], ['or', 1],
          ['&', 3], ['|', 3], ['^', 3], ['<<', 5], ['>>', 5],
          ['..', 0], ['..=', 0], ['|>', 0], ['??', 1]
      ].map(([op, prec]) =>
        prec.left(prec, seq($._expression, op, $._expression))
      )
    ),

    async_expression: $ => prec(8, seq('async', $._expression)),

    await_expression: $ => prec(8, seq('await', $._expression)),

    go_expression: $ => prec(8, seq('go', $._expression)),

    do_block: $ => seq(
      'do',
      optional(seq(optional($.parameter_list), '->')),
      repeat($._statement),
      'end'
    ),

    symbol: $ => seq(':', /[a-zA-Z_][a-zA-Z0-9_]*/),

    unary_expression: $ => choice(
      prec(8, seq('-', $._expression)),
      prec(8, seq('not', $._expression)),
      prec(8, seq('~', $._expression))
    ),

    call_expression: $ => prec(9, seq(
      field('function', $._expression),
      optional(seq('<', commaSep($.type), '>')),
      '(',
      optional(commaSep($._expression)),
      ')'
    )),

    index_expression: $ => prec(9, seq($._expression, '[', $._expression, ']')),

    field_expression: $ => prec(9, seq($._expression, '.', $.identifier)),

    lambda_expression: $ => seq(
      optional($.parameter_list),
      '->',
      $._expression
    ),

    if_expression: $ => seq(
      $._expression,
      'if',
      $._expression
    ),

    array_literal: $ => seq('[', optional(commaSep($._expression)), ']'),

    struct_literal: $ => seq(
      $.type_identifier,
      '{',
      commaSep(seq($.identifier, ':', $._expression)),
      '}'
    ),

    range_expression: $ => prec.left(0, seq($._expression, choice('..', '..=', '...'), $._expression)),

    parenthesized_expression: $ => seq('(', $._expression, ')'),

    function_reference: $ => seq('&', $.identifier),

    qualified_identifier: $ => seq($.identifier, '$', $.identifier),

    enum_access: $ => seq($.type_identifier, '::', $.type_identifier),

    // Literals
    integer: $ => token(choice(
      /0x[0-9a-fA-F][0-9a-fA-F_]*/,
      /0b[01][01_]*/,
      /0o[0-7][0-7_]*/,
      /[0-9][0-9_]*(?:_?(?:i8|i16|i32|i64|u8|u16|u32|u64))?/
    )),

    float: $ => token(/[0-9][0-9_]*\.[0-9][0-9_]*(?:[eE][+-]?[0-9]+)?(?:_?f(?:32|64))?/),

    string: $ => seq('"', repeat(choice($.escape_sequence, /[^"\\#]+/, /#[^{]/)), '"'),

    interpolated_string: $ => seq('"', repeat(choice($.escape_sequence, $.interpolation, /[^"\\#]+/, /#[^{]/)), '"'),

    interpolation: $ => seq('#{', $._expression, '}'),

    escape_sequence: $ => token(seq('\\', choice('n', 't', 'r', '\\', '"', '#', '0', /x[0-9a-fA-F]{2}/, /u\{[0-9a-fA-F]+\}/))),

    boolean: $ => choice('true', 'false'),

    nil: $ => 'nil',

    identifier: $ => /[a-zA-Z_][a-zA-Z0-9_$]*[?!]?/,
  }
});

function commaSep(rule) {
  return optional(commaSep1(rule));
}

function commaSep1(rule) {
  return seq(rule, repeat(seq(',', rule)));
}
