#!/usr/bin/env ruby
# Quartz language balance checker - verifies opening constructs have matching 'end'

OPENERS = %w[def if while for struct enum match]

def check_balance(file)
  lines = File.read(file).lines
  stack = []
  errors = []

  lines.each_with_index do |line, idx|
    line_num = idx + 1
    stripped = line.strip

    next if stripped.start_with?('#')

    OPENERS.each do |kw|
      next unless stripped =~ /^#{kw}\b/ || stripped =~ /^\w+\s*=\s*#{kw}\b/
      next if kw == 'if' && stripped =~ /^elsif\b/

      stack.push([kw, line_num])
    end

    if /^end\b/.match?(stripped)
      if stack.empty?
        errors << "Line #{line_num}: Unexpected 'end' with no matching opener"
      else
        stack.pop
      end
    end
  end

  stack.each do |kw, line_num|
    errors << "Line #{line_num}: Unclosed '#{kw}' - missing 'end'"
  end

  if errors.empty?
    puts "#{file}: OK (balanced)"
  else
    puts "#{file}: #{errors.length} balance error(s)"
    errors.each { |e| puts "  #{e}" }
  end

  errors.length
end

files = ARGV.empty? ? Dir['self-hosted/**/*.qz'] : ARGV
total_errors = files.sum { |f| check_balance(f) }
exit(total_errors > 0 ? 1 : 0)
