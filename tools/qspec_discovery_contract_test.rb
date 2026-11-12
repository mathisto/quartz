#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
HELPER = File.join(ROOT, "tools/qspec_discovery_contract.rb")

def assert(condition, message)
  abort "discovery contract assertion failed: #{message}" unless condition
end

def run_helper(*argv, env: {})
  Open3.capture3(env, RbConfig.ruby, HELPER, *argv)
end

Dir.mktmpdir("qspec-discovery-contract.") do |tmp|
  repository = File.join(tmp, "repo")
  qspec = File.join(repository, "spec/qspec")
  FileUtils.mkdir_p(qspec)
  identity = "spec/qspec/_stress_large_program_spec.qz"
  File.binwrite(File.join(repository, identity), "regular\n")
  selected = File.join(tmp, "selected")
  File.binwrite(selected, "#{identity}\n")

  source = File.join(tmp, "identities")
  original = "#{identity}\n"
  File.binwrite(source, original)
  digest = Digest::SHA256.hexdigest(original)
  snapshot = File.join(tmp, "snapshot")
  status = File.join(tmp, "status")
  args = ["check", "--source", source, "--source-sha256", digest, "--selected", selected,
          "--snapshot", snapshot, "--status", status, "--expected-count", "1", "--repository", repository]
  _out, error, result = run_helper(*args)
  assert(result.success?, "regular selected object rejected: #{error}")
  assert(File.binread(snapshot) == original, "snapshot changed parsed manifest bytes")

  outside = File.join(tmp, "outside_spec.qz")
  File.binwrite(outside, "outside\n")
  symlink_identity = "spec/qspec/symlink_spec.qz"
  File.symlink(outside, File.join(repository, symlink_identity))
  File.binwrite(selected, "#{symlink_identity}\n")
  _out, _error, result = run_helper(*args)
  assert(!result.success?, "symlink to outside was accepted")
  assert(File.binread(status).include?("symlink rejected"), "symlink rejection was not explicit")

  File.binwrite(selected, "#{identity}\n")
  replacement = File.join(tmp, "replacement")
  File.binwrite(replacement, "spec/qspec/beta_spec.qz\n")
  File.binwrite(source, original)
  _out, error, result = run_helper(*args, env: { "QSPEC_DISCOVERY_TEST_REPLACE_SOURCE_AFTER_READ" => replacement })
  assert(result.success?, "opened-byte swap fixture failed: #{error}")
  assert(File.binread(snapshot) == original, "pathname replacement changed parsed bytes")
  assert(File.binread(source) != original, "swap fixture did not replace pathname")
  assert(File.binread(status).start_with?(digest), "digest was not computed over parsed bytes")

  File.binwrite(source, original)
  _out, _error, result = run_helper(*args, env: { "QSPEC_DISCOVERY_TEST_EXIT_AFTER_PUBLICATION" => "23" })
  assert(result.exitstatus == 23, "post-publication nonzero fixture did not exit 23")
  assert(File.binread(snapshot) == original && File.exist?(status), "nonzero fixture did not publish evidence first")

  output_path = File.join(tmp, "updated-identities")
  _out, _error, result = run_helper("update", "--output", output_path)
  assert(!result.success?, "removed update command remained enabled")
  assert(!File.exist?(output_path), "removed update command published output")
end

Dir.mktmpdir("qspec-discovery-preflight.") do |tmp|
  marker = File.join(tmp, "executed")
  added = File.join(ROOT, "spec/qspec/discovery_contract_side_effect_spec.qz")
  manifest = File.join(tmp, "manifest.json")
  begin
    File.binwrite(added, <<~QZ)
      import * from qspec
      import file
      def main(): Int
        write_file(env_get("QSPEC_DISCOVERY_SIDE_EFFECT"), "executed")
        return qspec_main()
      end
    QZ
    env = { "QSPEC_DISCOVERY_SIDE_EFFECT" => marker, "QSPEC_DISCOVERY_TEST_EXIT_AFTER_PUBLICATION" => "23", "QSPEC_PREWARM" => "0", "QSPEC_NO_RETRY" => "1", "QSPEC_MANIFEST" => manifest }
    output, error, result = Open3.capture3(env, File.join(ROOT, "self-hosted/bin/quake"), "qspec", chdir: ROOT)
    assert(!result.success?, "added identity did not fail preflight")
    assert(!File.exist?(marker), "substituted/added test executed before contract failure")
    assert(File.exist?(manifest), "preflight did not publish manifest: #{output}#{error}")
    parsed = JSON.parse(File.binread(manifest))
    assert(parsed.dig("selection", "expected_discovery", "matches") == false, "failed exact set not published")
    assert(parsed.dig("selection", "expected_discovery", "preflight_error").include?("helper process failed"), "nonzero helper exit was ignored after publication")
    assert(parsed.fetch("cache_mode") == "not-started", "prewarm started before contract failure")
    hashes = parsed.fetch("files").map { |file| file.dig("parent_observed", "selection", "selected_pre_execution_content_hash") }
    assert(hashes.all?(&:empty?), "source hashing occurred before contract failure")
  ensure
    FileUtils.rm_f(added)
  end
end

puts "qspec discovery contract host/adversarial fixtures: PASS"
