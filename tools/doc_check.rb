#!/usr/bin/env ruby
# frozen_string_literal: true

# Documentation Checker for Quartz
# Enforces "World-Class" documentation standards:
# 1. Every file must have a Module Header
#    - Quartz: `##!` comment block at the top
#    - C: `/**` comment block at the top
# 2. Every public/private entity must be documented
#    - Quartz: `##` comment before `func`, `struct`, `enum`, `const`, `let` (global)
#    - C: `/**` or `///` comment before function definitions and types

require 'colorize' rescue nil # Optional color support

class DocCheck
  QUARTZ_EXTS = ['.qz'].freeze
  C_EXTS = ['.c', '.h'].freeze
  
  # Exclude these directories/files from minimal checks or full checks
  EXCLUDES = [
    'vendor/',
    'build/',
    'bin/',
    'tmp/',
    '.git/',
    'spec/', # Tests generally don't need API docs, but maybe headers?
    'tests/',
    'Rakefile',
    'Gemfile',
  ].freeze

  def initialize(root_dir)
    @root_dir = root_dir
    @errors = []
    @files_checked = 0
  end

  def run
    if File.file?(@root_dir)
      files = [@root_dir]
    else
      files = Dir.glob(File.join(@root_dir, '**/*')).select { |f| File.file?(f) }
    end
    
    files.each do |file|
      next if excluded?(file)
      
      ext = File.extname(file)
      if QUARTZ_EXTS.include?(ext)
        check_quartz(file)
      elsif C_EXTS.include?(ext)
        check_c(file)
      end
    end

    report
    @errors.empty? ? 0 : 1
  end

  private

  def excluded?(file)
    EXCLUDES.any? { |e| file.include?(e) }
  end

  def check_quartz(file)
    @files_checked += 1
    content = File.read(file)
    lines = content.lines

    # 1. Check Module Header (##!)
    # Should be the first non-whitespace, non-shebang thing
    unless content =~ /\A(\s*|#!(.*)\n)*##!/
      add_error(file, 1, "Missing Module Header (##!). File must start with a summary block.")
    end

    # 2. Check Items
    # We scan line by line to ensure comments precede items
    lines.each_with_index do |line, idx|
      next unless line =~ /^\s*(pub\s+)?(func|struct|enum|const|let)\s+(\w+)/
      
      item_type = Regexp.last_match(2)
      item_name = Regexp.last_match(3)
      line_num = idx + 1
      
      # Look backwards for doc comment
      # Allow empty lines between doc and item? No, usually tight.
      # But let's allow 1 empty line for spacing if needed, though style usually says attached.
      # Let's check immediate previous non-empty line.
      
      prev_idx = idx - 1
      while prev_idx >= 0 && lines[prev_idx].strip.empty?
        prev_idx -= 1
      end

      if prev_idx < 0 || !lines[prev_idx].strip.start_with?('##')
        add_error(file, line_num, "Undocumented #{item_type} '#{item_name}'. Must be preceded by `##` comment.")
      end
    end
  end

  def check_c(file)
    @files_checked += 1
    content = File.read(file)
    lines = content.lines

    # 1. Check Module Header
    # Expect /** or // at start (Doxygen style for file)
    # We accept /* ... */ or // ... block at top
    unless content =~ /\A(\s*)\/\*/ || content =~ /\A(\s*)\/\//
      add_error(file, 1, "Missing Module Header. File must start with a Doxygen-style comment block.")
    end

    # 2. Check Items (rough heuristic for C)
    # Functions: `Type name(...) {` at start of line (C bootstrap style usually matches this)
    # Structs: `typedef struct ...`
    
    lines.each_with_index do |line, idx|
      # Heuristic: Function definition at start of line (no whitespace)
      # e.g. "ASTNode* parse_expr(void) {"
      # or "typedef struct {"
      
      is_func = line =~ /^[A-Za-z0-9_]+\s+\*?([A-Za-z0-9_]+)\(.*\)\s*\{/
      is_struct = line =~ /^typedef\s+(struct|enum)\s+\{/
      is_struct_alt = line =~ /^typedef\s+(struct|enum)\s+\w+/
      
      if is_func || is_struct || is_struct_alt
        item_name = Regexp.last_match(1) || "struct/enum"
        line_num = idx + 1
        
        # Check previous lines for /// or /** or */
        prev_idx = idx - 1
        while prev_idx >= 0 && lines[prev_idx].strip.empty?
          prev_idx -= 1
        end

        has_slash_star = lines[prev_idx].strip.end_with?('*/')
        has_slashes = lines[prev_idx].strip.start_with?('//')
        
        unless has_slash_star || has_slashes
           add_error(file, line_num, "Undocumented item near '#{line.strip[0..20]}...'. Must be preceded by comment.")
        end
      end
    end
  end

  def add_error(file, line, msg)
    @errors << { file: file, line: line, msg: msg }
  end

  def report
    if @errors.empty?
      puts "✅ Documentation Check Passed! Checked #{@files_checked} files.".green rescue puts "✅ Documentation Check Passed! Checked #{@files_checked} files."
      return
    end

    puts "\n❌ Documentation Standard Failures:".red rescue puts "\n❌ Documentation Standard Failures:"
    
    # Group by file
    grouped = @errors.group_by { |e| e[:file] }
    
    grouped.each do |file, errors|
      puts "\n#{file}:"
      errors.each do |e|
        puts "  Line #{e[:line]}: #{e[:msg]}"
      end
    end

    puts "\nFound #{@errors.size} violations in #{@files_checked} files.".red rescue puts "\nFound #{@errors.size} violations in #{@files_checked} files."
    puts "Goal: 100% World-Class Documentation Coverage.".yellow rescue puts "Goal: 100% World-Class Documentation Coverage."
  end
end

if __FILE__ == $PROGRAM_NAME
  if ARGV[0] == "--help"
    puts "Usage: doc_check.rb [root_dir]"
    exit 0
  end

  root_dir = ARGV[0] || "."
  checker = DocCheck.new(root_dir)
  exit checker.run
end
