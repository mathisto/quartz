#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates self-hosted/frontend/token_constants.qz from bootstrap/src/lexer.h
#
# This ensures the self-hosted lexer and parser use the exact same token type
# values as the C bootstrap compiler. Single source of truth.
#
# Usage: ruby tools/generate_tokens.rb
#        rake generate_tokens

LEXER_H = '../quartz-bootstrap/src/lexer.h'
OUTPUT = 'self-hosted/frontend/token_constants.qz'

def parse_token_enum(content)
  tokens = []

  in_enum = false
  value = 0

  content.each_line do |line|
    if /typedef enum \{/.match?(line)
      in_enum = true
      next
    end

    break if in_enum && line =~ /^\} TokenType;/

    next unless in_enum

    # Skip comments-only lines and blank lines
    next if line.strip.empty?
    next if line.strip.start_with?('/*') && !line.include?('TOK_')

    # Match token definitions like: TOK_EOF = 0, or TOK_NEWLINE,
    next unless line =~ %r{^\s*(TOK_\w+)\s*(?:=\s*(\d+))?\s*,?\s*(?:/\*.*\*/)?}

    name = Regexp.last_match(1)
    explicit_value = Regexp.last_match(2)

    value = explicit_value.to_i if explicit_value

    tokens << { name: name, value: value }
    value += 1
  end

  tokens
end

def generate_qz_constants(tokens)
  lines = []
  lines << '# token_constants.qz - Generated from bootstrap/src/lexer.h'
  lines << "# DO NOT EDIT - Run 'rake generate_tokens' to regenerate"
  lines << '#'
  lines << '# Single source of truth for token type values.'
  lines << '# Used by both lexer.qz and parser.be.'
  lines << ''

  # Group tokens by category based on name patterns

  # Generate constant functions for each token
  tokens.each do |tok|
    short_name = tok[:name].sub(/^TOK_/, '')
    lines << "def TOK_#{short_name}(): Int"
    lines << "  return #{tok[:value]}"
    lines << 'end'
    lines << ''
  end

  lines.join("\n")
end

def main
  unless File.exist?(LEXER_H)
    warn "Error: #{LEXER_H} not found"
    warn 'Run from project root directory'
    exit 1
  end

  content = File.read(LEXER_H)
  tokens = parse_token_enum(content)

  if tokens.empty?
    warn "Error: No tokens found in #{LEXER_H}"
    exit 1
  end

  output = generate_qz_constants(tokens)

  # Ensure output directory exists
  require 'fileutils'
  FileUtils.mkdir_p(File.dirname(OUTPUT))

  File.write(OUTPUT, output)

  puts "Generated #{OUTPUT} with #{tokens.size} token constants"

  # Print summary
  puts "\nToken values:"
  tokens.each do |tok|
    printf "  %-20s = %d\n", tok[:name], tok[:value]
  end
end

main if __FILE__ == $0
