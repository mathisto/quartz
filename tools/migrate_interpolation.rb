#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: utf-8
#
# tools/migrate_interpolation.rb — Migrate string concatenation to interpolation
#
# Converts patterns like:
#   "prefix" + expr + "suffix"   →   "prefix#{expr}suffix"
#   expr + ".field"              →   "#{expr}.field"
#   "prefix" + expr              →   "prefix#{expr}"
#
# Usage:
#   ruby tools/migrate_interpolation.rb <file.qz> > output.qz
#

ARGV.length == 1 or abort "Usage: #{$0} <file.qz>"
source = File.read(ARGV[0], encoding: 'utf-8')

# ---------------------------------------------------------------------------
# Tokenizer
#
# Token kinds:
#   :string      — a double-quoted string literal (including escaped chars)
#   :concat_plus — the ` + ` concatenation operator (with spaces on both sides)
#   :expr        — an identifier/method-call expression that participates in
#                  a string concat chain
#   :verbatim    — everything else (preserved byte-for-byte)
#
# The tokenizer produces tokens that reconstruct the original line exactly
# when joined.
# ---------------------------------------------------------------------------

# Scan a double-quoted string starting at `pos`.  Returns [text, new_pos].
# `text` includes the surrounding quotes and any escape sequences verbatim.
def scan_string(s, pos)
  i = pos + 1
  while i < s.length
    ch = s[i]
    if ch == '\\'
      i += 2   # skip escape sequence (including escaped quote)
    elsif ch == '"'
      return [s[pos..i], i + 1]
    else
      i += 1
    end
  end
  # Unterminated — return rest (shouldn't happen in valid Quartz source)
  [s[pos..], s.length]
end

# Scan an expression token starting at `pos`: an identifier optionally followed
# by any combination of `[…]`, `(…)`, and `.name`.  We track bracket depth so
# that `args[i].to_s()` is consumed as a single token.
#
# The token ends at:
#   - depth-0 space (` + ` separator or end of argument)
#   - depth-0 comma
#   - depth-0 `)`  or `]`  (function/array boundary)
#   - depth-0 `"`  (start of adjacent string)
def scan_expr(s, pos)
  depth = 0
  i = pos
  while i < s.length
    ch = s[i]
    case ch
    when '(', '['
      depth += 1
      i += 1
    when ')', ']'
      break if depth == 0
      depth -= 1
      i += 1
    when '"'
      break if depth == 0
      _, i = scan_string(s, i)   # consume string inside parens (edge case)
    when ' '
      break if depth == 0
      i += 1
    when ','
      break if depth == 0
      i += 1
    else
      i += 1
    end
  end
  [s[pos...i], i]
end

# Return true if the character at `s[pos]` (after stripping a potential expr)
# is followed by ` + ` then another string or identifier — i.e. this position
# starts an expr that participates in a concat chain.
#
# We probe by scanning a hypothetical expr and checking what follows.
# A character is a valid expression start for our purposes if it begins an
# identifier, a subscript/call expression, or a parenthesized expression like
# `(init_cap * 8).to_s()`.
def concat_expr_start?(ch)
  ch == '"' || ch =~ /[a-zA-Z_(]/
end

def expr_followed_by_concat?(s, pos)
  _, after = scan_expr(s, pos)
  s[after, 3] == ' + ' && after + 3 < s.length &&
    concat_expr_start?(s[after + 3])
end

def tokenize_line(line)
  tokens = []
  i = 0
  n = line.length

  while i < n
    # --- String literal ---
    if line[i] == '"'
      text, i = scan_string(line, i)
      tokens << [:string, text]

    # --- Concat operator: ` + ` (spaces on both sides) followed by string/expr ---
    elsif line[i, 3] == ' + '
      j = i + 3
      last_kind = tokens.last&.first
      # Treat as concat only when the preceding token was string or expr
      # AND the following token is a string or identifier
      if (last_kind == :string || last_kind == :expr) &&
         j < n && concat_expr_start?(line[j])
        tokens << [:concat_plus, ' + ']
        i = j
      else
        tokens << [:verbatim, line[i]]
        i += 1
      end

    # --- Expression: identifier or paren-expr that will be part of a concat chain ---
    #
    # Three entry paths:
    #   a) We're immediately after a :concat_plus (the normal "string + expr" case)
    #   b) An identifier followed by ` + "` or ` + identifier` ("expr + string" case)
    #   c) A `(…)` expression (e.g. `(init_cap * 8).to_s()`) followed by ` + "`
    elsif line[i] =~ /[a-zA-Z_(]/
      last_kind = tokens.last&.first
      if last_kind == :concat_plus || expr_followed_by_concat?(line, i)
        text, i = scan_expr(line, i)
        tokens << [:expr, text]
      else
        tokens << [:verbatim, line[i]]
        i += 1
      end

    else
      tokens << [:verbatim, line[i]]
      i += 1
    end
  end

  tokens
end

# ---------------------------------------------------------------------------
# Chain merging
#
# Find contiguous runs of :string/:concat_plus/:expr and collapse them into a
# single interpolated :string token.  A run must contain at least one
# :concat_plus to qualify.
# ---------------------------------------------------------------------------

def merge_chains(tokens)
  result = []
  i = 0

  while i < tokens.length
    kind, text = tokens[i]

    if kind == :string || kind == :expr
      # Try to extend into a chain
      chain = [[kind, text]]
      j = i + 1

      while j + 1 < tokens.length &&
            tokens[j][0] == :concat_plus &&
            (tokens[j + 1][0] == :string || tokens[j + 1][0] == :expr)
        chain << tokens[j]       # :concat_plus
        chain << tokens[j + 1]   # :string or :expr
        j += 2
      end

      # Also check: chain ending with a single concat+expr (chain = [s/e, +, e])
      # already handled above.

      has_concat = chain.any? { |k, _| k == :concat_plus }

      if has_concat
        result << [:string, build_interpolated(chain)]
        i = j
      else
        result << tokens[i]
        i += 1
      end
    else
      result << tokens[i]
      i += 1
    end
  end

  result
end

# Build an interpolated string from a chain of alternating :string/:expr tokens
# separated by :concat_plus tokens.  Returns the complete string literal text.
def build_interpolated(chain)
  parts = chain.reject { |k, _| k == :concat_plus }

  inner = +''
  parts.each do |kind, text|
    case kind
    when :string
      inner << text[1..-2]          # strip surrounding quotes
    when :expr
      inner << "\#{#{text}}"
    end
  end

  "\"#{inner}\""
end

# ---------------------------------------------------------------------------
# Per-line driver
# ---------------------------------------------------------------------------

def transform_line(line)
  return line unless line.include?(' + ')

  stripped = line.lstrip
  return line if stripped.start_with?('#')

  tokens = tokenize_line(line)
  return line unless tokens.any? { |k, _| k == :concat_plus }

  merged = merge_chains(tokens)
  merged.map { |_, text| text }.join
end

lines = source.lines
result = lines.map { |line| transform_line(line.chomp) + "\n" }
print result.join
