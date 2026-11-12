#!/usr/bin/env ruby
# frozen_string_literal: true

# tools/check_constants.rb - Constant parity validation
#
# Ensures AST node kind constants (NODE_*) stay in sync across all compiler
# modules. The canonical source of truth is frontend/node_constants.qz.
#
# Consumer files may define subsets of the full constant set — this is normal.
# The script only fails on VALUE MISMATCHES: i.e., same constant name but
# different numeric value between the canonical file and a consumer.
#
# Also verifies OP_* parity between mir.qz and codegen.qz, and documents
# the TYPE_* divergence between typecheck.qz and types.qz (separate systems).
#
# Usage:
#   ruby tools/check_constants.rb            # Check only, no verbose
#   ruby tools/check_constants.rb --verbose  # Show coverage info
#   rake check_constants                     # Rake integration

require "set"

SELF_HOSTED = File.expand_path("../self-hosted", __dir__)
VERBOSE = ARGV.include?("--verbose")

# Parse `const NAME = VALUE` declarations from a .qz file.
# Returns Hash{ name => value }
def parse_constants(path, prefix: nil)
  constants = {}
  File.readlines(path).each do |line|
    if line =~ /^const\s+(\w+)\s*=\s*(-?\d+)/
      name, value = $1, $2.to_i
      next if prefix && !name.start_with?(prefix)
      constants[name] = value
    end
  end
  constants
end

# Check that every constant in `consumer` that also exists in `canonical`
# has the same value. Only VALUE MISMATCHES are errors.
def check_parity(canonical_path, consumer_path, prefix:)
  canonical = parse_constants(canonical_path, prefix: prefix)
  consumer  = parse_constants(consumer_path,  prefix: prefix)

  errors = []
  canonical_basename = File.basename(canonical_path)
  consumer_basename  = File.basename(consumer_path)

  # Check for value mismatches
  shared = consumer.keys & canonical.keys
  shared.each do |name|
    if consumer[name] != canonical[name]
      errors << "MISMATCH: #{consumer_basename} has #{name}=#{consumer[name]}, " \
                "#{canonical_basename} has #{name}=#{canonical[name]}"
    end
  end

  # Coverage info (verbose only)
  if VERBOSE
    coverage_pct = shared.size.to_f / canonical.size * 100
    puts "  → #{consumer_basename}: #{shared.size}/#{canonical.size} constants " \
         "(#{coverage_pct.round(1)}% coverage)"
  end

  errors
end

# === NODE_* parity checks ===

canonical_nodes = File.join(SELF_HOSTED, "frontend/node_constants.qz")
node_consumers = %w[
  middle/typecheck.qz
  backend/mir.qz
  frontend/parser.qz
  frontend/ast_print.qz
].map { |f| File.join(SELF_HOSTED, f) }

# === OP_* parity checks (mir.qz is canonical, codegen.qz is subset) ===

canonical_ops   = File.join(SELF_HOSTED, "backend/mir.qz")
op_consumers    = [File.join(SELF_HOSTED, "backend/codegen.qz")]

# === Run checks ===

all_errors = []

puts "Constant Parity Validation"
puts "=" * 40
puts ""
puts "NODE_* (canonical: node_constants.qz)"

node_consumers.each do |consumer|
  next unless File.exist?(consumer)
  errors = check_parity(canonical_nodes, consumer, prefix: "NODE_")
  if errors.empty?
    puts "  ✓ #{File.basename(consumer)}"
  else
    errors.each { |e| puts "  ✗ #{e}" }
    all_errors.concat(errors)
  end
end

puts ""
puts "OP_* (canonical: mir.qz)"

op_consumers.each do |consumer|
  next unless File.exist?(consumer)
  errors = check_parity(canonical_ops, consumer, prefix: "OP_")
  if errors.empty?
    puts "  ✓ #{File.basename(consumer)}"
  else
    errors.each { |e| puts "  ✗ #{e}" }
    all_errors.concat(errors)
  end
end

puts ""
puts "TYPE_* (note: typecheck.qz and types.qz are independent systems)"
puts "  ℹ  typecheck.qz: type checker classification (53 types)"
puts "  ℹ  types.qz: type storage constructors (38 types)"
puts "  ℹ  mir.qz: MIR_TYPE_* codegen classification (12 types)"
puts "  These are intentionally different. No parity check needed."

# === Summary ===

puts ""
canonical_count = parse_constants(canonical_nodes, prefix: "NODE_").size
if all_errors.empty?
  puts "All parity checks passed. #{canonical_count} canonical NODE_* constants."
  exit 0
else
  puts "#{all_errors.size} constant parity error(s) found!"
  puts "Fix: update the consumer file to match the canonical source."
  exit 1
end
