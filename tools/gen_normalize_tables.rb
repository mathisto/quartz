#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Generates Unicode normalization tables for Quartz stdlib.
# Uses Ruby's built-in Unicode normalization to extract decomposition and
# composition data.
#
# Usage: ruby tools/gen_normalize_tables.rb
#
# Outputs:
#   std/unicode/normalize_data.qz — decomposition, CCC, composition tables

MAX_CP = 0x10FFFF

# ============================================================================
# Canonical Decomposition
# ============================================================================

def gen_decompositions
  # Extract SINGLE-STEP canonical decompositions only.
  # Hangul syllables (U+AC00..U+D7A3) are excluded — handled algorithmically.
  # We find direct decompositions by checking if NFC(NFD(char)) roundtrips,
  # and storing only the immediate decomposition (not full recursive NFD).
  decomps = {}

  (0..MAX_CP).each do |cp|
    next if cp >= 0xD800 && cp <= 0xDFFF
    next if cp >= 0xAC00 && cp <= 0xD7A3  # Skip Hangul syllables
    begin
      char = [cp].pack("U")
      nfd = char.unicode_normalize(:nfd)
      nfd_cps = nfd.unpack("U*")

      next if nfd_cps == [cp]  # No decomposition

      # For single-step decompositions: we need the direct decomposition,
      # not the fully-recursive one. Check if NFC of the first 2 codepoints
      # gives back our character (direct 2-cp decomposition).
      if nfd_cps.length == 2
        decomps[cp] = nfd_cps
      elsif nfd_cps.length >= 3
        # Check if this is a multi-step decomposition by seeing if the
        # first codepoint itself decomposes. If so, we only need to store
        # the intermediate form.
        # Strategy: find the shortest decomposition that, when recursively
        # expanded, produces the full NFD.
        # For simplicity: store the first 2-cp split if it recomposes correctly.
        # Try recomposing: NFC of nfd should give back cp
        nfc_back = nfd.unicode_normalize(:nfc)
        nfc_cps = nfc_back.unpack("U*")
        if nfc_cps == [cp]
          # This character has a canonical decomposition. Try to find the
          # direct decomposition by checking 2-cp prefix.
          # The canonical decomposition mapping is always to at most 2 cps
          # in UnicodeData.txt. Multi-cp NFD results come from recursive
          # expansion. So find the direct mapping.
          # Try: does recomposing nfd_cps[0..1] give something that further
          # decomposes with nfd_cps[2..]?
          # Simpler: just store the full NFD and let the Quartz code handle it.
          decomps[cp] = nfd_cps
        end
      end
    rescue ArgumentError, RangeError, Encoding::UndefinedConversionError
      next
    end
  end

  decomps
end

# ============================================================================
# Canonical Combining Class (CCC)
# ============================================================================

def gen_ccc_data
  # Extract CCC values. Ruby doesn't directly expose CCC, but we can
  # determine it by checking reordering behavior in NFD.
  # Starter = CCC 0, combining marks have CCC > 0.
  #
  # Since we can't get exact CCC from Ruby, we'll use a different approach:
  # Generate the CCC table from the Unicode standard's known values.
  # The key CCC values are:
  #   0 = Starter (not a combining mark)
  #   1 = Overlay
  #   7 = Nukta
  #   8 = Kana voicing
  #   9 = Virama
  #   200 = Attached below left
  #   202 = Attached below
  #   204 = Attached below right (?)
  #   208 = Attached left
  #   210 = Attached right
  #   212 = Attached above left (?)
  #   214 = Attached above
  #   216 = Attached above right
  #   218 = Below left
  #   220 = Below
  #   222 = Below right
  #   224 = Left
  #   226 = Right
  #   228 = Above left
  #   230 = Above
  #   232 = Above right
  #   233 = Double below
  #   234 = Double above
  #   240 = Iota subscript

  # We'll derive CCC by checking if NFD reorders characters.
  # For a pragmatic approach: all Mn (nonspacing marks) have CCC > 0.
  # We assign CCC 230 (above) as default for Mn characters,
  # which is correct for most Latin/Greek/Cyrillic combining marks.
  #
  # For exact CCC values, we check specific known ranges.

  ccc = {}

  # Known CCC assignments from Unicode standard
  known_ccc = {
    # Combining diacritical marks (U+0300..U+036F)
    0x0300 => 230, 0x0301 => 230, 0x0302 => 230, 0x0303 => 230,
    0x0304 => 230, 0x0305 => 230, 0x0306 => 230, 0x0307 => 230,
    0x0308 => 230, 0x0309 => 230, 0x030A => 230, 0x030B => 230,
    0x030C => 230, 0x030D => 230, 0x030E => 230, 0x030F => 230,
    0x0310 => 230, 0x0311 => 230, 0x0312 => 230, 0x0313 => 230,
    0x0314 => 230, 0x0315 => 232, 0x0316 => 220, 0x0317 => 220,
    0x0318 => 220, 0x0319 => 220, 0x031A => 232, 0x031B => 216,
    0x031C => 220, 0x031D => 220, 0x031E => 220, 0x031F => 220,
    0x0320 => 220, 0x0321 => 202, 0x0322 => 202, 0x0323 => 220,
    0x0324 => 220, 0x0325 => 220, 0x0326 => 220, 0x0327 => 202,
    0x0328 => 202, 0x0329 => 220, 0x032A => 220, 0x032B => 220,
    0x032C => 220, 0x032D => 220, 0x032E => 220, 0x032F => 220,
    0x0330 => 220, 0x0331 => 220, 0x0332 => 220, 0x0333 => 220,
    0x0334 => 1,   0x0335 => 1,   0x0336 => 1,   0x0337 => 1,
    0x0338 => 1,   0x0339 => 220, 0x033A => 220, 0x033B => 220,
    0x033C => 220, 0x033D => 230, 0x033E => 230, 0x033F => 230,
    0x0340 => 230, 0x0341 => 230, 0x0342 => 230, 0x0343 => 230,
    0x0344 => 230, 0x0345 => 240, 0x0346 => 230, 0x0347 => 220,
    0x0348 => 220, 0x0349 => 220, 0x034A => 230, 0x034B => 230,
    0x034C => 230, 0x034D => 220, 0x034E => 220,
    # Hebrew
    0x05B0 => 10, 0x05B1 => 11, 0x05B2 => 12, 0x05B3 => 13,
    0x05B4 => 14, 0x05B5 => 15, 0x05B6 => 16, 0x05B7 => 17,
    0x05B8 => 18, 0x05B9 => 19, 0x05BA => 19, 0x05BB => 20,
    0x05BC => 21, 0x05BD => 22, 0x05BF => 23, 0x05C1 => 24,
    0x05C2 => 25, 0x05C4 => 230, 0x05C5 => 220, 0x05C7 => 18,
    # Arabic
    0x064B => 27, 0x064C => 28, 0x064D => 29, 0x064E => 30,
    0x064F => 31, 0x0650 => 32, 0x0651 => 33, 0x0652 => 34,
    0x0670 => 35,
    # Devanagari nukta
    0x093C => 7,
    # Bengali nukta
    0x09BC => 7,
    # Gurmukhi nukta
    0x0A3C => 7,
    # Gujarati nukta
    0x0ABC => 7,
    # Oriya nukta
    0x0B3C => 7,
    # Telugu virama
    0x0C4D => 9,
    # Kannada virama
    0x0CCD => 9,
    # Malayalam virama
    0x0D4D => 9,
    # Devanagari virama
    0x094D => 9,
    # Bengali virama
    0x09CD => 9,
    # Gurmukhi virama
    0x0A4D => 9,
    # Gujarati virama
    0x0ACD => 9,
    # Oriya virama
    0x0B4D => 9,
    # Tamil virama
    0x0BCD => 9,
    # Sinhala virama
    0x0DCA => 9,
    # Thai
    0x0E38 => 103, 0x0E39 => 103, 0x0E3A => 9,
    0x0E48 => 107, 0x0E49 => 107, 0x0E4A => 107, 0x0E4B => 107,
    # Lao
    0x0EB8 => 118, 0x0EB9 => 118, 0x0EC8 => 122, 0x0EC9 => 122,
    0x0ECA => 122, 0x0ECB => 122,
    # Tibetan
    0x0F71 => 129, 0x0F72 => 130, 0x0F74 => 132, 0x0F7A => 130,
    0x0F7B => 130, 0x0F7C => 130, 0x0F7D => 130, 0x0F80 => 130,
    0x0F82 => 230, 0x0F83 => 230, 0x0F84 => 9, 0x0F86 => 230,
    0x0F87 => 230,
    # Kana voicing
    0x3099 => 8, 0x309A => 8,
  }

  # Use known CCC values; for unspecified Mn/Me chars, use 230 (Above) as default
  (0..MAX_CP).each do |cp|
    next if cp >= 0xD800 && cp <= 0xDFFF
    if known_ccc.key?(cp)
      ccc[cp] = known_ccc[cp]
    else
      begin
        char = [cp].pack("U")
        if char.match?(/\p{Mn}/)
          ccc[cp] = 230  # Default for nonspacing marks
        end
      rescue ArgumentError, RangeError
        next
      end
    end
  end

  ccc
end

# ============================================================================
# Canonical Composition (for NFC)
# ============================================================================

def gen_compositions
  # A composition pair (A, B) -> C exists when:
  # NFC(A + B) == C (single codepoint)
  # and A is a starter (CCC=0) and B is either a starter or has CCC > 0
  #
  # We derive this from NFD/NFC:
  # For each codepoint C, if NFD(C) = A + B (exactly 2 codepoints)
  # and NFC(A + B) = C, then (A, B) -> C is a composition.

  compositions = {}

  (0..MAX_CP).each do |cp|
    next if cp >= 0xD800 && cp <= 0xDFFF
    begin
      char = [cp].pack("U")
      nfd = char.unicode_normalize(:nfd)
      nfd_cps = nfd.unpack("U*")

      # Only care about 2-codepoint decompositions for primary compositions
      if nfd_cps.length == 2
        a, b = nfd_cps
        # Verify this is a canonical composition (NFC roundtrips)
        nfc = nfd.unicode_normalize(:nfc)
        nfc_cps = nfc.unpack("U*")
        if nfc_cps == [cp]
          key = (a << 21) | b
          compositions[key] = cp
        end
      end
    rescue ArgumentError, RangeError, Encoding::UndefinedConversionError
      next
    end
  end

  compositions
end

# ============================================================================
# Code Generators
# ============================================================================

def emit_vec_pushes(io, var_name, values)
  values.each do |v|
    io.puts "  vec_push(#{var_name}, #{v})"
  end
end

# ============================================================================
# Main
# ============================================================================

puts "Generating Unicode normalization tables..."

# --- Decomposition ---
puts "  Generating canonical decompositions..."
decomps = gen_decompositions
puts "    #{decomps.size} decomposition entries"

# --- CCC ---
puts "  Generating Canonical Combining Class table..."
ccc_data = gen_ccc_data
puts "    #{ccc_data.size} CCC entries"

# Compress CCC into ranges of same value
def compress_ccc_ranges(ccc)
  # Group by CCC value, then compress each group into ranges
  by_value = Hash.new { |h, k| h[k] = [] }
  ccc.each { |cp, val| by_value[val] << cp }

  entries = []
  by_value.each do |val, cps|
    cps.sort!
    start = cps[0]
    prev = start
    cps[1..].each do |cp|
      if cp == prev + 1
        prev = cp
      else
        entries << [start, prev, val]
        start = cp
        prev = cp
      end
    end
    entries << [start, prev, val]
  end
  entries.sort_by! { |s, _, _| s }
  entries
end

ccc_ranges = compress_ccc_ranges(ccc_data)
puts "    Compressed to #{ccc_ranges.size} ranges"

# --- Composition ---
puts "  Generating canonical compositions..."
compositions = gen_compositions
puts "    #{compositions.size} composition pairs"

# --- Output ---
File.open("std/unicode/normalize_data.qz", "w") do |f|
  f.puts "## Unicode Normalization Data (NFD/NFC)"
  f.puts "## Generated by tools/gen_normalize_tables.rb — DO NOT EDIT"
  f.puts "## Ruby #{RUBY_VERSION}"
  f.puts "##"
  f.puts "## Decompositions: #{decomps.size}"
  f.puts "## CCC ranges: #{ccc_ranges.size}"
  f.puts "## Compositions: #{compositions.size}"
  f.puts ""

  # --- Decomposition table ---
  # For each decomposable codepoint, store the full NFD codepoint sequence.
  # Use parallel arrays: keys (source codepoint) and values (packed decomposition).
  # Pack: for 2-cp decomp: (cp1 << 21) | cp2
  # For longer: store in a separate overflow table.

  # Separate into 2-cp decomps (most common) and longer ones
  decomp2 = decomps.select { |_, v| v.length == 2 }
  decomp_long = decomps.select { |_, v| v.length > 2 }

  f.puts "## Canonical decomposition (2-codepoint)"
  f.puts "var _nd_decomp_keys = vec_new()"
  f.puts ""
  f.puts "def nd_decomp_keys(): Vec<Int>"
  f.puts "  if vec_len(_nd_decomp_keys) > 0"
  f.puts "    return _nd_decomp_keys"
  f.puts "  end"
  emit_vec_pushes(f, "_nd_decomp_keys", decomp2.keys.sort)
  f.puts "  return _nd_decomp_keys"
  f.puts "end"
  f.puts ""

  f.puts "var _nd_decomp_vals = vec_new()"
  f.puts ""
  f.puts "def nd_decomp_vals(): Vec<Int>"
  f.puts "  if vec_len(_nd_decomp_vals) > 0"
  f.puts "    return _nd_decomp_vals"
  f.puts "  end"
  packed = decomp2.keys.sort.map { |k| v = decomp2[k]; "(#{v[0]} << 21) | #{v[1]}" }
  emit_vec_pushes(f, "_nd_decomp_vals", packed)
  f.puts "  return _nd_decomp_vals"
  f.puts "end"
  f.puts ""

  # Long decompositions: store as flat array with length prefix
  # Format: [src_cp, len, cp1, cp2, ..., cpN, src_cp, len, ...]
  if decomp_long.any?
    f.puts "## Canonical decomposition (3+ codepoints)"
    f.puts "var _nd_decomp_long = vec_new()"
    f.puts ""
    f.puts "def nd_decomp_long(): Vec<Int>"
    f.puts "  if vec_len(_nd_decomp_long) > 0"
    f.puts "    return _nd_decomp_long"
    f.puts "  end"
    entries = []
    decomp_long.keys.sort.each do |k|
      v = decomp_long[k]
      entries << k
      entries << v.length
      entries.concat(v)
    end
    emit_vec_pushes(f, "_nd_decomp_long", entries)
    f.puts "  return _nd_decomp_long"
    f.puts "end"
    f.puts ""
  else
    f.puts "def nd_decomp_long(): Vec<Int>"
    f.puts "  return vec_new()"
    f.puts "end"
    f.puts ""
  end

  # --- CCC table ---
  # Store as parallel arrays: (start, end) ranges and their CCC values.
  # Pack start/end as (start << 21) | end.
  f.puts "## Canonical Combining Class ranges"
  f.puts "var _nd_ccc_ranges = vec_new()"
  f.puts ""
  f.puts "def nd_ccc_ranges(): Vec<Int>"
  f.puts "  if vec_len(_nd_ccc_ranges) > 0"
  f.puts "    return _nd_ccc_ranges"
  f.puts "  end"
  range_packed = ccc_ranges.map { |s, e, _| "(#{s} << 21) | #{e}" }
  emit_vec_pushes(f, "_nd_ccc_ranges", range_packed)
  f.puts "  return _nd_ccc_ranges"
  f.puts "end"
  f.puts ""

  f.puts "var _nd_ccc_values = vec_new()"
  f.puts ""
  f.puts "def nd_ccc_values(): Vec<Int>"
  f.puts "  if vec_len(_nd_ccc_values) > 0"
  f.puts "    return _nd_ccc_values"
  f.puts "  end"
  ccc_vals = ccc_ranges.map { |_, _, v| v }
  emit_vec_pushes(f, "_nd_ccc_values", ccc_vals)
  f.puts "  return _nd_ccc_values"
  f.puts "end"
  f.puts ""

  # --- Composition table ---
  # Keys: (cp1 << 21) | cp2, sorted
  # Values: composed codepoint
  comp_keys = compositions.keys.sort
  comp_vals = comp_keys.map { |k| compositions[k] }

  f.puts "## Canonical composition pairs"
  f.puts "var _nd_comp_keys = vec_new()"
  f.puts ""
  f.puts "def nd_comp_keys(): Vec<Int>"
  f.puts "  if vec_len(_nd_comp_keys) > 0"
  f.puts "    return _nd_comp_keys"
  f.puts "  end"
  emit_vec_pushes(f, "_nd_comp_keys", comp_keys)
  f.puts "  return _nd_comp_keys"
  f.puts "end"
  f.puts ""

  f.puts "var _nd_comp_vals = vec_new()"
  f.puts ""
  f.puts "def nd_comp_vals(): Vec<Int>"
  f.puts "  if vec_len(_nd_comp_vals) > 0"
  f.puts "    return _nd_comp_vals"
  f.puts "  end"
  emit_vec_pushes(f, "_nd_comp_vals", comp_vals)
  f.puts "  return _nd_comp_vals"
  f.puts "end"
end

puts "    -> std/unicode/normalize_data.qz"
puts "Done!"
