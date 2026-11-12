#!/usr/bin/env ruby
# frozen_string_literal: true

class BeLinter
  ERRORS = []
  WARNINGS = []

  def initialize(src_dir)
    @src_dir = src_dir
  end

  def run
    check_orphan_tokens
    check_all_token_handlers

    report
    ERRORS.empty? ? 0 : 1
  end

  private

  def lexer_file
    File.join(@src_dir, 'lexer.c')
  end

  def lexer_header
    File.join(@src_dir, 'lexer.h')
  end

  def parser_file
    File.join(@src_dir, 'parser.c')
  end

  def check_orphan_tokens
    return unless File.exist?(lexer_header) && File.exist?(parser_file)

    lexer_tokens = extract_token_types
    parser_handlers = extract_parser_switch_cases

    orphans = lexer_tokens - parser_handlers - ignored_tokens

    orphans.each do |token|
      ERRORS << "ORPHAN TOKEN: '#{token}' is defined in lexer but never handled in parser"
    end
  end

  def check_all_token_handlers
    return unless File.exist?(parser_file)

    parser_content = File.read(parser_file)

    required_handlers = %w[
      TOK_INT TOK_STRING TOK_IDENT TOK_TRUE TOK_FALSE
      TOK_PLUS TOK_MINUS TOK_STAR TOK_SLASH TOK_PERCENT
      TOK_EQ TOK_NE TOK_LT TOK_GT TOK_LE TOK_GE
      TOK_LPAREN TOK_RPAREN
    ]

    required_handlers.each do |tok|
      WARNINGS << "Token #{tok} may not be handled in parser" unless parser_content.include?(tok)
    end
  end

  def extract_token_types
    content = File.read(lexer_header)
    tokens = []

    content.scan(/TOK_(\w+)/) do |match|
      tokens << "TOK_#{match[0]}"
    end

    tokens.uniq
  end

  def extract_parser_switch_cases
    content = File.read(parser_file)
    handlers = []

    content.scan(/case (TOK_\w+):/) do |match|
      handlers << match[0]
    end

    content.scan(/== (TOK_\w+)/) do |match|
      handlers << match[0]
    end

    content.scan(/!= (TOK_\w+)/) do |match|
      handlers << match[0]
    end

    handlers.uniq
  end

  def ignored_tokens
    %w[TOK_EOF TOK_ERROR TOK_NEWLINE TOK_INDENT TOK_DEDENT]
  end

  def report
    if ERRORS.empty? && WARNINGS.empty?
      puts '✅ Lint passed'
      return
    end

    ERRORS.each { |e| puts "❌ ERROR: #{e}" }
    WARNINGS.each { |w| puts "⚠️  WARNING: #{w}" }

    puts
    puts "#{ERRORS.size} error(s), #{WARNINGS.size} warning(s)"
  end
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.empty?
    puts 'Usage: lint.rb <src_dir>'
    exit 1
  end

  linter = BeLinter.new(ARGV[0])
  exit linter.run
end
