#!/usr/bin/env ruby
# frozen_string_literal: true

# gen_ffi.rb - Generate Quartz FFI bindings from C headers
#
# Usage:
#   ruby tools/gen_ffi.rb <header.h> [options]
#
# Examples:
#   ruby tools/gen_ffi.rb /usr/include/time.h --functions time,localtime --output std/ffi/time.qz
#   ruby tools/gen_ffi.rb /usr/include/unistd.h --functions read,write,close --output std/ffi/unistd.qz
#
# Options:
#   --functions NAME,NAME,...   Only include these functions (comma-separated)
#   --structs NAME,NAME,...     Only include these structs (comma-separated)
#   --output PATH               Output file path (default: stdout)
#   --include-dir PATH          Additional include directory for clang
#   --all                       Include all declarations (use with caution)

require 'json'
require 'optparse'
require 'open3'

# C type to Quartz type mapping
# Built-in FFI types: CInt, CChar, CPtr, CSize, CFloat, CDouble
# Types not in compiler are mapped to Int (all are i64 at runtime)
C_TO_BE_TYPES = {
  # Integer types - map to CInt or Int depending on what's available
  'int' => 'CInt',
  'unsigned int' => 'CInt',           # No CUInt, use CInt (both i64)
  'long' => 'Int',                    # No CLong, use Int (both i64 on 64-bit)
  'unsigned long' => 'Int',           # No CULong, use Int
  'long long' => 'Int',               # No CLongLong, use Int
  'unsigned long long' => 'Int',      # No CULongLong, use Int
  'short' => 'CInt',                  # No CShort, use CInt
  'unsigned short' => 'CInt',         # No CUShort, use CInt
  'char' => 'CChar',
  'unsigned char' => 'CChar',         # Same as CChar at i64
  'signed char' => 'CChar',           # Same as CChar at i64
  'float' => 'CFloat',
  'double' => 'CDouble',
  'size_t' => 'CSize',
  'ssize_t' => 'Int',                 # No CSSize, use Int
  'ptrdiff_t' => 'Int',               # No CPtrDiff, use Int
  'void' => 'Void',

  # Time types (mapped to Int since no dedicated types)
  'time_t' => 'Int',                  # time_t is long on macOS
  'clock_t' => 'Int',                 # clock_t is unsigned long on macOS

  # File types
  'FILE' => 'CPtr', # FILE* always used as pointer

  # Socket types
  'socklen_t' => 'CInt', # socklen_t is typically unsigned int
  'sa_family_t' => 'CInt',
  'in_port_t' => 'CInt',
  'in_addr_t' => 'CInt'
}.freeze

# Patterns for pointer types
POINTER_PATTERNS = [
  /^(.+)\s*\*$/,           # "int *" or "char*"
  /^const\s+(.+)\s*\*$/,   # "const char *"
  /^(.+)\s*const\s*\*$/ # "char const *"
].freeze

class FFIGenerator
  def initialize(header_path, options = {})
    @header_path = header_path
    @functions = options[:functions]
    @structs = options[:structs]
    @output = options[:output]
    @include_dirs = options[:include_dirs] || []
    @include_all = options[:all]
    @generated_types = Set.new
  end

  def generate
    ast = parse_header
    return nil unless ast

    declarations = extract_declarations(ast)

    # Extract macros separately (not in AST)
    declarations[:macros] = extract_macros

    generate_qz_code(declarations)
  end

  private

  def parse_header
    # Build clang command
    cmd = ['clang', '-Xclang', '-ast-dump=json', '-fsyntax-only']
    @include_dirs.each { |dir| cmd += ['-I', dir] }
    cmd << @header_path

    stdout, stderr, status = Open3.capture3(*cmd)

    unless status.success?
      warn "clang failed: #{stderr}"
      return nil
    end

    JSON.parse(stdout)
  rescue JSON::ParserError => e
    warn "Failed to parse clang output: #{e.message}"
    nil
  end

  def extract_declarations(ast)
    result = { functions: [], structs: [], typedefs: [], enums: [], macros: [] }

    return result unless ast['inner']

    ast['inner'].each do |node|
      # Skip implicit/builtin declarations
      next if node['isImplicit']

      # Determine if we should include this declaration:
      # 1. If specific functions/structs are requested, include matching ones regardless of file
      # 2. If --all is specified, include everything from the target header
      # 3. Otherwise, include declarations from the target header file
      file = node.dig('loc', 'file')
      name = node['name']

      # If we have specific filters, check if this declaration matches
      has_function_filter = @functions && !@functions.empty?
      has_struct_filter = @structs && !@structs.empty?

      should_check_file = true
      if node['kind'] == 'FunctionDecl' && has_function_filter && @functions.include?(name)
        should_check_file = false  # Include regardless of file location
      elsif node['kind'] == 'RecordDecl' && has_struct_filter && @structs.include?(name)
        should_check_file = false  # Include regardless of file location
      end

      if should_check_file && !@include_all
        next unless file
        next unless file == @header_path || file.end_with?(File.basename(@header_path)) ||
                    file.include?('_time.h') || file.include?('_types.h') # macOS internal headers
      end

      case node['kind']
      when 'FunctionDecl'
        func = extract_function(node)
        result[:functions] << func if func && should_include_function?(func[:name])
      when 'RecordDecl'
        struct = extract_struct(node)
        result[:structs] << struct if struct && should_include_struct?(struct[:name])
      when 'TypedefDecl'
        typedef = extract_typedef(node)
        result[:typedefs] << typedef if typedef
      when 'EnumDecl'
        enum = extract_enum(node)
        result[:enums] << enum if enum
      end
    end

    result
  end

  def extract_function(node)
    name = node['name']
    return nil unless name

    type_str = node.dig('type', 'qualType')
    return nil unless type_str

    # Parse function type: "ret_type (param_types)"
    # e.g., "int (int, int)" or "void *(size_t)"
    return_type, = parse_function_type(type_str)
    return nil unless return_type

    # Extract parameter names and types from inner nodes
    params = []
    if node['inner']
      node['inner'].each do |inner|
        next unless inner['kind'] == 'ParmVarDecl'

        param_name = inner['name'] || "arg#{params.size}"
        param_type = inner.dig('type', 'qualType')
        params << { name: param_name, type: param_type }
      end
    end

    # Check for variadic
    variadic = node['variadic'] == true

    {
      name: name,
      return_type: return_type,
      params: params,
      variadic: variadic,
      raw_type: type_str
    }
  end

  def extract_struct(node)
    name = node['name']
    return nil unless name
    return nil unless node['completeDefinition'] # Skip forward declarations

    fields = []
    if node['inner']
      node['inner'].each do |inner|
        next unless inner['kind'] == 'FieldDecl'

        field_name = inner['name']
        field_type = inner.dig('type', 'qualType')
        fields << { name: field_name, type: field_type } if field_name && field_type
      end
    end

    {
      name: name,
      fields: fields
    }
  end

  def extract_typedef(node)
    name = node['name']
    return nil unless name

    underlying = node.dig('type', 'qualType')
    return nil unless underlying

    {
      name: name,
      underlying: underlying
    }
  end

  def extract_enum(node)
    name = node['name']
    # Anonymous enums are skipped for now (could be typedef'd)
    return nil unless name

    variants = []
    if node['inner']
      node['inner'].each do |inner|
        next unless inner['kind'] == 'EnumConstantDecl'

        variant_name = inner['name']
        # Extract value from evaluatedValue or inner ConstantExpr
        value = nil
        if inner['inner']
          inner['inner'].each do |val_node|
            if val_node['kind'] == 'ConstantExpr'
              value = val_node.dig('value')
            elsif val_node['kind'] == 'IntegerLiteral'
              value = val_node.dig('value')
            end
          end
        end
        # Also check for evaluatedValue in modern clang
        value ||= inner.dig('evaluatedValue')

        variants << { name: variant_name, value: value }
      end
    end

    return nil if variants.empty?

    {
      name: name,
      variants: variants
    }
  end

  def extract_macros
    # Clang AST doesn't include preprocessor macros, so we need to use -dM
    # We run it twice: once without the header (baseline) and once with,
    # then take the difference to get only macros defined by the header

    # Get baseline macros (without header)
    baseline_cmd = ['clang', '-E', '-dM', '-x', 'c', '/dev/null']
    baseline_stdout, _, baseline_status = Open3.capture3(*baseline_cmd)
    baseline_macros = Set.new
    if baseline_status.success?
      baseline_stdout.each_line do |line|
        if (match = line.match(/^#define\s+(\w+)/))
          baseline_macros << match[1]
        end
      end
    end

    # Get macros with header
    cmd = ['clang', '-E', '-dM']
    @include_dirs.each { |dir| cmd += ['-I', dir] }
    cmd << @header_path

    stdout, stderr, status = Open3.capture3(*cmd)

    unless status.success?
      warn "clang -dM failed: #{stderr}" if $VERBOSE
      return []
    end

    macros = []
    stdout.each_line do |line|
      # Match: #define NAME value
      # We want simple integer constants only (not function-like macros)
      # Patterns:
      #   #define MAX_SIZE 1024
      #   #define VERSION 0x0102
      #   #define FLAG (1 << 3)   -- skip complex expressions for now
      next unless (match = line.match(/^#define\s+([A-Z][A-Z0-9_]*)\s+(\d+|0x[0-9A-Fa-f]+)\s*$/))

      name, value = match.captures
      # Skip common system/compiler macros
      next if name.start_with?('__', '_')
      next if %w[NULL EOF].include?(name)
      # Skip macros that were in baseline (not from this header)
      next if baseline_macros.include?(name)

      macros << { name: name, value: value }
    end

    macros
  end

  def parse_function_type(type_str)
    # Match: "return_type (param1, param2, ...)"
    # Handle complex cases like "void *(size_t)" or "int (*)(int, int)"
    match = type_str.match(/^(.+?)\s*\((.*)\)$/)
    return nil unless match

    return_type = match[1].strip
    params_str = match[2].strip

    [return_type, params_str]
  end

  def should_include_function?(name)
    return true if @include_all
    return true unless @functions

    @functions.include?(name)
  end

  def should_include_struct?(name)
    return true if @include_all
    return true unless @structs

    @structs.include?(name)
  end

  def generate_qz_code(declarations)
    lines = []
    lines << "# Generated by gen_ffi.rb from #{File.basename(@header_path)}"
    lines << '# Do not edit manually - regenerate with:'
    lines << "#   ruby tools/gen_ffi.rb #{@header_path} #{generate_cli_args}"
    lines << ''

    # Generate type aliases for common C types used
    type_aliases = collect_required_types(declarations)
    unless type_aliases.empty?
      lines << '# Type aliases'
      type_aliases.each do |alias_name, qz_type|
        lines << "type #{alias_name} = #{qz_type}"
      end
      lines << ''
    end

    # Generate enums
    unless declarations[:enums].empty?
      lines << '# Enums'
      declarations[:enums].each do |enum|
        lines += generate_enum(enum)
        lines << ''
      end
    end

    # Generate typedefs
    unless declarations[:typedefs].empty?
      lines << '# Type aliases'
      declarations[:typedefs].each do |typedef|
        line = generate_typedef(typedef)
        lines << line if line
      end
      lines << '' unless lines.last == ''
    end

    # Generate structs
    unless declarations[:structs].empty?
      lines << '# Structs'
      declarations[:structs].each do |struct|
        lines += generate_struct(struct)
        lines << ''
      end
    end

    # Generate extern functions
    unless declarations[:functions].empty?
      lines << '# Functions'
      declarations[:functions].each do |func|
        lines << generate_function(func)
      end
      lines << ''
    end

    # Generate macro constants
    unless declarations[:macros].empty?
      lines << '# Constants'
      declarations[:macros].each do |macro|
        lines << generate_macro(macro)
      end
    end

    lines.join("\n")
  end

  def generate_cli_args
    args = []
    args << "--functions #{@functions.join(',')}" if @functions
    args << "--structs #{@structs.join(',')}" if @structs
    args << "--output #{@output}" if @output
    args.join(' ')
  end

  def collect_required_types(declarations)
    types = {}

    # Collect all types from functions
    declarations[:functions].each do |func|
      check_type_alias(func[:return_type], types)
      func[:params].each do |param|
        check_type_alias(param[:type], types)
      end
    end

    # Collect from structs
    declarations[:structs].each do |struct|
      struct[:fields].each do |field|
        check_type_alias(field[:type], types)
      end
    end

    types
  end

  def check_type_alias(c_type, types)
    # No-op: All C types now map directly to built-in Quartz types
    # (CInt, CChar, CPtr, CSize, CFloat, CDouble, Int, Void)
    # No type aliases needed
  end

  def generate_enum(enum)
    lines = []
    lines << "enum #{enum[:name]}"

    enum[:variants].each do |variant|
      # Convert C enum constant name to Quartz PascalCase
      qz_name = variant[:name].split('_').map(&:capitalize).join
      lines << if variant[:value]
                 "  #{qz_name} = #{variant[:value]}"
               else
                 "  #{qz_name}"
               end
    end

    lines << 'end'
    lines
  end

  def generate_typedef(typedef)
    name = typedef[:name]
    underlying = typedef[:underlying]

    # Skip if this is just a struct/enum reference
    return nil if underlying.start_with?('struct ', 'enum ')

    # Map the underlying type
    qz_type = c_type_to_qz(underlying)

    # Skip if it maps to the same name (e.g., time_t -> Int)
    return nil if qz_type == name

    "type #{name} = #{qz_type}"
  end

  def generate_macro(macro)
    # Keep original SCREAMING_SNAKE_CASE name to match C convention
    # Quartz supports hex literals, so keep those too
    "const #{macro[:name]} = #{macro[:value]}"
  end

  def generate_struct(struct)
    lines = []
    lines << '@repr(C)'
    lines << "struct #{struct[:name]}"

    struct[:fields].each do |field|
      qz_type = c_type_to_qz(field[:type])
      lines << "  #{field[:name]}: #{qz_type}"
    end

    lines << 'end'
    lines
  end

  def generate_function(func)
    params_str = func[:params].map do |param|
      qz_type = c_type_to_qz(param[:type])
      "#{param[:name]}: #{qz_type}"
    end.join(', ')

    # Add variadic indicator
    if func[:variadic]
      params_str += ', ...' unless params_str.empty?
      params_str = '...' if params_str.empty?
    end

    ret_type = c_type_to_qz(func[:return_type])

    if ret_type == 'Void'
      "extern \"C\" fn #{func[:name]}(#{params_str})"
    else
      "extern \"C\" fn #{func[:name]}(#{params_str}): #{ret_type}"
    end
  end

  def c_type_to_qz(c_type)
    return 'CPtr' unless c_type

    # Normalize whitespace
    c_type = c_type.gsub(/\s+/, ' ').strip

    # Check for pointer types first
    return 'CPtr' if c_type.include?('*')

    # Check for const qualifier and remove it
    c_type = c_type.gsub(/\bconst\b/, '').strip

    # Check for struct/union prefix
    c_type = c_type.gsub(/^struct\s+/, '').gsub(/^union\s+/, '')

    # Direct mapping
    return C_TO_BE_TYPES[c_type] if C_TO_BE_TYPES[c_type]

    # Check for unsigned variants
    if c_type.start_with?('unsigned ')
      base = c_type.sub('unsigned ', '')
      unsigned_key = "unsigned #{base}"
      return C_TO_BE_TYPES[unsigned_key] if C_TO_BE_TYPES[unsigned_key]
    end

    # Check for long long
    if c_type.include?('long long')
      return c_type.include?('unsigned') ? 'CULongLong' : 'CLongLong'
    end

    # Default: treat as opaque type (CPtr for now, could be improved)
    warn "Warning: Unknown C type '#{c_type}', using CPtr"
    'CPtr'
  end
end

# CLI
if __FILE__ == $0
  options = {
    functions: nil,
    structs: nil,
    output: nil,
    include_dirs: [],
    all: false
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} <header.h> [options]"

    opts.on('--functions NAMES', 'Comma-separated function names to include') do |v|
      options[:functions] = v.split(',').map(&:strip)
    end

    opts.on('--structs NAMES', 'Comma-separated struct names to include') do |v|
      options[:structs] = v.split(',').map(&:strip)
    end

    opts.on('--output PATH', 'Output file path') do |v|
      options[:output] = v
    end

    opts.on('-I', '--include-dir PATH', 'Additional include directory') do |v|
      options[:include_dirs] << v
    end

    opts.on('--all', 'Include all declarations') do
      options[:all] = true
    end

    opts.on('-h', '--help', 'Show this help') do
      puts opts
      exit
    end
  end

  parser.parse!

  if ARGV.empty?
    puts parser
    exit 1
  end

  header_path = ARGV[0]

  unless File.exist?(header_path)
    warn "Error: Header file not found: #{header_path}"
    exit 1
  end

  generator = FFIGenerator.new(header_path, options)
  output = generator.generate

  if output
    if options[:output]
      # Ensure directory exists
      dir = File.dirname(options[:output])
      FileUtils.mkdir_p(dir) unless File.directory?(dir)

      File.write(options[:output], output)
      puts "Generated: #{options[:output]}"
    else
      puts output
    end
  else
    warn 'Failed to generate FFI bindings'
    exit 1
  end
end
