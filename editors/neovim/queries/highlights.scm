; Quartz TreeSitter highlight queries for Neovim
; Matches the VS Code TextMate scope conventions

; Keywords
["if" "elsif" "else" "unless" "match" "end" "while" "for" "in" "loop"
 "break" "continue" "return" "do" "then" "try" "catch" "select"] @keyword.conditional

["def" "var" "const" "struct" "enum" "trait" "impl" "extend" "import" "from"
 "as" "type" "newtype" "macro" "quote" "unquote" "unquote_each" "private"
 "priv" "cimport" "when" "where" "public"] @keyword

["go" "async" "await" "yield"] @keyword.coroutine

["spawn" "defer" "arena" "extern" "static_assert" "linear"
 "task_group"] @keyword.other

["and" "or" "not"] @keyword.operator

; Function definitions
(function_definition
  name: (identifier) @function.definition)

; Struct, enum, trait definitions
(struct_definition
  name: (type_identifier) @type.definition)

(enum_definition
  name: (type_identifier) @type.definition)

(trait_definition
  name: (type_identifier) @type.definition)

(impl_block
  trait: (type_identifier) @type
  type: (type_identifier) @type)

(extend_block
  type: (_) @type)

; Type alias / newtype
(type_alias (type_identifier) @type.definition)
(newtype_definition (type_identifier) @type.definition)

; Function calls
(call_expression
  function: (identifier) @function.call)

(call_expression
  function: (qualified_identifier) @function.call)

; Field access
(field_expression
  "." @punctuation.delimiter
  (identifier) @field)

; Field definitions
(field_definition
  name: (identifier) @field)

; Parameters
(parameter
  name: (identifier) @parameter)

; Type identifiers
(type_identifier) @type

; Qualified identifiers (module$function)
(qualified_identifier) @function.call

; Enum access (Type::Variant)
(enum_access) @constant

; Constants
(const_declaration
  name: (identifier) @constant)

; Built-in types
((type_identifier) @type.builtin
  (#any-of? @type.builtin
   "Int" "String" "Bool" "Void" "F64" "F32" "Float64" "Float32" "Float"
   "Never" "Nil" "Vec" "HashMap" "IntMap" "Set" "Array" "StringBuilder"
   "Option" "Result" "Some" "None" "Ok" "Err"
   "CPtr" "CInt" "CLong" "CChar" "CSize" "Fn" "Regex" "Arena"
   "Mutex" "Channel" "TaskGroup"))

; Symbols
(symbol) @string.special.symbol

; Literals
(integer) @number
(float) @number.float
(string) @string
(interpolated_string) @string
(interpolation) @string.special
(escape_sequence) @string.escape
(boolean) @boolean
(nil) @constant.builtin

; Comments
(comment) @comment.line
(doc_comment) @comment.documentation
(module_doc_comment) @comment.documentation

; Operators
["+" "-" "*" "/" "%" "==" "!=" "<" ">" "<=" ">=" "<<" ">>" "&" "|" "^" "~"
 "=" "+=" "-=" "*=" "/=" "%=" "&=" "|=" "<<=" ">>="
 ".." "..=" "..." "|>" "??" "?." "->" "=>"] @operator

; Punctuation
["(" ")" "[" "]" "{" "}"] @punctuation.bracket
["," ":" "."] @punctuation.delimiter
["$" "::"] @punctuation.special

; Attributes
(attribute "@" @keyword.directive (identifier) @keyword.directive)

; Self
["self" "Self"] @variable.builtin

; Identifiers (catch-all)
(identifier) @variable
