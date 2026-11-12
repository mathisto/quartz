#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Generates Quartz Unicode data tables from Ruby's built-in Unicode support
# plus a small handful of UCD .txt files fetched from unicode.org.
#
# Usage: ruby tools/gen_unicode_tables.rb
#
# Outputs:
#   std/unicode/case_data.qz     — uppercase/lowercase/case-fold mapping tables
#   std/unicode/category_data.qz — alphabetic/numeric/whitespace/etc. range tables
#   std/unicode/grapheme_data.qz — UAX #29 Grapheme Break Property tables
#   std/unicode/width_data.qz    — East Asian Width + Emoji_Presentation +
#                                  zero-width (combining marks etc.) tables
#
# Width data sources (Unicode 15.0.0; downloaded on demand, cached in
# tools/data/, not committed):
#   https://www.unicode.org/Public/15.0.0/ucd/EastAsianWidth.txt
#   https://www.unicode.org/Public/15.0.0/ucd/emoji/emoji-data.txt

require "net/http"
require "uri"

MAX_CP = 0x10FFFF
UCD_VERSION = "15.0.0"
UCD_BASE = "https://www.unicode.org/Public/#{UCD_VERSION}/ucd"
DATA_DIR = File.expand_path("data", __dir__)

# ============================================================================
# Case Mapping Tables
# ============================================================================

def gen_case_mappings
  upper_keys = []
  upper_vals = []
  lower_keys = []
  lower_vals = []
  fold_keys = []
  fold_vals = []

  # Full uppercase/lowercase mappings (1:1 simple mapping only)
  (0..MAX_CP).each do |cp|
    next if cp >= 0xD800 && cp <= 0xDFFF  # surrogates
    begin
      char = [cp].pack("U")

      up = char.upcase
      if up != char && up.length == 1
        up_cp = up.unpack1("U")
        upper_keys << cp
        upper_vals << up_cp
      end

      lo = char.downcase
      if lo != char && lo.length == 1
        lo_cp = lo.unpack1("U")
        lower_keys << cp
        lower_vals << lo_cp
      end

      # Case folding (Ruby's String#downcase with :fold option uses casefold)
      folded = char.downcase(:fold)
      if folded != char && folded.length == 1
        fold_cp = folded.unpack1("U")
        fold_keys << cp
        fold_vals << fold_cp
      end
    rescue ArgumentError, RangeError
      next
    end
  end

  # Also collect special 1-to-many uppercase mappings (e.g., ß → SS)
  special_upper = {}
  (0..MAX_CP).each do |cp|
    next if cp >= 0xD800 && cp <= 0xDFFF
    begin
      char = [cp].pack("U")
      up = char.upcase
      if up != char && up.length > 1
        cps = up.unpack("U*")
        special_upper[cp] = cps
      end
    rescue ArgumentError, RangeError
      next
    end
  end

  [upper_keys, upper_vals, lower_keys, lower_vals, fold_keys, fold_vals, special_upper]
end

# ============================================================================
# Category Range Tables
# ============================================================================

def codepoints_matching(regex)
  cps = []
  (0..MAX_CP).each do |cp|
    next if cp >= 0xD800 && cp <= 0xDFFF
    begin
      char = [cp].pack("U")
      cps << cp if char.match?(regex)
    rescue ArgumentError, RangeError
      next
    end
  end
  cps
end

def compress_to_ranges(sorted_cps)
  return [] if sorted_cps.empty?
  ranges = []
  start = sorted_cps[0]
  prev = start
  sorted_cps[1..].each do |cp|
    if cp == prev + 1
      prev = cp
    else
      ranges << [start, prev]
      start = cp
      prev = cp
    end
  end
  ranges << [start, prev]
  ranges
end

def gen_category_ranges
  categories = {}

  # Alphabetic: Unicode property \p{Alpha}
  categories[:alphabetic] = compress_to_ranges(codepoints_matching(/\p{Alpha}/))

  # Numeric digit: \p{Nd} (decimal digits)
  categories[:numeric] = compress_to_ranges(codepoints_matching(/\p{Nd}/))

  # Whitespace: \p{Space}
  categories[:whitespace] = compress_to_ranges(codepoints_matching(/\p{Space}/))

  # Uppercase: \p{Lu}
  categories[:uppercase] = compress_to_ranges(codepoints_matching(/\p{Lu}/))

  # Lowercase: \p{Ll}
  categories[:lowercase] = compress_to_ranges(codepoints_matching(/\p{Ll}/))

  categories
end

# ============================================================================
# Grapheme Break Property Tables (UAX #29)
# ============================================================================

def gen_grapheme_break_data
  # Ruby doesn't expose grapheme break properties directly,
  # but we can derive them from Unicode regex properties.
  # For complete UAX #29, we need to read GraphemeBreakProperty.txt.
  # For now, we encode the categories using known Unicode property ranges.

  gb = {}

  # CR (U+000D)
  gb[:cr] = [[0x000D, 0x000D]]

  # LF (U+000A)
  gb[:lf] = [[0x000A, 0x000A]]

  # Control (Cc + Cf + Zl + Zp minus CR/LF/ZWJ)
  control_cps = codepoints_matching(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/)
  control_cps -= [0x000A, 0x000D, 0x200D] # remove LF, CR, ZWJ
  # Also remove U+200C (ZWNJ) and some Prepend chars that are Cf
  gb[:control] = compress_to_ranges(control_cps.sort)

  # Extend (\p{Grapheme_Extend} approximation — Mn + Me + some Mc)
  extend_cps = codepoints_matching(/[\p{Mn}\p{Me}]/)
  # Add specific extend characters
  [0x09BE, 0x09D7, 0x0B3E, 0x0B57, 0x0BBE, 0x0BD7, 0x0CC2,
   0x0CD5, 0x0CD6, 0x0D3E, 0x0D57, 0x0DCF, 0x0DDF, 0x200C,
   0x200D, 0xFF9E, 0xFF9F].each { |cp| extend_cps << cp unless extend_cps.include?(cp) }
  gb[:extend] = compress_to_ranges(extend_cps.sort.uniq)

  # ZWJ (U+200D) — for emoji ZWJ sequences
  gb[:zwj] = [[0x200D, 0x200D]]

  # Regional Indicator (U+1F1E6..U+1F1FF)
  gb[:regional_indicator] = [[0x1F1E6, 0x1F1FF]]

  # SpacingMark (approximation — Mc minus Extend)
  spacing_cps = codepoints_matching(/\p{Mc}/) - extend_cps
  gb[:spacing_mark] = compress_to_ranges(spacing_cps.sort)

  # Prepend (a small set of Cf characters used as viramas etc.)
  # These are characters with Prepended_Concatenation_Mark property
  prepend_cps = [
    0x0600, 0x0601, 0x0602, 0x0603, 0x0604, 0x0605,
    0x06DD, 0x070F, 0x0890, 0x0891, 0x08E2,
    0x0D4E, 0x110BD, 0x110CD,
    0x111C2, 0x111C3, 0x1193F, 0x11941, 0x11A3A,
    0x11A84, 0x11A85, 0x11A86, 0x11A87, 0x11A88, 0x11A89,
    0x11D46, 0x11F02
  ]
  gb[:prepend] = compress_to_ranges(prepend_cps.sort)

  # Hangul syllable types
  gb[:hangul_l] = [[0x1100, 0x115F], [0xA960, 0xA97C]]
  gb[:hangul_v] = [[0x1160, 0x11A7], [0xD7B0, 0xD7C6]]
  gb[:hangul_t] = [[0x11A8, 0x11FF], [0xD7CB, 0xD7FB]]
  gb[:hangul_lv] = [] # Generated algorithmically for Hangul syllables
  gb[:hangul_lvt] = []
  # LV syllables: every 28th syllable starting at 0xAC00
  (0xAC00..0xD7A3).each do |cp|
    if (cp - 0xAC00) % 28 == 0
      gb[:hangul_lv] << cp
    else
      gb[:hangul_lvt] << cp
    end
  end
  gb[:hangul_lv] = compress_to_ranges(gb[:hangul_lv])
  gb[:hangul_lvt] = compress_to_ranges(gb[:hangul_lvt])

  # Extended_Pictographic (emoji that can participate in ZWJ sequences)
  # This is a simplified version — full list from emoji-data.txt
  ep_ranges = [
    [0x00A9, 0x00A9], [0x00AE, 0x00AE], [0x203C, 0x203C],
    [0x2049, 0x2049], [0x2122, 0x2122], [0x2139, 0x2139],
    [0x2194, 0x2199], [0x21A9, 0x21AA], [0x231A, 0x231B],
    [0x2328, 0x2328], [0x23CF, 0x23CF], [0x23E9, 0x23F3],
    [0x23F8, 0x23FA], [0x24C2, 0x24C2], [0x25AA, 0x25AB],
    [0x25B6, 0x25B6], [0x25C0, 0x25C0], [0x25FB, 0x25FE],
    [0x2600, 0x2605], [0x2607, 0x2612], [0x2614, 0x2685],
    [0x2690, 0x2705], [0x2708, 0x2712], [0x2714, 0x2714],
    [0x2716, 0x2716], [0x271D, 0x271D], [0x2721, 0x2721],
    [0x2728, 0x2728], [0x2733, 0x2734], [0x2744, 0x2744],
    [0x2747, 0x2747], [0x274C, 0x274C], [0x274E, 0x274E],
    [0x2753, 0x2755], [0x2757, 0x2757], [0x2763, 0x2767],
    [0x2795, 0x2797], [0x27A1, 0x27A1], [0x27B0, 0x27B0],
    [0x27BF, 0x27BF], [0x2934, 0x2935], [0x2B05, 0x2B07],
    [0x2B1B, 0x2B1C], [0x2B50, 0x2B50], [0x2B55, 0x2B55],
    [0x3030, 0x3030], [0x303D, 0x303D], [0x3297, 0x3297],
    [0x3299, 0x3299],
    [0x1F000, 0x1F0FF], [0x1F10D, 0x1F10F], [0x1F12F, 0x1F12F],
    [0x1F16C, 0x1F171], [0x1F17E, 0x1F17F], [0x1F18E, 0x1F18E],
    [0x1F191, 0x1F19A], [0x1F1AD, 0x1F1E5],
    [0x1F201, 0x1F20F], [0x1F21A, 0x1F21A], [0x1F22F, 0x1F22F],
    [0x1F232, 0x1F23A], [0x1F23C, 0x1F23F], [0x1F249, 0x1F3FA],
    [0x1F400, 0x1F53D], [0x1F546, 0x1F64F], [0x1F680, 0x1F6FF],
    [0x1F774, 0x1F77F], [0x1F7D5, 0x1F7FF],
    [0x1F80C, 0x1F80F], [0x1F848, 0x1F84F], [0x1F85A, 0x1F85F],
    [0x1F888, 0x1F88F], [0x1F8AE, 0x1F8FF],
    [0x1F90C, 0x1F93A], [0x1F93C, 0x1F945], [0x1F947, 0x1FAFF],
    [0x1FC00, 0x1FFFD],
  ]
  gb[:extended_pictographic] = ep_ranges

  gb
end

# ============================================================================
# East Asian Width + Emoji_Presentation + zero-width tables
# ============================================================================
#
# Three range sets:
#   wide       = EAW=Wide ∪ EAW=Fullwidth ∪ Emoji_Presentation
#   ambiguous  = EAW=Ambiguous       (defaults to width 1; locale opt-in to 2)
#   zero       = Mn ∪ Me ∪ explicit zero-width controls + Hangul Jamo
#                medial vowels and final consonants (which combine
#                visually onto the preceding initial consonant).
#
# wcwidth-style result: 0 / 2 / (1 default | per-locale ambiguous).

def fetch_ucd(name, dest)
  return File.read(dest) if File.exist?(dest)
  FileUtils.mkdir_p(File.dirname(dest))
  uri = URI("#{UCD_BASE}/#{name}")
  puts "    Fetching #{uri}..."
  Net::HTTP.get_response(uri).tap do |res|
    raise "HTTP #{res.code} fetching #{uri}" unless res.is_a?(Net::HTTPSuccess)
    File.write(dest, res.body)
  end.body
end

def parse_ucd_ranges(text, want_value)
  # Generic UCD range-line parser. Lines look like:
  #   `0020;Na # Zs SPACE`        (single codepoint)
  #   `2E80..303E;W # ...`        (inclusive range)
  cps = []
  text.each_line do |line|
    line = line.split("#", 2).first.to_s.strip
    next if line.empty?
    code_field, value = line.split(";", 2).map(&:strip)
    next unless value == want_value
    if code_field.include?("..")
      lo, hi = code_field.split("..")
      (lo.to_i(16)..hi.to_i(16)).each { |cp| cps << cp }
    else
      cps << code_field.to_i(16)
    end
  end
  cps.sort.uniq
end

def gen_width_data
  require "fileutils"
  eaw_text = fetch_ucd("EastAsianWidth.txt", File.join(DATA_DIR, "EastAsianWidth.txt"))
  emoji_text = fetch_ucd("emoji/emoji-data.txt", File.join(DATA_DIR, "emoji-data.txt"))

  wide_eaw   = parse_ucd_ranges(eaw_text, "W") + parse_ucd_ranges(eaw_text, "F")
  ambig_eaw  = parse_ucd_ranges(eaw_text, "A")
  emoji_pres = parse_ucd_ranges(emoji_text, "Emoji_Presentation")

  # Wide = EAW(W,F) ∪ Emoji_Presentation. Emoji_Presentation pulls in
  # base-plane symbols (⌚ U+231A etc.) that EAW classifies as N but
  # which terminals draw as 2 cells when emoji-rendered.
  wide_set = (wide_eaw + emoji_pres).sort.uniq

  # Ambiguous = EAW=A only. Default-rendered as 1 cell; the runtime
  # exposes uc_set_east_asian_ambiguous_width(2) for CJK locales.
  ambig_set = ambig_eaw

  # Zero-width: Mn (Nonspacing Mark) ∪ Me (Enclosing Mark) ∪ explicit
  # ZW codepoints ∪ Hangul Jamo medial vowels (U+1160..U+11A7) and
  # final consonants (U+11A8..U+11FF). Hangul Jamo medial+final are
  # category Lo per UCD but combine visually onto the preceding
  # initial consonant, so they render as 0 cells in practice — this
  # matches Markus Kuhn's reference wcwidth and Rust's unicode-width.
  zero_set  = codepoints_matching(/[\p{Mn}\p{Me}]/)
  zero_set += [0x200B, 0x200C, 0x200D, 0x2060, 0x2061, 0x2062, 0x2063,
               0x2064, 0xFEFF]
  zero_set += (0x1160..0x11FF).to_a
  zero_set = zero_set.sort.uniq

  {
    wide: compress_to_ranges(wide_set),
    ambiguous: compress_to_ranges(ambig_set),
    zero: compress_to_ranges(zero_set),
  }
end

# ============================================================================
# Code Generators
# ============================================================================

def emit_vec_pushes(io, var_name, values)
  values.each do |v|
    io.puts "  vec_push(#{var_name}, #{v})"
  end
end

def emit_range_table(io, func_name, ranges)
  io.puts "var _#{func_name} = vec_new()"
  io.puts ""
  io.puts "def #{func_name}(): Vec<Int>"
  io.puts "  if vec_size(_#{func_name}) > 0"
  io.puts "    return _#{func_name}"
  io.puts "  end"
  packed = ranges.map { |s, e| "(#{s} << 21) | #{e}" }
  emit_vec_pushes(io, "_#{func_name}", packed)
  io.puts "  return _#{func_name}"
  io.puts "end"
  io.puts ""
end

def emit_mapping_table(io, func_keys, func_vals, keys, values)
  # Keys table
  io.puts "var _#{func_keys} = vec_new()"
  io.puts ""
  io.puts "def #{func_keys}(): Vec<Int>"
  io.puts "  if vec_size(_#{func_keys}) > 0"
  io.puts "    return _#{func_keys}"
  io.puts "  end"
  emit_vec_pushes(io, "_#{func_keys}", keys)
  io.puts "  return _#{func_keys}"
  io.puts "end"
  io.puts ""

  # Values table
  io.puts "var _#{func_vals} = vec_new()"
  io.puts ""
  io.puts "def #{func_vals}(): Vec<Int>"
  io.puts "  if vec_size(_#{func_vals}) > 0"
  io.puts "    return _#{func_vals}"
  io.puts "  end"
  emit_vec_pushes(io, "_#{func_vals}", values)
  io.puts "  return _#{func_vals}"
  io.puts "end"
  io.puts ""
end

# ============================================================================
# Main
# ============================================================================

puts "Generating Unicode tables from Ruby #{RUBY_VERSION} (Unicode #{RbConfig::CONFIG["UNICODE_VERSION"] rescue "?"})"

# --- Case mappings ---
puts "  Generating case mapping tables..."
upper_keys, upper_vals, lower_keys, lower_vals, fold_keys, fold_vals, special_upper = gen_case_mappings
puts "    Uppercase: #{upper_keys.size} mappings"
puts "    Lowercase: #{lower_keys.size} mappings"
puts "    Case fold: #{fold_keys.size} mappings"
puts "    Special uppercase (1-to-many): #{special_upper.size} mappings"

File.open("std/unicode/case_data.qz", "w") do |f|
  f.puts "## Unicode Case Mapping Data"
  f.puts "## Generated by tools/gen_unicode_tables.rb — DO NOT EDIT"
  f.puts "## Ruby #{RUBY_VERSION}, Unicode #{RbConfig::CONFIG["UNICODE_VERSION"] rescue "?"}"
  f.puts "##"
  f.puts "## Uppercase: #{upper_keys.size} mappings"
  f.puts "## Lowercase: #{lower_keys.size} mappings"
  f.puts "## Case fold: #{fold_keys.size} mappings"
  f.puts "## Special uppercase (1-to-many): #{special_upper.size} mappings"
  f.puts ""

  emit_mapping_table(f, "uc_upper_keys", "uc_upper_vals", upper_keys, upper_vals)
  emit_mapping_table(f, "uc_lower_keys", "uc_lower_vals", lower_keys, lower_vals)
  emit_mapping_table(f, "uc_fold_keys", "uc_fold_vals", fold_keys, fold_vals)

  # Special 1-to-many uppercase mappings
  # Stored as parallel arrays: source codepoint → packed target codepoints
  # Pack target as (cp1 << 42) | (cp2 << 21) | cp3, with 0 for unused slots
  f.puts "var _uc_special_upper_keys = vec_new()"
  f.puts ""
  f.puts "def uc_special_upper_keys(): Vec<Int>"
  f.puts "  if vec_size(_uc_special_upper_keys) > 0"
  f.puts "    return _uc_special_upper_keys"
  f.puts "  end"
  emit_vec_pushes(f, "_uc_special_upper_keys", special_upper.keys.sort)
  f.puts "  return _uc_special_upper_keys"
  f.puts "end"
  f.puts ""

  f.puts "var _uc_special_upper_vals = vec_new()"
  f.puts ""
  f.puts "def uc_special_upper_vals(): Vec<Int>"
  f.puts "  if vec_size(_uc_special_upper_vals) > 0"
  f.puts "    return _uc_special_upper_vals"
  f.puts "  end"
  packed_vals = special_upper.keys.sort.map do |src|
    target = special_upper[src]
    cp1 = target[0] || 0
    cp2 = target[1] || 0
    cp3 = target[2] || 0
    "(#{cp1} << 42) | (#{cp2} << 21) | #{cp3}"
  end
  emit_vec_pushes(f, "_uc_special_upper_vals", packed_vals)
  f.puts "  return _uc_special_upper_vals"
  f.puts "end"
  f.puts ""

  # Store the number of codepoints in each expansion
  f.puts "var _uc_special_upper_lens = vec_new()"
  f.puts ""
  f.puts "def uc_special_upper_lens(): Vec<Int>"
  f.puts "  if vec_size(_uc_special_upper_lens) > 0"
  f.puts "    return _uc_special_upper_lens"
  f.puts "  end"
  lens = special_upper.keys.sort.map { |src| special_upper[src].size }
  emit_vec_pushes(f, "_uc_special_upper_lens", lens)
  f.puts "  return _uc_special_upper_lens"
  f.puts "end"
end
puts "    -> std/unicode/case_data.qz"

# --- Category ranges ---
puts "  Generating category range tables..."
categories = gen_category_ranges

File.open("std/unicode/category_data.qz", "w") do |f|
  f.puts "## Unicode Category Range Data"
  f.puts "## Generated by tools/gen_unicode_tables.rb — DO NOT EDIT"
  f.puts "## Ruby #{RUBY_VERSION}, Unicode #{RbConfig::CONFIG["UNICODE_VERSION"] rescue "?"}"
  f.puts ""

  categories.each do |name, ranges|
    puts "    #{name}: #{ranges.size} ranges"
    emit_range_table(f, "uc_#{name}_ranges", ranges)
  end
end
puts "    -> std/unicode/category_data.qz"

# --- Grapheme Break Property ---
puts "  Generating Grapheme Break Property tables..."
gb = gen_grapheme_break_data

File.open("std/unicode/grapheme_data.qz", "w") do |f|
  f.puts "## Unicode Grapheme Break Property Data (UAX #29)"
  f.puts "## Generated by tools/gen_unicode_tables.rb — DO NOT EDIT"
  f.puts "## Ruby #{RUBY_VERSION}, Unicode #{RbConfig::CONFIG["UNICODE_VERSION"] rescue "?"}"
  f.puts ""
  f.puts "## Grapheme break category constants"
  cats = [:cr, :lf, :control, :extend, :zwj, :regional_indicator,
          :spacing_mark, :prepend, :hangul_l, :hangul_v, :hangul_t,
          :hangul_lv, :hangul_lvt, :extended_pictographic]
  cats.each_with_index do |cat, i|
    f.puts "def GB_#{cat.upcase}(): Int = #{i + 1}"
  end
  f.puts "def GB_OTHER(): Int = 0"
  f.puts ""

  cats.each do |cat|
    ranges = gb[cat]
    puts "    #{cat}: #{ranges.size} ranges"
    emit_range_table(f, "uc_gb_#{cat}", ranges)
  end
end
puts "    -> std/unicode/grapheme_data.qz"

# --- East Asian Width / Emoji_Presentation / zero-width ---
puts "  Generating width tables (UCD #{UCD_VERSION})..."
width = gen_width_data
puts "    Wide:      #{width[:wide].size} ranges"
puts "    Ambiguous: #{width[:ambiguous].size} ranges"
puts "    Zero:      #{width[:zero].size} ranges"

File.open("std/unicode/width_data.qz", "w") do |f|
  f.puts "## Unicode Width Property Data"
  f.puts "## Generated by tools/gen_unicode_tables.rb — DO NOT EDIT"
  f.puts "## Sources: UCD #{UCD_VERSION} EastAsianWidth.txt + emoji-data.txt"
  f.puts "##"
  f.puts "## Wide:      #{width[:wide].size} ranges (EAW=W ∪ EAW=F ∪ Emoji_Presentation)"
  f.puts "## Ambiguous: #{width[:ambiguous].size} ranges (EAW=A; default 1, locale opt-in 2)"
  f.puts "## Zero:      #{width[:zero].size} ranges (Mn ∪ Me ∪ ZW + Hangul medial/final)"
  f.puts ""
  emit_range_table(f, "uc_width_wide_ranges", width[:wide])
  emit_range_table(f, "uc_width_ambiguous_ranges", width[:ambiguous])
  emit_range_table(f, "uc_width_zero_ranges", width[:zero])
end
puts "    -> std/unicode/width_data.qz"

puts "Done! #{upper_keys.size + lower_keys.size + fold_keys.size} case mappings, " \
     "#{categories.values.sum(&:size)} category ranges, " \
     "#{gb.values.sum { |v| v.is_a?(Array) ? v.size : 0 }} grapheme break ranges, " \
     "#{width[:wide].size + width[:ambiguous].size + width[:zero].size} width ranges"
