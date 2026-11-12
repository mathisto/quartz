#!/usr/bin/env ruby

require "digest"

IDENTITY = /\A[A-Za-z0-9][A-Za-z0-9_-]*_spec\.qz\z/
FROZEN_LEGACY_IDENTITY = "_stress_large_program_spec.qz"

def portable_identity?(basename)
  basename == FROZEN_LEGACY_IDENTITY || IDENTITY.match?(basename)
end

def options!
  ARGV.each_slice(2).to_h.tap do |options|
    abort "missing option value" unless ARGV.length.even?
    yield options
  end
end

def read_regular_nofollow(path)
  abort "symlink rejected: #{path}" if File.lstat(path).symlink?
  flags = File::RDONLY
  flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
  File.open(path, flags) do |file|
    stat = file.stat
    abort "not a regular file: #{path}" unless stat.file?
    return file.read
  end
rescue Errno::ELOOP
  abort "symlink rejected: #{path}"
end

command = ARGV.shift
case command
when "check"
  options = options! { |parsed| parsed }
  source = options.fetch("--source")
  selected_path = options.fetch("--selected")
  snapshot = options.fetch("--snapshot")
  status_path = options.fetch("--status")
  expected_digest = options.fetch("--source-sha256")
  expected_count = Integer(options.fetch("--expected-count"), 10)
  repository = File.realpath(options.fetch("--repository"))
  expected_parent = File.realpath(File.join(repository, "spec/qspec"))

  source_bytes = read_regular_nofollow(source)
  if replacement = ENV["QSPEC_DISCOVERY_TEST_REPLACE_SOURCE_AFTER_READ"]
    File.rename(replacement, source)
  end
  actual_digest = Digest::SHA256.hexdigest(source_bytes)
  expected = source_bytes.lines(chomp: true)
  source_valid = actual_digest == expected_digest &&
    source_bytes.end_with?("\n") &&
    expected.length == expected_count && expected == expected.sort && expected.uniq == expected &&
    expected.all? { |path| path == "spec/qspec/#{File.basename(path)}" && portable_identity?(File.basename(path)) }

  selected = read_regular_nofollow(selected_path).lines(chomp: true)
  filesystem_errors = []
  selected.each do |identity|
    basename = File.basename(identity)
    unless identity == "spec/qspec/#{basename}" && portable_identity?(basename)
      filesystem_errors << "nonportable identity: #{identity.inspect}"
      next
    end
    path = File.join(repository, identity)
    begin
      lst = File.lstat(path)
      raise "symlink rejected" if lst.symlink?
      raise "not a regular file" unless lst.file?
      raise "resolved parent escaped spec/qspec" unless File.realpath(File.dirname(path)) == expected_parent
      flags = File::RDONLY
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      File.open(path, flags) { |file| raise "opened object is not regular" unless file.stat.file? }
    rescue SystemCallError, RuntimeError => error
      filesystem_errors << "#{identity}: #{error.message}"
    end
  end

  File.binwrite(snapshot, source_bytes)
  error = if !source_valid
    "identity manifest digest/content invalid"
  elsif !filesystem_errors.empty?
    filesystem_errors.join("; ")
  else
    ""
  end
  File.binwrite(status_path, [actual_digest, source_valid ? "1" : "0", filesystem_errors.empty? ? "1" : "0", error.empty? ? "-" : error].join("\t") + "\n")
  exit Integer(ENV["QSPEC_DISCOVERY_TEST_EXIT_AFTER_PUBLICATION"], 10) if ENV["QSPEC_DISCOVERY_TEST_EXIT_AFTER_PUBLICATION"]
  exit(error.empty? ? 0 : 1)
else
  abort "usage: qspec_discovery_contract.rb check OPTIONS"
end
