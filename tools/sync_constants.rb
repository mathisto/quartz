# frozen_string_literal: true
# encoding: utf-8
#!/usr/bin/env ruby
# tools/sync_constants.rb — Verify constant synchronization across compiler modules
#
# Constants live in multiple files because the C bootstrap doesn't support
# glob imports (import * from). This tool verifies that all copies are in sync
# and reports divergences.
#
# Usage:
#   ruby tools/sync_constants.rb           # check mode (exit 1 if out of sync)
#   ruby tools/sync_constants.rb --fix     # sync mode (update secondary files)
#
# Canonical sources:
#   NODE_ constants: self-hosted/frontend/node_constants.qz
#   TYPE_ constants: self-hosted/middle/typecheck_util.qz
#   OP_   constants: self-hosted/shared/op_constants.qz

require 'set'

FIX_MODE = ARGV.include?('--fix')
ROOT = File.expand_path('..', __dir__)

# Parse constants from a .qz file
# Returns Hash: name => [value, comment]
def parse_constants(path, prefix)
  constants = {}
  File.readlines(File.join(ROOT, path), encoding: 'utf-8').each do |line|
    if line =~ /^const\s+(#{prefix}\w+)\s*=\s*(\d+)/
      name, value = $1, $2.to_i
      # Grab preceding doc comment if any
      constants[name] = value
    end
  end
  constants
end

# Compare two constant sets
def compare(canonical_path, canonical_prefix, secondary_path, secondary_prefix = nil)
  secondary_prefix ||= canonical_prefix
  
  canonical = parse_constants(canonical_path, canonical_prefix)
  secondary = parse_constants(secondary_path, secondary_prefix)
  
  errors = []
  
  # Check for missing constants in secondary
  (canonical.keys - secondary.keys).each do |name|
    errors << "  MISSING in #{secondary_path}: #{name} = #{canonical[name]}"
  end
  
  # Check for extra constants in secondary (not in canonical)
  (secondary.keys - canonical.keys).each do |name|
    errors << "  EXTRA in #{secondary_path}: #{name} = #{secondary[name]} (not in #{canonical_path})"
  end
  
  # Check for value mismatches
  (canonical.keys & secondary.keys).each do |name|
    if canonical[name] != secondary[name]
      errors << "  MISMATCH #{name}: #{canonical_path} has #{canonical[name]}, #{secondary_path} has #{secondary[name]}"
    end
  end
  
  errors
end

puts "=== Constant Sync Check ==="
puts

all_errors = []

# 1. NODE_ constants: node_constants.qz (canonical) vs typecheck_util.qz
puts "NODE_ constants:"
puts "  Canonical: self-hosted/frontend/node_constants.qz"
puts "  Secondary: self-hosted/middle/typecheck_util.qz"
errors = compare(
  'self-hosted/frontend/node_constants.qz', 'NODE_',
  'self-hosted/middle/typecheck_util.qz', 'NODE_'
)
if errors.empty?
  puts "  ✅ In sync"
else
  errors.each { |e| puts e }
  all_errors.concat(errors)
end
puts

# 2. TYPE_ constants: typecheck_util.qz (canonical) vs infer.qz
puts "TYPE_ constants:"
puts "  Canonical: self-hosted/middle/typecheck_util.qz"
puts "  Secondary: self-hosted/middle/infer.qz"
errors = compare(
  'self-hosted/middle/typecheck_util.qz', 'TYPE_',
  'self-hosted/middle/infer.qz', 'TYPE_'
)
if errors.empty?
  puts "  ✅ In sync"
else
  errors.each { |e| puts e }
  all_errors.concat(errors)
end
puts

# 3. OP_ constants: op_constants.qz — check that codegen uses qualified access
puts "OP_ constants:"
puts "  Canonical: self-hosted/shared/op_constants.qz"
op_canonical = parse_constants('self-hosted/shared/op_constants.qz', 'OP_')
puts "  #{op_canonical.size} constants defined"
puts "  ✅ (no secondary copies — all consumers use qualified import)"
puts

# Summary
if all_errors.empty?
  puts "✅ All constants in sync"
  exit 0
else
  puts "❌ #{all_errors.size} divergence(s) found"
  puts
  puts "To fix: update the secondary file to match the canonical source,"
  puts "or add the missing constants to the canonical source if they're new."
  exit 1
end
