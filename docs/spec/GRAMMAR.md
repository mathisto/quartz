# Quartz Language Grammar — Formal Specification

> **Version**: 5.25.0  
> **Status**: Living document — tracks the parser implementation  
> **Source of truth**: `self-hosted/frontend/parser.qz` (5712 lines)

## Notation

This grammar uses Extended Backus-Naur Form (EBNF) with the following conventions:

| Notation       | Meaning                            |
|----------------|------------------------------------|
| `'keyword'`    | Terminal keyword (literal text)    |
| `TOKEN`        | Terminal token from lexer          |
| `rule`         | Non-terminal (grammar rule)        |
| `rule?`        | Optional (zero or one)             |
| `rule*`        | Zero or more                       |
| `rule+`        | One or more                        |
| `rule1 \| rule2` | Alternation                      |
| `( ... )`      | Grouping                           |
| `NL`           | Newline or semicolon               |

---

## 1. Program Structure

```ebnf
program        = NL* ( top_level NL* )* EOF ;

top_level      = import_decl
               | struct_decl
               | enum_decl
               | trait_decl
               | impl_decl
               | extend_decl
               | type_alias_decl
               | newtype_decl
               | const_decl
               | extern_decl
               | macro_decl
               | visibility_decl
               | func_decl
               | annotation top_level ;

visibility_decl = 'private' ;
```

## 2. Import Declarations

```ebnf
import_decl    = 'import' import_path
               | 'import' '*' 'from' import_path ;

import_path    = IDENT ( '/' IDENT )* ;
```

## 3. Type Expressions

```ebnf
type           = borrow_type
               | never_type
               | record_type
               | function_type
               | named_type
               | type union_or_intersect ;

borrow_type    = '&' 'mut'? type ;
never_type     = '!' ;

record_type    = '{' ( field_type ( ',' field_type )* )? '}'
                 union_or_intersect? ;

field_type     = IDENT ':' type ;

function_type  = 'Fn' '(' ( type ( ',' type )* )? ')' ( ':' type )? ;

named_type     = IDENT ( '.' IDENT )* type_args? ;

type_args      = '<' type ( ',' type )* '>' ;

type_params    = '<' IDENT ( ',' IDENT )* '>' ;

union_or_intersect = ( '|' type | '&' type )* ;
```

## 4. Function Declarations

```ebnf
func_decl      = 'def' IDENT type_params?
                 '(' param_list? ')' ( ':' type )?
                 ( '=' expr | NL body 'end' )
               | 'def' IDENT type_params?
                 '(' param_list? ')' ( ':' type )?
                 where_clause?
                 NL body 'end' ;

param_list     = param ( ',' param )* ;
param          = IDENT ':' type ( '=' expr )? ;

where_clause   = 'where' constraint ( ',' constraint )* ;
constraint     = IDENT ':' type ( '+' type )* ;
```

## 5. Struct, Enum, Trait, Impl, Extend

```ebnf
struct_decl    = annotation? 'struct' IDENT type_params? NL
                 ( doc_comment? field_decl NL )* 'end' ;

field_decl     = IDENT ':' type ( '=' expr )? ;

enum_decl      = 'enum' IDENT type_params? NL
                 ( doc_comment? variant_decl NL )* 'end' ;

variant_decl   = IDENT ( '(' type ( ',' type )* ')' )? ;

trait_decl     = 'trait' IDENT type_params? NL
                 ( func_decl NL )* 'end' ;

impl_decl      = 'impl' IDENT 'for' type NL
                 ( func_decl NL )* 'end' ;

extend_decl    = 'extend' type type_params? NL
                 ( func_decl NL )* 'end' ;
```

## 6. Type Aliases and Newtypes

```ebnf
type_alias_decl = 'type' IDENT type_params? '=' type ;

newtype_decl   = 'newtype' IDENT '=' type ;
```

## 7. Constants

```ebnf
const_decl     = 'const' IDENT ( ':' type )? '=' expr ;
```

## 8. Extern (FFI)

```ebnf
extern_decl    = 'extern' STRING 'def' IDENT
                 '(' param_list? ')' ( ':' type )? ;
```

## 9. Macro Declarations

```ebnf
macro_decl     = 'macro' IDENT '(' param_list? ')' NL
                 body 'end' ;
```

## 10. Annotations

```ebnf
annotation     = '@' IDENT ( '(' annotation_args ')' )? ;
annotation_args = IDENT ( ',' IDENT )* ;
```

## 11. Statements

```ebnf
body           = ( stmt NL )* ;

stmt           = const_assign
               | var_stmt
               | return_stmt
               | if_stmt
               | unless_stmt
               | while_stmt
               | loop_stmt
               | for_stmt
               | match_expr
               | break_stmt
               | continue_stmt
               | defer_stmt
               | arena_stmt
               | try_stmt
               | spawn_stmt
               | select_stmt
               | task_group_stmt
               | assign_stmt
               | expr ;

const_assign   = IDENT ( ':' type )? '=' expr ;
var_stmt       = 'var' IDENT ( ':' type )? '=' expr ;

return_stmt    = 'return' expr? ;

if_stmt        = 'if' expr NL body
                 ( 'elsif' expr NL body )*
                 ( 'else' NL body )?
                 'end'
               | expr 'if' expr          (* postfix if *)
               | expr 'unless' expr ;    (* postfix unless *)

unless_stmt    = 'unless' expr NL body 'end' ;

while_stmt     = 'while' expr NL body 'end' ;

loop_stmt      = 'loop' NL body 'end' ;

for_stmt       = 'for' IDENT 'in' expr '..' expr NL body 'end'
               | 'for' IDENT 'in' expr NL body 'end' ;

break_stmt     = 'break' ;
continue_stmt  = 'continue' ;

defer_stmt     = 'defer' expr ;

arena_stmt     = 'arena' NL body 'end' ;

try_stmt       = 'try' NL body
                 ( 'catch' IDENT NL body )?
                 'end' ;

spawn_stmt     = 'spawn' expr ;

select_stmt    = 'select' NL
                 ( 'when' expr NL body )*
                 ( 'default' NL body )?
                 'end' ;

task_group_stmt = 'task_group' IDENT NL body 'end' ;
```

## 12. Assignment

```ebnf
assign_stmt    = lvalue '=' expr
               | lvalue compound_op expr ;

lvalue         = IDENT
               | expr '.' IDENT
               | expr '[' expr ']' ;

compound_op    = '+=' | '-=' | '*=' | '/=' | '%=' | '^=' ;
```

## 13. Expressions

```ebnf
expr           = arrow_lambda
               | or_expr
               | or_expr '?' expr ':' expr    (* ternary *)
               | or_expr '??' expr            (* nil coalesce *)
               | or_expr '|>' expr            (* pipe *)
               | expr 'as' type              (* type cast *)
               | 'not' expr ;

or_expr        = and_expr ( 'or' and_expr )* ;
and_expr       = eq_expr ( 'and' eq_expr )* ;
eq_expr        = cmp_expr ( ( '==' | '!=' | '=~' | '!~' | '?=' ) cmp_expr )* ;
cmp_expr       = bitor_expr ( ( '<' | '>' | '<=' | '>=' ) bitor_expr )* ;
bitor_expr     = bitxor_expr ( '|' bitxor_expr )* ;
bitxor_expr    = bitand_expr ( '^' bitand_expr )* ;
bitand_expr    = shift_expr ( '&' shift_expr )* ;
shift_expr     = add_expr ( ( '<<' | '>>' ) add_expr )* ;
add_expr       = mul_expr ( ( '+' | '-' ) mul_expr )* ;
mul_expr       = unary_expr ( ( '*' | '/' | '%' ) unary_expr )* ;

unary_expr     = '-' unary_expr
               | '~' unary_expr
               | '!' unary_expr
               | '&' 'mut'? unary_expr      (* address-of / borrow *)
               | '*' unary_expr             (* dereference *)
               | postfix_expr ;

postfix_expr   = primary ( postfix_op )* ;

postfix_op     = '.' IDENT ( '(' arg_list? ')' )?    (* field access / method call *)
               | '?.' IDENT                            (* optional chaining *)
               | '[' expr ']'                          (* index *)
               | '(' arg_list? ')' do_block?           (* function call *)
               | '!' IDENT                             (* unwrap variant *)
               | '$' IDENT ( '(' arg_list? ')' )?      (* qualified call *)
               | 'as' type ;                           (* type cast *)
```

## 14. Primary Expressions

```ebnf
primary        = INT_LIT
               | FLOAT_LIT
               | CHAR_LIT
               | STRING_LIT
               | INTERP_STRING
               | REGEX_LIT
               | SYMBOL_LIT
               | 'true' | 'false'
               | 'nil'
               | IDENT enum_or_struct_or_call?
               | '(' expr ')'                          (* grouped *)
               | '(' expr ',' expr ( ',' expr )* ')'   (* tuple *)
               | '[' ( expr ( ',' expr )* )? ']'       (* array *)
               | '{' map_or_set_literal '}'             (* map/set *)
               | match_expr
               | if_expr
               | do_block
               | macro_call
               | '_'                                    (* wildcard *)
               | 'await' expr ;

match_expr     = 'match' expr NL
                 ( pattern '=>' ( expr | NL body 'end' ) NL )*
                 'end' ;

if_expr        = 'if' expr 'then' expr 'else' expr ;

do_block       = 'do' ( param ( ',' param )* '->' )?
                 NL body 'end' ;

macro_call     = '$' IDENT '(' arg_list? ')' ;
```

## 15. Patterns

```ebnf
pattern        = '_'                                    (* wildcard *)
               | INT_LIT
               | STRING_LIT
               | 'true' | 'false' | 'nil'
               | IDENT '::' IDENT ( '(' pattern_list ')' )?  (* enum variant *)
               | IDENT                                  (* binding *)
               | pattern 'if' expr                      (* guard *)
               | pattern '|' pattern ;                  (* or-pattern *)

pattern_list   = pattern ( ',' pattern )* ;
```

## 16. Argument Lists

```ebnf
arg_list       = expr ( ',' expr )* ;
```

## 17. Operator Precedence (highest to lowest)

| Prec | Operators                    | Assoc | Description         |
|------|------------------------------|-------|---------------------|
| 14   | `.` `?.` `[]` `()` `!` `$`  | Left  | Postfix             |
| 13   | `-` `~` `!` `&` `*` (unary) | Right | Unary               |
| 12   | `*` `/` `%`                  | Left  | Multiplicative      |
| 11   | `+` `-`                      | Left  | Additive            |
| 10   | `<<` `>>`                    | Left  | Shift               |
| 9    | `&`                          | Left  | Bitwise AND         |
| 8    | `^`                          | Left  | Bitwise XOR         |
| 7    | `\|`                         | Left  | Bitwise OR          |
| 6    | `<` `>` `<=` `>=`            | Left  | Comparison          |
| 5    | `==` `!=` `=~` `!~` `?=`    | Left  | Equality            |
| 4    | `and`                        | Left  | Logical AND         |
| 3    | `or`                         | Left  | Logical OR          |
| 2    | `\|>`                        | Left  | Pipe                |
| 1    | `??`                         | Right | Nil coalesce        |
| 0    | `? :`                        | Right | Ternary             |

## 18. Lexical Grammar

```ebnf
(* Whitespace *)
WS             = ' ' | '\t' | '\r' ;

(* Newline *)
NL             = '\n' | ';' ;

(* Comments *)
comment        = '#' (not '\n')* ;
doc_comment    = '##' (not '\n')* ;
module_doc     = '##!' (not '\n')* ;

(* Identifiers *)
IDENT          = letter ( letter | digit | '_' )* ;
letter         = 'a'..'z' | 'A'..'Z' | '_' ;
digit          = '0'..'9' ;

(* Integer literals *)
INT_LIT        = decimal_lit | hex_lit | binary_lit ;
decimal_lit    = digit ( digit | '_' )* type_suffix? ;
hex_lit        = '0' ('x'|'X') hex_digit ( hex_digit | '_' )* ;
binary_lit     = '0' ('b'|'B') ('0'|'1') ( '0' | '1' | '_' )* ;
type_suffix    = '_' ('u8'|'i8'|'u16'|'i16'|'u32'|'i32'|'u64'|'i64') ;

(* Float literals *)
FLOAT_LIT      = digit+ '.' digit+ ;

(* String literals *)
STRING_LIT     = '"' string_char* '"' ;
string_char    = escape_seq | (not '"' and not '\') ;
escape_seq     = '\' ('n'|'t'|'r'|'\\'|'"'|'0'|'e') ;

(* Regex literals *)
REGEX_LIT      = '~r"' (not '"')* '"' ;

(* Character literals *)
CHAR_LIT       = "'" (escape_seq | not "'") "'" ;

(* Symbol literals *)
SYMBOL_LIT     = ':' IDENT ;
```

## 19. Keywords (Reserved)

```
and       arena     as        await     break     catch
const     continue  def       default   defer     do
else      elsif     end       enum      extend    extern
false     for       from      if        impl      import
in        let       loop      macro     match     newtype
nil       not       or        private   public    quote
return    select    spawn     struct    task_group then
trait     true      try       type      unless    unquote
unquote_each        var       when      where     while
```
