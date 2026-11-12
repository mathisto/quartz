# frozen_string_literal: true
# encoding: utf-8
#!/usr/bin/env ruby
#
# tools/refactor_intrinsics.rb — Automated intrinsic dispatch table refactor
#
# Parses codegen_intrinsics.qz, extracts each handler block, categorizes by name,
# and generates two-level dispatch: HashMap name→category, per-category functions.
#
# Usage:
#   ruby tools/refactor_intrinsics.rb --analyze   # Show categories and counts
#   ruby tools/refactor_intrinsics.rb --generate  # Generate refactored code

require 'set'

ROOT = File.expand_path('..', __dir__)
SOURCE = File.join(ROOT, 'self-hosted/backend/codegen_intrinsics.qz')
OUTPUT = File.join(ROOT, 'self-hosted/backend/codegen_intrinsics_v2.qz')

CATEGORIES = {
  'io' => %w[puts eputs print eprint print_int eprint_int write_bytes read_line
             read_file write_file open_file close_file fread fwrite pipe_open pipe_close
             capture_output_start capture_output_end mkdir readdir
             path_basename path_dir path_ext path_join],
  'string' => /^str_|^to_str$|^f64_to_str$|^char_|^string_to_cstr$|^cstr_to_string$|^cptr_to_string/,
  'regex' => /^regex_/,
  'vec' => /^vec_/,
  'map' => /^map_/,
  'set' => /^set_/,
  'math' => %w[abs min max clamp pow sqrt ceil floor round log sin cos tan rand] +
            %w[band bor bxor bnot shl shr clz ctz popcount bswap rotl rotr],
  'simd' => /^simd_/,
  'concurrency' => /^channel_|^mutex_|^atomic_|^task_|^thread_|^taskgroup_|^spawn$|^send$|^recv$|
                    ^try_send$|^try_recv$|^recv_timeout$|^parallel_|^is_cancelled$|^fence$|^compiler_fence$/x,
  'sb' => /^sb_/,
  'memory' => /^malloc$|^free$|^qz_malloc$|^qz_free$|^realloc$|^memcpy$|^arena_|^pool_|^ptr_|^sizeof$|
              ^bump_|^alloc$|^load$|^store$|^volatile_load$|^volatile_store$|^addr_of$|^field_offset$|
              ^drop$|^gc_|^option_/x,
  'conversion' => /^as_|^to_|^from_|^cast_|^i8_|^i16_|^i32_|^u8_|^u16_|^u32_|^f64_|^f32_|
                   ^int_to_|^cptr_to_int$|^fn_to_int$|^Int\$|^F64\$/x,
  'collection' => %w[all any each enumerate filter find first flatten group_by last
                     map partition product reduce reverse slice sort sum take unique zip
                     count array_new array_get array_set array_len slice_get slice_len slice_set
                     range_new range_start range_end range_len range_contains],
  'system' => %w[exit abort panic unreachable assert argc argv get_arg getenv setenv system
                 sleep time_now time_elapsed clock_now call_fn unwrap],
}

def categorize(name)
  CATEGORIES.each do |cat, matcher|
    case matcher
    when Array then return cat if matcher.include?(name)
    when Regexp then return cat if name.match?(matcher)
    end
  end
  'misc'
end

def parse_handlers(lines)
  handlers = []
  preamble_end = nil
  lines.each_with_index do |line, idx|
    next if idx < 16
    if line.strip.start_with?('if name == "')
      preamble_end = idx
      break
    end
  end
  return handlers unless preamble_end

  i = preamble_end
  while i < lines.length
    line = lines[i]
    if line.strip =~ /^if name == "([^"]+)"/
      names = line.scan(/"([^"]+)"/).flatten
      start_line = i
      depth = 1
      j = i + 1
      while j < lines.length && depth > 0
        stripped = lines[j].strip
        depth += 1 if stripped =~ /^(if |while |for |match )/
        depth -= 1 if stripped == 'end'
        j += 1
      end
      end_line = j - 1
      handlers << {
        names: names, primary_name: names.first, category: categorize(names.first),
        start_line: start_line, end_line: end_line,
        body: lines[(start_line + 1)..(end_line - 1)].map(&:rstrip)
      }
      i = end_line + 1
    else
      i += 1
    end
  end
  handlers
end

def analyze(handlers)
  by_category = handlers.group_by { |h| h[:category] }
  puts "=== Intrinsic Dispatch Analysis ==="
  puts
  puts "%-15s %5s %7s" % ['Category', 'Count', 'Lines']
  puts '-' * 30
  total_h = 0; total_l = 0
  by_category.sort_by { |c, _| c }.each do |cat, hs|
    lc = hs.sum { |h| h[:end_line] - h[:start_line] + 1 }
    puts "%-15s %5d %7d" % [cat, hs.length, lc]
    total_h += hs.length; total_l += lc
  end
  puts '-' * 30
  puts "%-15s %5d %7d" % ['TOTAL', total_h, total_l]
  puts
  by_category.sort_by { |c, _| c }.each do |cat, hs|
    puts "#{cat} (#{hs.length}): #{hs.map { |h| h[:primary_name] }.sort.join(', ')}\n\n"
  end
end

def generate(handlers, lines)
  by_category = handlers.group_by { |h| h[:category] }
  last_end = handlers.last[:end_line]
  raw_ft = lines[(last_end + 1)...(lines.length)]
  raw_ft.pop while raw_ft.last&.strip == '' || raw_ft.last&.strip == 'end'
  categories = by_category.keys.sort

  out = []
  out << '##! # Codegen Intrinsics'
  out << '##!'
  out << '##! Emits LLVM IR for all Quartz built-in intrinsic functions.'
  out << '##! Uses two-level dispatch: Map name→category, then per-category handler.'
  out << '##!'
  out << '##! @see codegen_util Shared codegen utilities'
  out << '##! @see codegen Main code generation module'
  out << '##! @since 5.14.0 (refactored from 386-branch sequential dispatch)'
  out << ''
  out << 'import mir'
  out << 'import codegen_util'
  out << 'import elem_width'
  out << ''
  out << '# ============================================================================'
  out << '# Intrinsic Category Constants'
  out << '# ============================================================================'
  out << ''
  categories.each_with_index { |cat, idx| out << "const INTRINSIC_CAT_#{cat.upcase} = #{idx + 1}" }
  out << ''
  out << '# Intrinsic dispatch registry: name → category ID'
  out << 'var g_intrinsic_registry = map_new()'
  out << 'var g_intrinsic_registry_initialized = 0'
  out << ''
  out << '## Initialize the intrinsic dispatch registry.'
  out << '## Maps each intrinsic name to its category for O(1) lookup.'
  out << 'def cg_init_intrinsic_registry(): Void'
  out << '  if g_intrinsic_registry_initialized == 1'
  out << '    return'
  out << '  end'
  out << '  g_intrinsic_registry_initialized = 1'
  out << ''
  categories.each do |cat|
    hs = by_category[cat]
    out << "  # #{cat} (#{hs.length} intrinsics)"
    hs.flat_map { |h| h[:names] }.uniq.sort.each do |name|
      out << "  map_set(g_intrinsic_registry, \"#{name}\", INTRINSIC_CAT_#{cat.upcase})"
    end
    out << ''
  end
  out << 'end'
  out << ''
  out << '## Emit an intrinsic function call.'
  out << '## Uses Map-based two-level dispatch for O(1) name resolution.'
  out << 'def cg_emit_intrinsic(state: CodegenState, out: Int, prog: Int, instr: Int): Void'
  out << '  cg_init_intrinsic_registry()'
  out << '  var dest = mir$mir_instr_get_dest_id(instr)'
  out << '  var name = mir$mir_instr_get_func_name(instr)'
  out << '  var args = mir$mir_instr_get_args(instr)'
  out << '  var argc = args.size'
  out << '  var d = dest.to_s()'
  out << '  var _elem_slot = mir$mir_instr_get_slot2(instr)'
  out << '  var _elem_type = ""'
  out << '  if _elem_slot != 0'
  out << '    _elem_type = as_string(_elem_slot)'
  out << '  end'
  out << ''
  out << '  # O(1) category lookup'
  out << '  var category = 0'
  out << '  if map_has(g_intrinsic_registry, name) == 1'
  out << '    category = map_get(g_intrinsic_registry, name)'
  out << '  end'
  out << ''
  categories.each do |cat|
    out << "  if category == INTRINSIC_CAT_#{cat.upcase}"
    out << "    cg_emit_intrinsic_#{cat}(state, out, prog, instr, dest, name, args, argc, d, _elem_type)"
    out << '    return'
    out << '  end'
    out << ''
  end
  raw_ft.each { |l| out << l.rstrip }
  out << 'end'
  out << ''

  categories.each do |cat|
    hs = by_category[cat]
    out << '# ============================================================================'
    out << "# #{cat.capitalize} Intrinsics (#{hs.length} handlers)"
    out << '# ============================================================================'
    out << ''
    out << "def cg_emit_intrinsic_#{cat}(state: CodegenState, out: Int, prog: Int, instr: Int, dest: Int, name: String, args: Vec<Int>, argc: Int, d: String, _elem_type: String): Void"
    hs.each do |handler|
      if handler[:names].length > 1
        out << "  if #{handler[:names].map { |n| "name == \"#{n}\"" }.join(' or ')}"
      else
        out << "  if name == \"#{handler[:primary_name]}\""
      end
      handler[:body].each { |l| out << l }
      out << '  end'
      out << ''
    end
    out << 'end'
    out << ''
  end
  out.join("\n") + "\n"
end

lines = File.readlines(SOURCE, encoding: 'utf-8').map(&:chomp)
handlers = parse_handlers(lines)

if ARGV.include?('--analyze')
  analyze(handlers)
elsif ARGV.include?('--generate')
  result = generate(handlers, lines)
  File.write(OUTPUT, result)
  puts "Generated: #{OUTPUT}"
  puts "#{handlers.length} handlers in #{handlers.group_by { |h| h[:category] }.length} categories"
  puts "#{result.lines.count} lines"
else
  puts "Usage: ruby tools/refactor_intrinsics.rb --analyze|--generate"
end
