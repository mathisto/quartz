#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "securerandom"
require "shellwords"
require "time"

class GuardError < StandardError; end

class QuartzGuard
  SCHEMA = 2
  STAMP_SCHEMA = 2
  POLICY_SCHEMA = 1
  ENTRY = "self-hosted/quartz.qz"
  BINARY = "self-hosted/bin/quartz"
  STAMP = "self-hosted/.fixpoint"
  POLICY = "tools/quartz_guard_inputs.json"
  SUPERVISOR = "tools/qspec_supervise.rb"
  ARTIFACT_ROOT = "self-hosted/.guard/artifacts"
  POINTER = "self-hosted/.guard/current"
  FLAGS = ["--no-opt", "--no-cache"].freeze
  INCLUDE_DIRS = %w[
    self-hosted/frontend self-hosted/middle self-hosted/backend self-hosted/error
    self-hosted/shared tools std .
  ].freeze
  STAGES = %w[
    gen1 canonical_verify candidate gen2 fixpoint debug_verify architecture
    smoke_brainfuck smoke_expr_eval smoke_style_demo cache_ro cache_warm
  ].freeze
  SMOKES = {
    "smoke_brainfuck" => "examples/brainfuck.qz",
    "smoke_expr_eval" => "examples/expr_eval.qz",
    "smoke_style_demo" => "examples/style_demo.qz"
  }.freeze
  CLAIM_SCOPE = {
    "attested_by_reproduction" => %w[source_manifest_sha256 seed_sha256 target flags toolchain environment commands input_manifest_sha256 stable_ir_sha256 candidate_behavior],
    "consistency_only" => %w[seed_provenance validated_at candidate_sha256]
  }.freeze

  def initialize(root: Dir.pwd, env: ENV, out: $stdout, err: $stderr)
    @root = File.realpath(root)
    @env = env
    @out = out
    @err = err
    @git_dir = File.expand_path(capture!("git", "rev-parse", "--git-dir").strip, @root)
    @lock_io = nil
    @run_root = nil
    @snapshot = nil
    @seed = nil
    @toolchain = nil
    @command_records = []
    @policy_transition_evidence = nil
    @trusted_supervisor_path = nil
    @authoritative_reproduction = false
    @trust_approval = nil
  end

  def run(mode)
    validate_mode!(mode)
    reject_target_override!
    verify_checker!(mode)
    acquire_lock(mode)
    cleanup_abandoned_runs!
    recover_publication!(repair: true)
    @run_root = File.join(@root, "tmp", "guard", run_id)
    @snapshot = File.join(@run_root, "snapshot")
    FileUtils.mkdir_p(@snapshot)
    entries = materialize(mode, @snapshot)
    @seed = select_trusted_seed
    source_manifest, source_manifest_sha = build_source_manifest(entries, @snapshot)
    manifest, manifest_sha = build_manifest(mode, @snapshot, entries, @seed.fetch("sha256"), @seed.fetch("provenance"))
    manifest_path = File.join(@run_root, "input.manifest")
    durable_write(manifest_path, manifest, 0o600)
    update_lock_metadata(mode, manifest_sha)
    candidate, stable_ir = validate_candidate(@snapshot)
    stamp = build_stamp(mode, source_manifest_sha, manifest_sha, candidate, stable_ir)
    publish(candidate, stamp, manifest_path, stable_ir)
    @out.puts("Guard PASSED (#{mode}) manifest=#{manifest_sha} binary=#{sha256_regular(candidate, executable: true)}")
  ensure
    cleanup
  end

  def check(mode, index_artifacts: mode == "staged")
    validate_mode!(mode)
    reject_target_override!
    verify_checker!(mode)
    recover_publication!(repair: false)
    base = File.join(@root, "tmp", "guard-check", run_id)
    snapshot = File.join(base, "snapshot")
    FileUtils.mkdir_p(snapshot)
    entries = materialize(mode, snapshot)
    stamp_bytes = index_artifacts ? index_blob(STAMP, expected_mode: "100644") : read_regular(STAMP)
    stamp = parse_stamp(stamp_bytes)
    _source_manifest, expected_source_sha = build_source_manifest(entries, snapshot)
    manifest, expected_manifest_sha = build_manifest(
      mode, snapshot, entries, stamp.fetch("seed_sha256"), stamp.fetch("seed_provenance"),
      target_value: stamp.fetch("target"), flags_value: stamp.fetch("flags"), toolchain_value: stamp.fetch("toolchain")
    )
    errors = []
    errors << "stamp mode mismatch" unless stamp["mode"] == mode
    errors << "policy transition evidence mismatch" unless stamp["policy_transition"] == @policy_transition_evidence
    errors << "source manifest mismatch" unless stamp["source_manifest_sha256"] == expected_source_sha
    errors << "input manifest mismatch" unless stamp["input_manifest_sha256"] == expected_manifest_sha
    errors << "validation set mismatch" unless stamp["validation"] == STAGES
    actual_binary_sha = sha256_regular(File.join(@root, BINARY), executable: true)
    errors << "installed binary SHA mismatch" unless stamp["candidate_sha256"] == actual_binary_sha
    if index_artifacts
      index_binary_sha = Digest::SHA256.hexdigest(index_blob(BINARY, expected_mode: "100755"))
      errors << "index binary SHA mismatch" unless stamp["candidate_sha256"] == index_binary_sha
    end
    errors << "manifest payload mismatch" unless Digest::SHA256.hexdigest(manifest) == stamp["input_manifest_sha256"]
    raise GuardError, errors.join("; ") unless errors.empty?

    @out.puts("Guard check PASSED (#{mode}) manifest=#{expected_manifest_sha} binary=#{actual_binary_sha}")
  ensure
    FileUtils.rm_rf(base) if base
  end

  def status
    recover_publication!(repair: false)
    stamp = parse_stamp(read_regular(STAMP))
    @out.puts(JSON.pretty_generate(stamp))
    %w[worktree staged].each do |mode|
      begin
        check(mode, index_artifacts: mode == "staged")
      rescue GuardError => e
        @out.puts("#{mode}: STALE (#{e.message})")
      end
    end
  end

  def recover
    acquire_lock("recover")
    cleanup_abandoned_runs!
    recover_publication!(repair: true)
    @out.puts("Guard publication mirrors are current")
  ensure
    cleanup
  end

  def reproduce(candidate, legacy: false)
    actual_checker = Digest::SHA256.file(File.realpath(__FILE__)).hexdigest
    if legacy
      checker_path = @env["QUARTZ_GUARD_LEGACY_CHECKER"]
      pinned = @env["QUARTZ_GUARD_LEGACY_CHECKER_SHA256"]
      raise GuardError, "legacy reproduction requires pinned checker path and SHA" unless checker_path && pinned == actual_checker && File.realpath(checker_path) == File.realpath(__FILE__)
      policy_bytes = pinned_external_file("QUARTZ_GUARD_LEGACY_POLICY", "QUARTZ_GUARD_LEGACY_POLICY_SHA256", "legacy policy", executable: false)
      supervisor_bytes, supervisor_path = pinned_external_file_with_path("QUARTZ_GUARD_LEGACY_SUPERVISOR", "QUARTZ_GUARD_LEGACY_SUPERVISOR_SHA256", "legacy supervisor", executable: true)
      base_ref = nil
      seed_path = @env["QUARTZ_GUARD_LEGACY_BASE_SEED"]
      seed_sha = @env["QUARTZ_GUARD_LEGACY_BASE_SEED_SHA256"]
    else
      pinned = @env["QUARTZ_GUARD_TRUSTED_CHECKER_SHA256"]
      raise GuardError, "independent reproduction requires a pinned trusted checker SHA" unless pinned == actual_checker
      base_ref = @env["QUARTZ_GUARD_BASE_REF"]
      raise GuardError, "independent reproduction requires QUARTZ_GUARD_BASE_REF" unless base_ref && !base_ref.empty?
      base_ref = resolve_commit(base_ref)
      policy_bytes = ref_blob(base_ref, POLICY, "100644")
      supervisor_bytes = ref_blob(base_ref, SUPERVISOR, "100755")
      supervisor_path = nil
      seed_path = @env["QUARTZ_GUARD_BASE_SEED"]
      seed_sha = @env["QUARTZ_GUARD_BASE_SEED_SHA256"]
    end
    candidate = resolve_commit(candidate) unless candidate == "index"
    reject_target_override!
    acquire_lock("reproduce")
    cleanup_abandoned_runs!
    @run_root = File.join(@root, "tmp", "guard-reproduce", run_id)
    @snapshot = File.join(@run_root, "snapshot")
    FileUtils.mkdir_p(@snapshot)
    @authoritative_reproduction = true
    @trust_approval = load_trust_approval(policy_bytes, legacy: legacy)
    @trusted_policy_bytes = policy_bytes
    @trusted_supervisor_path = supervisor_path || materialize_trusted_runtime("supervisor", supervisor_bytes, 0o500)
    base_entries = base_ref ? ref_entries(base_ref) : (candidate == "index" ? index_entries : ref_entries(candidate))
    entries = materialize_candidate(candidate, @snapshot, policy_bytes, base_entries)
    @seed = trusted_external_seed(seed_path, seed_sha, legacy ? "legacy base seed" : "base seed")
    submitted_stamp_bytes, submitted_binary = candidate_artifacts(candidate)
    submitted_stamp = parse_stamp(submitted_stamp_bytes)
    raise GuardError, "submitted reproduction stamp must be staged mode" unless submitted_stamp["mode"] == "staged"
    raise GuardError, "submitted validation set differs from authoritative protocol" unless submitted_stamp["validation"] == STAGES
    source_manifest, source_sha = build_source_manifest(entries, @snapshot)
    raise GuardError, "submitted source manifest does not match reproduced candidate source" unless submitted_stamp["source_manifest_sha256"] == source_sha
    raise GuardError, "submitted policy transition evidence mismatch" unless submitted_stamp["policy_transition"] == @policy_transition_evidence
    submitted_binary_sha = Digest::SHA256.hexdigest(submitted_binary)
    raise GuardError, "submitted binary does not match submitted stamp" unless submitted_binary_sha == submitted_stamp["candidate_sha256"]
    expected_seed_sha = @seed.fetch("sha256")
    raise GuardError, "submitted seed SHA does not match trusted reproduction seed" unless submitted_stamp["seed_sha256"] == expected_seed_sha
    raise GuardError, "submitted host target differs from reproduction host" unless submitted_stamp["target"] == host_target
    raise GuardError, "submitted flags differ from reproduction flags" unless submitted_stamp["flags"] == FLAGS
    candidate_binary, stable_ir = validate_candidate(@snapshot)
    reproduced_stable_sha = sha256_regular(stable_ir)
    raise GuardError, "independent stable IR reproduction mismatch" unless reproduced_stable_sha == submitted_stamp["stable_ir_sha256"]
    raise GuardError, "submitted toolchain differs from reproduced toolchain" unless comparable_toolchain(submitted_stamp["toolchain"]) == comparable_toolchain(toolchain)
    raise GuardError, "submitted environment differs from reproduced environment" unless submitted_stamp["environment"] == recorded_environment
    raise GuardError, "submitted command plan differs from reproduced command plan" unless submitted_stamp["commands"] == @command_records
    reproduced_manifest, reproduced_manifest_sha = build_manifest(
      submitted_stamp.fetch("mode"), @snapshot, entries, submitted_stamp.fetch("seed_sha256"),
      submitted_stamp.fetch("seed_provenance"), target_value: submitted_stamp.fetch("target"),
      flags_value: submitted_stamp.fetch("flags"), toolchain_value: submitted_stamp.fetch("toolchain")
    )
    raise GuardError, "submitted input manifest differs from reproduced observations" unless submitted_stamp["input_manifest_sha256"] == reproduced_manifest_sha && !reproduced_manifest.empty?
    if @env["QUARTZ_GUARD_MOCK_COMMAND"] || @env["QUARTZ_GUARD_REPRODUCIBLE_BINARY"] == "1"
      raise GuardError, "independent candidate binary reproduction mismatch" unless sha256_regular(candidate_binary, executable: true) == submitted_binary_sha
    else
      submitted_path = File.join(@run_root, "submitted", "quartz")
      FileUtils.mkdir_p(File.dirname(submitted_path))
      durable_write(submitted_path, submitted_binary, 0o755)
      submitted_ir = File.join(@run_root, "submitted", "stable.ll")
      includes = INCLUDE_DIRS.flat_map { |dir| ["-I", File.join(@snapshot, dir)] }
      supervised!("submitted_binary_ir", [submitted_path, *FLAGS, *includes, File.join(@snapshot, ENTRY)], stdout: submitted_ir, stderr: File.join(@run_root, "submitted", "compile.err"))
      raise GuardError, "submitted binary does not reproduce submitted stable IR" unless sha256_regular(submitted_ir) == submitted_stamp["stable_ir_sha256"]
    end
    @out.puts("Guard reproduction PASSED candidate=#{candidate} source=#{source_sha} stable_ir=#{reproduced_stable_sha}")
  ensure
    cleanup
  end

  private

  def validate_mode!(mode)
    raise GuardError, "mode must be worktree or staged" unless %w[worktree staged].include?(mode)
  end

  def reject_target_override!
    raise GuardError, "QUARTZ_GUARD_TARGET is unsupported; guard validates the host target" if @env.key?("QUARTZ_GUARD_TARGET")
  end

  def verify_checker!(mode)
    return if @env["QUARTZ_GUARD_TEST_TRUST_CHECKER"] == "1" && @env["QUARTZ_GUARD_MOCK_COMMAND"]
    return unless %w[staged worktree].include?(mode)

    expected = begin
      Digest::SHA256.hexdigest(ref_blob("HEAD", "tools/quartz_guard.rb", "100755"))
    rescue GuardError
      bootstrap = @env["QUARTZ_GUARD_BOOTSTRAP_CHECKER_SHA256"]
      raise GuardError, "HEAD has no trusted checker; follow the documented bootstrap migration" unless bootstrap&.match?(/\A[0-9a-f]{64}\z/)
      bootstrap
    end
    actual = Digest::SHA256.file(File.realpath(__FILE__)).hexdigest
    raise GuardError, "running checker differs from trusted HEAD/base checker" unless actual == expected
  end

  def acquire_lock(mode)
    lock_path = File.join(@git_dir, "quartz-guard.lock")
    @lock_io = File.open(lock_path, File::RDWR | File::CREAT, 0o600)
    unless @lock_io.flock(File::LOCK_EX | File::LOCK_NB)
      metadata = File.join(@git_dir, "quartz-guard.owner.json")
      detail = File.file?(metadata) ? File.read(metadata).strip : "owner metadata unavailable"
      raise GuardError, "another guard holds the advisory lock: #{detail}"
    end
    update_lock_metadata(mode, nil)
  end

  def update_lock_metadata(mode, manifest_sha)
    metadata = {
      "schema" => 1, "pid" => Process.pid, "started_at" => Time.now.utc.iso8601,
      "mode" => mode, "manifest_sha256" => manifest_sha, "run_root" => @run_root
    }
    atomic_write(File.join(@git_dir, "quartz-guard.owner.json"), JSON.generate(metadata) + "\n", 0o600)
  end

  def cleanup
    FileUtils.rm_rf(@run_root) if @run_root
    return unless @lock_io

    @lock_io.flock(File::LOCK_UN)
    @lock_io.close
    @lock_io = nil
  end

  def cleanup_abandoned_runs!
    %w[tmp/guard tmp/guard-reproduce].each do |relative|
      root = File.join(@root, relative)
      next unless File.directory?(root) && !File.symlink?(root)
      Dir.children(root).each { |name| FileUtils.rm_rf(File.join(root, name)) }
    end
  end

  def run_id
    "#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{Process.pid}-#{SecureRandom.hex(6)}"
  end

  def materialize(mode, snapshot)
    index = index_entries
    policy_bytes = trusted_policy_bytes(mode, index)
    policy = parse_policy(policy_bytes)
    base_entries = begin
      ref_entries("HEAD")
    rescue GuardError
      index
    end
    selected = select_candidate_policy_entries(policy, base_entries, index)
    validate_index_entry!(index, BINARY, "100755")
    selected.each do |path, expected_mode|
      bytes = if mode == "staged"
                entry = validate_index_entry!(index, path, expected_mode)
                git_blob(entry.fetch("oid"))
              else
                validate_index_entry!(index, path, expected_mode)
                read_worktree_input(path, expected_mode)
              end
      write_snapshot_blob(snapshot, path, bytes, expected_mode)
    end
    selected
  end

  def trusted_policy_bytes(mode, index)
    return @trusted_policy_bytes if @trusted_policy_bytes
    ref_blob("HEAD", POLICY, "100644")
  rescue GuardError
    expected = @env["QUARTZ_GUARD_BOOTSTRAP_POLICY_SHA256"]
    raise GuardError, "HEAD has no trusted guard input policy; follow the documented bootstrap migration" unless expected&.match?(/\A[0-9a-f]{64}\z/)
    bytes = mode == "staged" ? index_blob(POLICY, expected_mode: "100644", entries: index) : read_worktree_input(POLICY, "100644")
    raise GuardError, "bootstrap policy SHA mismatch" unless Digest::SHA256.hexdigest(bytes) == expected
    bytes
  end

  def index_entries
    raw = capture!("git", "ls-files", "-s", "-z", binary: true)
    entries = {}
    raw.split("\0").reject(&:empty?).each do |record|
      metadata, path = record.split("\t", 2)
      raise GuardError, "malformed Git index entry" unless path
      mode, oid, stage = metadata.split(" ", 3)
      raise GuardError, "unmerged index entry: #{path}" unless stage == "0"
      raise GuardError, "duplicate index entry: #{path}" if entries.key?(path)
      entries[path] = { "mode" => mode, "oid" => oid }
    end
    entries
  end

  def parse_policy(bytes)
    policy = JSON.parse(bytes)
    keys = %w[schema inventory_sha256 trees files transition meta_policy]
    raise GuardError, "unsupported guard input policy schema" unless policy == policy.slice(*keys) && policy["schema"] == POLICY_SCHEMA
    raise GuardError, "invalid guard input inventory identity" unless policy["inventory_sha256"].is_a?(String) && policy["inventory_sha256"].match?(/\A[0-9a-f]{64}\z/)
    raise GuardError, "invalid guard input trees" unless policy["trees"].is_a?(Array)
    raise GuardError, "invalid guard input files" unless policy["files"].is_a?(Array)
    transition = policy["transition"]
    raise GuardError, "invalid policy transition configuration" unless transition.is_a?(Hash) && transition.keys.sort == %w[path protected roots]
    clean_relative(transition.fetch("path"))
    raise GuardError, "invalid protected transition paths" unless transition["protected"].is_a?(Array)
    transition["protected"].each { |path| clean_relative(path) }
    raise GuardError, "invalid transition roots" unless transition["roots"].is_a?(Array)
    meta = policy["meta_policy"]
    raise GuardError, "invalid meta-policy fields" unless meta.is_a?(Hash) && meta.keys.sort == %w[schema transition_authority trust_components]
    raise GuardError, "unsupported meta-policy schema" unless meta["schema"] == 1
    raise GuardError, "invalid transition authority" unless meta["transition_authority"] == "protected-base-or-pinned-external"
    raise GuardError, "invalid trust component list" unless meta["trust_components"].is_a?(Array) && !meta["trust_components"].empty?
    meta["trust_components"].each do |component|
      raise GuardError, "invalid trust component" unless component.is_a?(Hash) && component.keys.sort == %w[kind mode path]
      clean_relative(component.fetch("path"))
      validate_policy_mode(component.fetch("mode"))
      raise GuardError, "invalid trust component kind" unless %w[immutable policy-meta].include?(component["kind"])
    end
    policy
  rescue JSON::ParserError => e
    raise GuardError, "invalid guard input policy: #{e.message}"
  end

  def select_policy_entries(policy, index)
    selected = {}
    policy.fetch("trees").each do |rule|
      raise GuardError, "invalid tree rule" unless rule == rule.slice("root", "suffix", "mode")
      root = clean_relative(rule.fetch("root"))
      suffix = rule.fetch("suffix")
      mode = validate_policy_mode(rule.fetch("mode"))
      matches = index.keys.select { |path| path.start_with?("#{root}/") && path.end_with?(suffix) }
      raise GuardError, "guard input tree is empty: #{root}" if matches.empty?
      matches.each { |path| selected[path] = mode }
    end
    policy.fetch("files").each do |rule|
      raise GuardError, "invalid file rule" unless rule == rule.slice("path", "mode")
      selected[clean_relative(rule.fetch("path"))] = validate_policy_mode(rule.fetch("mode"))
    end
    selected = selected.sort.to_h
    actual_inventory = Digest::SHA256.hexdigest(selected.map { |path, mode| frame("path", path) + frame("mode", mode) }.join)
    raise GuardError, "guard input inventory drift: expected #{policy.fetch("inventory_sha256")}, got #{actual_inventory}" unless actual_inventory == policy.fetch("inventory_sha256")
    selected
  end

  def select_candidate_policy_entries(policy, base_entries, candidate_entries)
    base_selected = select_policy_entries(policy, base_entries)
    transition_path = clean_relative(policy.fetch("transition").fetch("path"))
    transition_entry = validate_index_entry!(candidate_entries, transition_path, "100644")
    transition_bytes = git_blob(transition_entry.fetch("oid"))
    transition = parse_policy_transition(transition_bytes)
    raise GuardError, "policy transition base inventory mismatch" unless transition["base_inventory_sha256"] == policy["inventory_sha256"]
    selected = base_selected.dup
    protected = policy.fetch("transition").fetch("protected").map { |path| clean_relative(path) }
    transition.fetch("delete").each do |rule|
      path = clean_relative(rule.fetch("path"))
      raise GuardError, "policy transition cannot delete protected input: #{path}" if protected.include?(path)
      raise GuardError, "policy transition deletes unknown input: #{path}" unless selected[path] == rule.fetch("mode")
      selected.delete(path)
    end
    transition.fetch("add").each do |rule|
      path = clean_relative(rule.fetch("path"))
      mode = validate_policy_mode(rule.fetch("mode"))
      raise GuardError, "policy transition adds existing input: #{path}" if selected.key?(path)
      raise GuardError, "policy transition addition is outside constrained roots: #{path}" unless transition_addition_allowed?(policy, path, mode)
      selected[path] = mode
    end
    selected = selected.sort.to_h
    actual = inventory_sha(selected)
    raise GuardError, "policy transition candidate inventory mismatch" unless actual == transition["candidate_inventory_sha256"]
    automatically_relevant = policy.fetch("trees").flat_map do |rule|
      root = clean_relative(rule.fetch("root"))
      candidate_entries.keys.select { |path| path.start_with?("#{root}/") && path.end_with?(rule.fetch("suffix")) }
    end.uniq
    unapproved = automatically_relevant.reject { |path| selected.key?(path) }
    raise GuardError, "candidate contains unapproved compiler inputs: #{unapproved.join(", ")}" unless unapproved.empty?
    candidate_policy_bytes = git_blob(validate_index_entry!(candidate_entries, POLICY, "100644").fetch("oid"))
    candidate_policy = parse_policy(candidate_policy_bytes)
    raise GuardError, "candidate policy does not claim transitioned inventory" unless candidate_policy["inventory_sha256"] == actual
    @policy_transition_evidence = {
      "schema" => 1, "base_inventory_sha256" => policy["inventory_sha256"],
      "candidate_inventory_sha256" => actual, "transition_sha256" => Digest::SHA256.hexdigest(transition_bytes),
      "add" => transition["add"], "delete" => transition["delete"]
    }
    validate_trust_takeover!(policy, candidate_policy, candidate_policy_bytes, base_entries, candidate_entries) if @authoritative_reproduction
    selected.each { |path, mode| validate_index_entry!(candidate_entries, path, mode) }
    selected
  rescue JSON::ParserError => e
    raise GuardError, "invalid candidate policy data: #{e.message}"
  end

  def load_trust_approval(base_policy_bytes, legacy:)
    path_key = legacy ? "QUARTZ_GUARD_LEGACY_TRUST_SET" : "QUARTZ_GUARD_TRUST_ROTATION"
    sha_key = legacy ? "QUARTZ_GUARD_LEGACY_TRUST_SET_SHA256" : "QUARTZ_GUARD_TRUST_ROTATION_SHA256"
    return nil unless legacy || @env[path_key] || @env[sha_key]
    bytes = pinned_external_file(path_key, sha_key, legacy ? "legacy initial trust set" : "trust rotation", executable: false)
    approval = JSON.parse(bytes)
    keys = %w[schema base_policy_sha256 next_policy_sha256 components]
    raise GuardError, "invalid external trust approval fields" unless approval.keys.sort == keys.sort && approval["schema"] == 1
    base_sha = Digest::SHA256.hexdigest(base_policy_bytes)
    raise GuardError, "external trust approval base policy SHA mismatch" unless approval["base_policy_sha256"] == base_sha
    next_sha = approval["next_policy_sha256"]
    raise GuardError, "invalid approved next policy SHA" unless next_sha.nil? || (next_sha.is_a?(String) && next_sha.match?(/\A[0-9a-f]{64}\z/))
    raise GuardError, "invalid approved trust components" unless approval["components"].is_a?(Array)
    approval["components"].each do |component|
      raise GuardError, "invalid approved trust component" unless component.is_a?(Hash) && component.keys.sort == %w[mode path sha256]
      clean_relative(component.fetch("path"))
      validate_policy_mode(component.fetch("mode"))
      raise GuardError, "invalid approved trust component SHA" unless component["sha256"].is_a?(String) && component["sha256"].match?(/\A[0-9a-f]{64}\z/)
    end
    approval
  rescue JSON::ParserError => e
    raise GuardError, "invalid external trust approval: #{e.message}"
  end

  def validate_trust_takeover!(base_policy, candidate_policy, candidate_policy_bytes, base_entries, candidate_entries)
    base_normalized = JSON.parse(JSON.generate(base_policy))
    candidate_normalized = JSON.parse(JSON.generate(candidate_policy))
    base_files = base_policy.fetch("files").to_h { |rule| [rule.fetch("path"), rule.fetch("mode")] }
    candidate_files = candidate_policy.fetch("files").to_h { |rule| [rule.fetch("path"), rule.fetch("mode")] }
    added_files = candidate_files.reject { |path, mode| base_files[path] == mode }
    deleted_files = base_files.reject { |path, mode| candidate_files[path] == mode }
    transition_add = @policy_transition_evidence.fetch("add").to_h { |rule| [rule.fetch("path"), rule.fetch("mode")] }
    transition_delete = @policy_transition_evidence.fetch("delete").to_h { |rule| [rule.fetch("path"), rule.fetch("mode")] }
    unless added_files.all? { |path, mode| transition_add[path] == mode } && deleted_files.all? { |path, mode| transition_delete[path] == mode }
      raise GuardError, "candidate policy file inventory change is not authorized by constrained transition"
    end
    candidate_normalized["inventory_sha256"] = base_normalized["inventory_sha256"]
    candidate_normalized["files"] = base_normalized["files"]
    policy_meta_changed = candidate_normalized != base_normalized
    candidate_policy_sha = Digest::SHA256.hexdigest(candidate_policy_bytes)
    if policy_meta_changed
      approved = @trust_approval && @trust_approval["next_policy_sha256"] == candidate_policy_sha
      raise GuardError, "candidate meta-policy change lacks externally approved full policy SHA" unless approved
    end

    approvals = (@trust_approval&.fetch("components", []) || []).to_h { |item| [item.fetch("path"), item] }
    trust_components = base_policy.dig("meta_policy", "trust_components")
    candidate_components = candidate_policy.dig("meta_policy", "trust_components")
    if policy_meta_changed
      trust_components = (trust_components + candidate_components).uniq { |item| item.fetch("path") }
    end
    trust_components.each do |component|
      next if component["kind"] == "policy-meta"
      path = component.fetch("path")
      mode = component.fetch("mode")
      base_entry = base_entries[path]
      candidate_entry = validate_index_entry!(candidate_entries, path, mode)
      candidate_sha = Digest::SHA256.hexdigest(git_blob(candidate_entry.fetch("oid")))
      base_sha = base_entry && base_entry["mode"] == mode ? Digest::SHA256.hexdigest(git_blob(base_entry.fetch("oid"))) : nil
      changed = base_sha != candidate_sha
      approval = approvals[path]
      must_pin = changed || @env.key?("QUARTZ_GUARD_LEGACY_TRUST_SET")
      next unless must_pin
      valid = approval && approval["mode"] == mode && approval["sha256"] == candidate_sha
      raise GuardError, "trust component change lacks exact external approval: #{path}" unless valid
    end
    if @env.key?("QUARTZ_GUARD_LEGACY_TRUST_SET")
      raise GuardError, "legacy initial trust set must approve full policy SHA" unless @trust_approval["next_policy_sha256"] == candidate_policy_sha
    end
  end

  def parse_policy_transition(bytes)
    transition = JSON.parse(bytes)
    keys = %w[schema base_inventory_sha256 candidate_inventory_sha256 add delete]
    raise GuardError, "invalid policy transition fields" unless transition.keys.sort == keys.sort && transition["schema"] == 1
    %w[base_inventory_sha256 candidate_inventory_sha256].each do |key|
      raise GuardError, "invalid policy transition #{key}" unless transition[key].is_a?(String) && transition[key].match?(/\A[0-9a-f]{64}\z/)
    end
    %w[add delete].each do |key|
      raise GuardError, "invalid policy transition #{key}" unless transition[key].is_a?(Array)
      transition[key].each do |rule|
        raise GuardError, "invalid policy transition entry" unless rule.is_a?(Hash) && rule.keys.sort == %w[mode path]
        clean_relative(rule.fetch("path"))
        validate_policy_mode(rule.fetch("mode"))
      end
    end
    transition
  rescue JSON::ParserError => e
    raise GuardError, "invalid policy transition: #{e.message}"
  end

  def transition_addition_allowed?(policy, path, mode)
    policy.fetch("transition").fetch("roots").any? do |rule|
      raise GuardError, "invalid transition root rule" unless rule.keys.sort == %w[mode root suffixes]
      root = clean_relative(rule.fetch("root"))
      suffixes = rule.fetch("suffixes")
      raise GuardError, "invalid transition suffixes" unless suffixes.is_a?(Array) && suffixes.all? { |suffix| suffix.is_a?(String) && suffix.start_with?(".") }
      path.start_with?("#{root}/") && suffixes.any? { |suffix| path.end_with?(suffix) } && mode == validate_policy_mode(rule.fetch("mode"))
    end
  end

  def inventory_sha(entries)
    Digest::SHA256.hexdigest(entries.sort.map { |path, mode| frame("path", path) + frame("mode", mode) }.join)
  end

  def validate_policy_mode(mode)
    raise GuardError, "guard inputs must be regular files" unless %w[100644 100755].include?(mode)
    mode
  end

  def validate_index_entry!(entries, path, expected_mode)
    entry = entries[path]
    raise GuardError, "required staged input missing: #{path}" unless entry
    mode = entry.fetch("mode")
    raise GuardError, "symlink input rejected: #{path}" if mode == "120000"
    raise GuardError, "gitlink input rejected: #{path}" if mode == "160000"
    raise GuardError, "nonregular or wrong mode #{mode} for #{path}; expected #{expected_mode}" unless mode == expected_mode
    entry
  end

  def index_blob(path, expected_mode:, entries: nil)
    entries ||= index_entries
    git_blob(validate_index_entry!(entries, path, expected_mode).fetch("oid"))
  end

  def git_blob(oid)
    capture!("git", "cat-file", "blob", oid, binary: true)
  end

  def read_worktree_input(path, expected_mode)
    clean = clean_relative(path)
    absolute = File.join(@root, clean)
    reject_symlink_parents!(absolute)
    stat = File.lstat(absolute)
    raise GuardError, "worktree symlink input rejected: #{clean}" if stat.symlink?
    raise GuardError, "worktree input is not regular: #{clean}" unless stat.file?
    executable = (stat.mode & 0o111).positive?
    raise GuardError, "worktree executable mode mismatch: #{clean}" unless executable == (expected_mode == "100755")
    File.binread(absolute)
  rescue Errno::ENOENT
    raise GuardError, "worktree input missing: #{clean}"
  end

  def write_snapshot_blob(snapshot, path, bytes, mode)
    destination = File.join(snapshot, clean_relative(path))
    FileUtils.mkdir_p(File.dirname(destination))
    flags = File::WRONLY | File::CREAT | File::EXCL
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    io = File.open(destination, flags, mode == "100755" ? 0o755 : 0o644)
    io.binmode
    io.write(bytes)
    io.flush
    io.fsync
    raise GuardError, "snapshot destination is not regular: #{path}" unless io.stat.file?
    io.close
  ensure
    io&.close unless io&.closed?
  end

  def clean_relative(path)
    raise GuardError, "path must be a String" unless path.is_a?(String) && !path.include?("\0")
    clean = Pathname.new(path).cleanpath.to_s
    raise GuardError, "input escapes repository: #{path}" if clean == "." || clean == ".." || clean.start_with?("../", "/")
    clean
  end

  def build_manifest(mode, snapshot, entries, seed_sha, seed_provenance, target_value: host_target, flags_value: FLAGS, toolchain_value: toolchain)
    fields = [
      ["schema", SCHEMA.to_s], ["mode", mode], ["policy", POLICY], ["entry", ENTRY],
      ["target", target_value], ["flags", flags_value.join("\0")],
      ["include_dirs", INCLUDE_DIRS.join("\0")], ["cache_schema", "cold-no-cache-v2"],
      ["seed_sha256", seed_sha], ["seed_provenance", seed_provenance], ["toolchain", canonical_json(toolchain_value)]
    ]
    entries.each do |path, mode_value|
      bytes = File.binread(File.join(snapshot, path))
      value = frame("path", path) + frame("mode", mode_value) + frame("sha256", Digest::SHA256.hexdigest(bytes))
      fields << ["file", value]
    end
    manifest = fields.map { |key, value| frame(key, value) }.join
    [manifest, Digest::SHA256.hexdigest(manifest)]
  end

  def build_source_manifest(entries, snapshot)
    fields = [["schema", SCHEMA.to_s], ["policy_inventory", policy_inventory_sha(snapshot)]]
    entries.each do |path, mode_value|
      bytes = File.binread(File.join(snapshot, path))
      value = frame("path", path) + frame("mode", mode_value) + frame("sha256", Digest::SHA256.hexdigest(bytes))
      fields << ["file", value]
    end
    manifest = fields.map { |key, value| frame(key, value) }.join
    [manifest, Digest::SHA256.hexdigest(manifest)]
  end

  def policy_inventory_sha(snapshot)
    JSON.parse(File.read(File.join(snapshot, POLICY))).fetch("inventory_sha256")
  rescue JSON::ParserError, KeyError => e
    raise GuardError, "cannot read snapshot policy identity: #{e.message}"
  end

  def frame(key, value)
    "#{key.bytesize}:#{key}#{value.bytesize}:#{value}\n"
  end

  def canonical_json(value)
    JSON.generate(value.sort.to_h)
  end

  def select_trusted_seed
    if File.file?(File.join(@root, POINTER))
      artifact = validate_current_artifact!
      live_sha = sha256_regular(File.join(@root, BINARY), executable: true)
      raise GuardError, "installed seed differs from published artifact" unless live_sha == artifact.fetch("stamp").fetch("candidate_sha256")
      return { "path" => File.join(@root, BINARY), "sha256" => live_sha, "provenance" => "artifact:#{artifact.fetch("id")}" }
    end

    begin
      return select_committed_seed
    rescue GuardError => committed_error
      @err.puts("guard: committed seed unavailable: #{committed_error.message}") if @env["QUARTZ_GUARD_VERBOSE"] == "1"
    end

    recovery_path = @env["QUARTZ_GUARD_RECOVERY_SEED"]
    expected = @env["QUARTZ_GUARD_RECOVERY_SEED_SHA256"]
    raise GuardError, "no trusted published seed; set QUARTZ_GUARD_RECOVERY_SEED and QUARTZ_GUARD_RECOVERY_SEED_SHA256" unless recovery_path && expected&.match?(/\A[0-9a-f]{64}\z/)
    absolute = File.expand_path(recovery_path)
    live_path = File.join(@root, BINARY)
    raise GuardError, "recovery seed must not be the installed live compiler" if File.realpath(absolute) == File.realpath(live_path)
    recovery_stat = File.lstat(absolute)
    raise GuardError, "recovery seed must be read-only" unless (recovery_stat.mode & 0o222).zero?
    actual = sha256_regular(absolute, executable: true)
    raise GuardError, "recovery seed SHA mismatch" unless actual == expected
    { "path" => absolute, "sha256" => actual, "provenance" => "recovery:#{File.realpath(absolute)}" }
  rescue Errno::ENOENT
    raise GuardError, "recovery seed does not exist"
  end

  def select_committed_seed
    stamp_bytes = read_regular(STAMP)
    stamp = parse_stamp(stamp_bytes)
    raise GuardError, "installed stamp differs from HEAD" unless stamp_bytes == ref_blob("HEAD", STAMP, "100644")
    committed_binary = ref_blob("HEAD", BINARY, "100755")
    committed_sha = Digest::SHA256.hexdigest(committed_binary)
    live_sha = sha256_regular(File.join(@root, BINARY), executable: true)
    raise GuardError, "installed binary differs from HEAD" unless live_sha == committed_sha
    raise GuardError, "committed binary SHA does not match stamp" unless live_sha == stamp.fetch("candidate_sha256")

    snapshot = File.join(@run_root, "committed-seed-snapshot")
    FileUtils.mkdir_p(snapshot)
    entries = materialize_ref("HEAD", snapshot)
    _source_manifest, source_manifest_sha = build_source_manifest(entries, snapshot)
    raise GuardError, "committed source manifest mismatch" unless source_manifest_sha == stamp.fetch("source_manifest_sha256")
    manifest, manifest_sha = build_manifest(
      stamp.fetch("mode"), snapshot, entries, stamp.fetch("seed_sha256"), stamp.fetch("seed_provenance"),
      target_value: stamp.fetch("target"), flags_value: stamp.fetch("flags"), toolchain_value: stamp.fetch("toolchain")
    )
    raise GuardError, "committed source/provenance manifest mismatch" unless manifest_sha == stamp.fetch("input_manifest_sha256")
    raise GuardError, "committed manifest payload is empty" if manifest.empty?
    { "path" => File.join(@root, BINARY), "sha256" => live_sha, "provenance" => "commit:#{capture!("git", "rev-parse", "HEAD").strip}" }
  end

  def materialize_ref(ref, snapshot)
    entries = ref_entries(ref)
    policy_bytes = ref_blob(ref, POLICY, "100644", entries: entries)
    policy = parse_policy(policy_bytes)
    selected = select_policy_entries(policy, entries)
    validate_index_entry!(entries, BINARY, "100755")
    selected.each do |path, mode|
      entry = validate_index_entry!(entries, path, mode)
      write_snapshot_blob(snapshot, path, git_blob(entry.fetch("oid")), mode)
    end
    selected
  end

  def materialize_candidate(candidate, snapshot, policy_bytes, base_entries)
    policy = parse_policy(policy_bytes)
    entries = candidate == "index" ? index_entries : ref_entries(candidate)
    selected = select_candidate_policy_entries(policy, base_entries, entries)
    validate_index_entry!(entries, BINARY, "100755")
    selected.each do |path, mode|
      entry = validate_index_entry!(entries, path, mode)
      write_snapshot_blob(snapshot, path, git_blob(entry.fetch("oid")), mode)
    end
    selected
  end

  def pinned_external_file(path_key, sha_key, label, executable:)
    bytes, = pinned_external_file_with_path(path_key, sha_key, label, executable: executable)
    bytes
  end

  def pinned_external_file_with_path(path_key, sha_key, label, executable:)
    path = @env[path_key]
    expected = @env[sha_key]
    raise GuardError, "#{label} requires pinned path and SHA" unless path && expected&.match?(/\A[0-9a-f]{64}\z/)
    original_stat = File.lstat(path)
    raise GuardError, "#{label} must not be a symlink" if original_stat.symlink?
    absolute = File.realpath(path)
    raise GuardError, "#{label} must be outside the candidate repository" if absolute.start_with?(File.expand_path(@root) + File::SEPARATOR)
    stat = File.lstat(absolute)
    raise GuardError, "#{label} must be a regular read-only file" unless stat.file? && !stat.symlink? && (stat.mode & 0o222).zero?
    raise GuardError, "#{label} must be executable" if executable && (stat.mode & 0o111).zero?
    bytes = File.binread(absolute)
    raise GuardError, "#{label} SHA mismatch" unless Digest::SHA256.hexdigest(bytes) == expected
    [bytes, absolute]
  rescue Errno::ENOENT
    raise GuardError, "#{label} does not exist"
  end

  def materialize_trusted_runtime(name, bytes, mode)
    path = File.join(@run_root, "trusted-runtime", name)
    FileUtils.mkdir_p(File.dirname(path))
    durable_write(path, bytes, mode)
    path
  end

  def comparable_toolchain(value)
    normalized = Marshal.load(Marshal.dump(value))
    seed = normalized.fetch("compiler_seed")
    seed["path"] = "$SEED"
    seed["argv"] = ["$SEED", *seed.fetch("argv").drop(1)]
    normalized
  end

  def candidate_artifacts(candidate)
    if candidate == "index"
      [index_blob(STAMP, expected_mode: "100644"), index_blob(BINARY, expected_mode: "100755")]
    else
      entries = ref_entries(candidate)
      [ref_blob(candidate, STAMP, "100644", entries: entries), ref_blob(candidate, BINARY, "100755", entries: entries)]
    end
  end

  def trusted_external_seed(path, expected, label)
    raise GuardError, "independent reproduction requires #{label} path and SHA" unless path && expected&.match?(/\A[0-9a-f]{64}\z/)
    absolute = File.expand_path(path)
    raise GuardError, "#{label} must be outside the candidate repository" if absolute.start_with?(File.expand_path(@root) + File::SEPARATOR)
    stat = File.lstat(absolute)
    raise GuardError, "#{label} must be read-only" unless (stat.mode & 0o222).zero?
    actual = sha256_regular(absolute, executable: true)
    raise GuardError, "#{label} SHA mismatch" unless actual == expected
    provenance = @env["QUARTZ_GUARD_BASE_REF"] ? "base:#{base_ref_identity}" : "external:#{expected}"
    { "path" => absolute, "sha256" => actual, "provenance" => provenance }
  rescue Errno::ENOENT
    raise GuardError, "#{label} does not exist"
  end

  def base_ref_identity
    resolve_commit(@env.fetch("QUARTZ_GUARD_BASE_REF"))
  end

  def resolve_commit(ref)
    raise GuardError, "invalid Git ref" unless ref.is_a?(String) && ref.match?(/\A[A-Za-z0-9._\/-]+\z/) && !ref.start_with?("-")
    oid = capture!("git", "rev-parse", "--verify", "#{ref}^{commit}").strip
    raise GuardError, "invalid commit identity" unless oid.match?(/\A[0-9a-f]{40,64}\z/)
    oid
  end

  def ref_entries(ref)
    raw = capture!("git", "ls-tree", "-rz", ref, binary: true)
    entries = {}
    raw.split("\0").reject(&:empty?).each do |record|
      metadata, path = record.split("\t", 2)
      raise GuardError, "malformed #{ref} tree entry" unless path
      mode, type, oid = metadata.split(" ", 3)
      raise GuardError, "non-blob #{ref} input rejected: #{path}" unless type == "blob"
      entries[path] = { "mode" => mode, "oid" => oid }
    end
    entries
  end

  def ref_blob(ref, path, expected_mode, entries: nil)
    entries ||= ref_entries(ref)
    git_blob(validate_index_entry!(entries, path, expected_mode).fetch("oid"))
  end

  def host_target
    reject_target_override!
    linker_triple = capture!(*linker_argv, "-dumpmachine").strip
    raise GuardError, "linker did not report a host target" if linker_triple.empty?
    "#{RbConfig::CONFIG.fetch("host")}|#{linker_triple}"
  end

  def toolchain
    @toolchain ||= {
      "ruby" => tool_identity(RbConfig.ruby), "opt" => tool_identity(tool("opt")),
      "llc" => tool_identity(tool("llc")), "linker" => tool_identity(linker),
      "bash" => tool_identity("bash"), "file" => tool_identity("file"),
      "compiler_seed" => seed_identity, "sdk" => sdk_identity, "libraries" => library_identities
    }
  end

  def tool_identity(command)
    command_argv = Shellwords.split(command)
    executable = resolve_executable(command)
    stdout, stderr, status = Open3.capture3(executable, "--version")
    raise GuardError, "cannot identify tool: #{executable}" unless status.success?
    { "argv" => [executable, *command_argv.drop(1)], "path" => executable,
      "sha256" => sha256_regular(executable), "version" => (stdout.empty? ? stderr : stdout).lines.first.to_s.strip }
  end

  def seed_identity
    version = if @env["QUARTZ_GUARD_MOCK_COMMAND"]
                "fixture-seed"
              else
                stdout, stderr, status = Open3.capture3(@seed.fetch("path"), "--version")
                raise GuardError, "cannot identify compiler seed" unless status.success?
                (stdout.empty? ? stderr : stdout).lines.first.to_s.strip
              end
    { "argv" => [@seed.fetch("path")], "path" => @seed.fetch("path"),
      "sha256" => @seed.fetch("sha256"), "version" => version }
  end

  def sdk_identity
    if RUBY_PLATFORM.include?("darwin")
      path = capture!("xcrun", "--show-sdk-path").strip
      version = capture!("xcrun", "--show-sdk-version").strip
      { "kind" => "apple-sdk", "path" => path, "version" => version }
    else
      output, _stderr, status = Open3.capture3(*linker_argv, "--print-sysroot")
      { "kind" => "compiler-sysroot", "path" => status.success? ? output.strip : "", "version" => RbConfig::CONFIG.fetch("host_os") }
    end
  end

  def library_identities
    %w[libc.a libm.a libpthread.a libmimalloc.a].to_h do |name|
      output, _stderr, status = Open3.capture3(*linker_argv, "-print-file-name=#{name}")
      path = status.success? ? output.strip : ""
      identity = { "query" => name, "path" => path, "sha256" => "unresolved" }
      identity["sha256"] = sha256_regular(path) if !path.empty? && path != name && File.file?(path) && !File.symlink?(path)
      [name, identity]
    end
  end

  def recorded_environment
    keys = %w[PATH SDKROOT MACOSX_DEPLOYMENT_TARGET LIBRARY_PATH CPATH CFLAGS CXXFLAGS LDFLAGS]
    keys.to_h { |key| [key, @env.fetch(key, "")] }
  end

  def tool(name)
    @env.fetch("QUARTZ_GUARD_#{name.upcase}", name)
  end

  def linker
    @env.fetch("QUARTZ_GUARD_LINKER", File.executable?("/usr/bin/clang") ? "/usr/bin/clang" : "clang")
  end

  def linker_argv
    Shellwords.split(linker)
  end

  def resolve_executable(command)
    executable = Shellwords.split(command).first
    if executable.include?(File::SEPARATOR)
      return File.realpath(executable) if File.file?(executable) && File.executable?(executable)
      raise GuardError, "tool not executable: #{executable}"
    end
    path = capture!("sh", "-c", "command -v #{Shellwords.escape(executable)}").strip
    raise GuardError, "tool not found: #{executable}" if path.empty?
    File.realpath(path)
  end

  def validate_candidate(snapshot)
    paths = {
      "snapshot" => snapshot, "run_root" => @run_root, "seed" => @seed.fetch("path"),
      "candidate" => File.join(@run_root, "candidate", "quartz"),
      "gen1" => File.join(@run_root, "ir", "gen1.ll"), "gen2" => File.join(@run_root, "ir", "gen2.ll"),
      "debug" => File.join(@run_root, "ir", "debug.ll")
    }
    paths.values_at("candidate", "gen1", "gen2", "debug").each { |path| FileUtils.mkdir_p(File.dirname(path)) }
    STAGES.each do |stage|
      run_stage(stage, paths)
      case stage
      when "gen1" then require_nonempty(paths["gen1"], stage)
      when "candidate" then require_nonempty(paths["candidate"], stage)
      when "gen2" then require_nonempty(paths["gen2"], stage)
      when "fixpoint"
        raise GuardError, "fixpoint mismatch" unless File.binread(paths["gen1"]) == File.binread(paths["gen2"])
      when "debug_verify" then require_nonempty(paths["debug"], stage)
      end
    end
    [paths.fetch("candidate"), paths.fetch("gen2")]
  end

  def run_stage(stage, paths)
    fail_stage = @env["QUARTZ_GUARD_FAIL_STAGE"]
    raise GuardError, "simulated failure at #{stage}" if fail_stage == stage
    mock = @env["QUARTZ_GUARD_MOCK_COMMAND"]
    if mock
      env = paths.transform_keys { |key| "GUARD_#{key.upcase}" }.merge("GUARD_STAGE" => stage)
      supervised!(stage, Shellwords.split(mock), env: env)
      return
    end

    source = File.join(paths.fetch("snapshot"), ENTRY)
    includes = INCLUDE_DIRS.flat_map { |dir| ["-I", File.join(paths.fetch("snapshot"), dir)] }
    case stage
    when "gen1"
      supervised!(stage, [paths.fetch("seed"), *FLAGS, *includes, source], stdout: paths.fetch("gen1"), stderr: File.join(@run_root, "gen1.err"))
    when "canonical_verify"
      supervised!(stage, [tool("opt"), "-passes=verify", paths.fetch("gen1"), "-disable-output"])
    when "candidate"
      optimized = File.join(@run_root, "ir", "gen1.opt.ll")
      object = File.join(@run_root, "candidate", "quartz.o")
      supervised!("candidate_opt", [tool("opt"), "--passes=always-inline", paths.fetch("gen1"), "-o", optimized, "-S"])
      supervised!("candidate_llc", [tool("llc"), "-filetype=obj", optimized, "-o", object])
      link_flags = RUBY_PLATFORM.include?("darwin") ? ["-Wl,-stack_size,0x2000000"] : []
      link_flags << "-lmimalloc" if RUBY_PLATFORM.include?("linux")
      supervised!("candidate_link", [*linker_argv, "-g", *link_flags, object, "-o", paths.fetch("candidate"), "-lm", "-lpthread"])
    when "gen2"
      supervised!(stage, [paths.fetch("candidate"), *FLAGS, *includes, source], stdout: paths.fetch("gen2"), stderr: File.join(@run_root, "gen2.err"))
    when "fixpoint"
      nil
    when "debug_verify"
      supervised!("debug_compile", [paths.fetch("candidate"), *FLAGS, "--debug", *includes, source], stdout: paths.fetch("debug"), stderr: File.join(@run_root, "debug.err"))
      supervised!(stage, [tool("opt"), "-passes=verify", paths.fetch("debug"), "-disable-output"])
    when "architecture"
      verify_architecture(paths.fetch("candidate"))
    when *SMOKES.keys
      run_smoke(stage, paths, includes)
    when "cache_ro"
      run_cache_ro(paths, includes)
    when "cache_warm"
      cache = File.join(@run_root, "cache-warm")
      FileUtils.mkdir_p(cache)
      supervised!(stage, ["bash", File.join(paths.fetch("snapshot"), "tools/cache_invalidation_vecstruct_smoke.sh")],
                  env: { "QUARTZ" => paths.fetch("candidate"), "LLC" => tool("llc"), "CC" => linker, "TMPDIR" => cache })
    else
      raise GuardError, "unknown guard stage: #{stage}"
    end
  end

  def verify_architecture(candidate)
    output_path = File.join(@run_root, "architecture.txt")
    supervised!("architecture", ["file", candidate], stdout: output_path)
    output = File.read(output_path)
    expected = RbConfig::CONFIG.fetch("host_cpu")
    aliases = expected.match?(/arm|aarch64/) ? %w[arm64 aarch64] : [expected, "x86-64"]
    raise GuardError, "candidate architecture mismatch: expected #{expected}, got #{output.strip}" unless aliases.any? { |name| output.downcase.include?(name.downcase) }
  end

  def run_smoke(stage, paths, includes)
    relative = SMOKES.fetch(stage)
    dir = File.join(@run_root, "smokes", stage)
    FileUtils.mkdir_p(dir)
    ir = File.join(dir, "program.ll")
    object = File.join(dir, "program.o")
    binary = File.join(dir, "program")
    supervised!("#{stage}_compile", [paths.fetch("candidate"), "--no-cache", *includes, File.join(paths.fetch("snapshot"), relative)], stdout: ir, stderr: File.join(dir, "compile.err"))
    supervised!("#{stage}_llc", [tool("llc"), "-filetype=obj", ir, "-o", object])
    supervised!("#{stage}_link", [*linker_argv, object, "-o", binary, "-lm", "-lpthread"])
    supervised!("#{stage}_run", [binary], stdout: File::NULL, stderr: File::NULL)
  end

  def run_cache_ro(paths, includes)
    cache = File.join(@run_root, "cache-ro")
    FileUtils.mkdir_p(cache)
    prewarm = File.join(paths.fetch("snapshot"), "spec/qspec/_qspec_prewarm.qz")
    supervised!("cache_ro_prewarm", [paths.fetch("candidate"), "--cache-dir", cache, *includes, prewarm], stdout: File::NULL, stderr: File.join(cache, "prewarm.err"))
    %w[spec/qspec/network_timeout_spec.qz spec/qspec/https_spec.qz].each_with_index do |relative, index|
      ir = File.join(cache, "smoke-#{index}.ll")
      supervised!("cache_ro_compile_#{index}", [paths.fetch("candidate"), "--cache-dir", cache, "--cache-ro", *includes, File.join(paths.fetch("snapshot"), relative)], stdout: ir, stderr: File.join(cache, "smoke-#{index}.err"))
      supervised!("cache_ro_llc_#{index}", [tool("llc"), "-filetype=obj", ir, "-o", File.join(cache, "smoke-#{index}.o")])
    end
  end

  def supervised!(stage, argv, env: {}, stdout: "", stderr: "")
    protocol_stage = stage.gsub(/[^a-z0-9_-]/, "-")
    dir = File.join(@run_root, "supervision")
    FileUtils.mkdir_p(dir)
    token = "#{protocol_stage}-#{SecureRandom.hex(5)}"
    request = File.join(dir, "#{token}.request")
    status = File.join(dir, "#{token}.status")
    stdout = "" if stdout == File::NULL
    stderr = "" if stderr == File::NULL
    deadline = stage_deadline_ms(stage)
    @command_records << {
      "stage" => stage, "argv" => argv.map { |value| normalize_record_value(value) },
      "env" => env.sort.to_h.transform_values { |value| normalize_record_value(value) },
      "cwd" => "$REPO", "deadline_ms" => deadline, "grace_ms" => 2_000,
      "stdout" => normalize_record_value(stdout), "stderr" => normalize_record_value(stderr)
    }
    body = +"QSP2\n"
    [protocol_stage, deadline, 2_000, @root, stdout, stderr, 0, "", @run_root].each { |value| body << qsp_field(value) }
    body << "#{argv.length}\n"
    argv.each { |value| body << qsp_field(value) }
    body << "#{env.length}\n"
    env.each { |key, value| body << qsp_field(key) << qsp_field(value) }
    durable_write(request, body, 0o600)
    supervisor = @trusted_supervisor_path || trusted_local_supervisor
    success = system(RbConfig.ruby, supervisor, request, status, chdir: @root, out: @out, err: @err)
    raise GuardError, "#{stage}: supervisor failed to publish" unless success && File.file?(status)
    fields = File.read(status).split("\t", -1)
    raise GuardError, "#{stage}: malformed supervisor status" unless fields.length == 13 && fields[0] == "QSS2"
    unless fields[3].empty? && fields[4] == "0" && fields[5] == "0" && fields[6] == "0" && fields[10] == "0"
      raise GuardError, "#{stage}: supervised failure exit=#{fields[4]} signal=#{fields[5]} timeout=#{fields[6]} orphan=#{fields[10]} error=#{fields[3]}"
    end
  end

  def trusted_local_supervisor
    return @trusted_supervisor_path if @trusted_supervisor_path
    bytes = begin
      ref_blob("HEAD", SUPERVISOR, "100755")
    rescue GuardError
      expected = @env["QUARTZ_GUARD_BOOTSTRAP_SUPERVISOR_SHA256"]
      path = @env["QUARTZ_GUARD_BOOTSTRAP_SUPERVISOR"]
      raise GuardError, "HEAD has no trusted supervisor; follow the documented bootstrap migration" unless path && expected
      pinned_external_file("QUARTZ_GUARD_BOOTSTRAP_SUPERVISOR", "QUARTZ_GUARD_BOOTSTRAP_SUPERVISOR_SHA256", "bootstrap supervisor", executable: true)
    end
    @trusted_supervisor_path = materialize_trusted_runtime("supervisor", bytes, 0o500)
  end

  def normalize_record_value(value)
    value.to_s.gsub(@snapshot.to_s, "$SNAPSHOT").gsub(@run_root.to_s, "$RUN").gsub(@root, "$REPO").gsub(@seed&.fetch("path", ""), "$SEED")
  end

  def qsp_field(value)
    bytes = value.to_s.b
    "#{bytes.bytesize}\n#{bytes}\n"
  end

  def stage_deadline_ms(stage)
    override = @env["QUARTZ_GUARD_STAGE_TIMEOUT_MS"]
    return Integer(override, 10) if override
    return 1_200_000 if stage.match?(/gen|compile|candidate/)
    return 600_000 if stage.match?(/llc|link|verify/)
    120_000
  end

  def build_stamp(mode, source_manifest_sha, manifest_sha, candidate, stable_ir)
    JSON.generate(
      "schema" => STAMP_SCHEMA, "mode" => mode, "source_manifest_sha256" => source_manifest_sha,
      "input_manifest_sha256" => manifest_sha,
      "candidate_sha256" => sha256_regular(candidate, executable: true), "seed_sha256" => @seed.fetch("sha256"),
      "seed_provenance" => @seed.fetch("provenance"), "stable_ir_sha256" => sha256_regular(stable_ir),
      "target" => host_target, "flags" => FLAGS, "toolchain" => toolchain,
      "environment" => recorded_environment, "commands" => @command_records,
      "policy_transition" => @policy_transition_evidence, "claim_scope" => CLAIM_SCOPE,
      "validated_at" => Time.now.utc.iso8601, "validation" => STAGES
    ) + "\n"
  end

  def publish(candidate, stamp_bytes, manifest_path, stable_ir)
    stamp = parse_stamp(stamp_bytes)
    artifact_id = "#{stamp.fetch("candidate_sha256")}-#{stamp.fetch("input_manifest_sha256")}-#{Digest::SHA256.hexdigest(stamp_bytes)}"
    root = File.join(@root, ARTIFACT_ROOT)
    reject_symlink_parents!(root)
    FileUtils.mkdir_p(root)
    temporary = File.join(root, ".tmp-#{run_id}")
    final = File.join(root, artifact_id)
    FileUtils.mkdir(temporary)
    durable_copy(candidate, File.join(temporary, "quartz"), 0o755)
    durable_write(File.join(temporary, "stamp.json"), stamp_bytes, 0o644)
    durable_copy(manifest_path, File.join(temporary, "input.manifest"), 0o644)
    durable_copy(stable_ir, File.join(temporary, "stable.ll"), 0o644)
    fsync_directory(temporary)
    File.rename(temporary, final)
    fsync_directory(root)
    raise GuardError, "simulated publication crash before pointer" if @env["QUARTZ_GUARD_FAIL_PUBLICATION"] == "before-pointer"
    previous = File.file?(File.join(@root, POINTER)) ? read_pointer.fetch("current") : nil
    pointer_bytes = JSON.generate("schema" => 1, "current" => artifact_id, "previous" => previous) + "\n"
    atomic_write(File.join(@root, POINTER), pointer_bytes, 0o644, fsync_parent: true)
    raise GuardError, "simulated publication crash after pointer" if @env["QUARTZ_GUARD_FAIL_PUBLICATION"] == "after-pointer"
    Process.kill("KILL", Process.pid) if @env["QUARTZ_GUARD_SIGKILL_BOUNDARY"] == "after-pointer"
    synchronize_live_pair!(final)
    prune_artifacts!
  ensure
    FileUtils.rm_rf(temporary) if temporary && File.exist?(temporary)
  end

  def recover_publication!(repair:)
    pointer = File.join(@root, POINTER)
    return unless File.exist?(pointer)
    artifact = validate_current_artifact!
    final = artifact.fetch("path")
    live_binary = File.join(@root, BINARY)
    live_stamp = File.join(@root, STAMP)
    binary_matches = regular_file_matches?(live_binary, File.join(final, "quartz"), executable: true)
    stamp_matches = regular_file_matches?(live_stamp, File.join(final, "stamp.json"))
    return if binary_matches && stamp_matches
    raise GuardError, "interrupted publication detected; run guard:recover" unless repair
    synchronize_live_pair!(final)
    prune_artifacts!
  end

  def validate_current_artifact!
    pointer_state = read_pointer
    pointer = pointer_state.fetch("current")
    path = File.join(@root, ARTIFACT_ROOT, pointer)
    stat = File.lstat(path)
    raise GuardError, "guard artifact is not a directory" unless stat.directory? && !stat.symlink?
    stamp_bytes = read_regular(File.join(ARTIFACT_ROOT, pointer, "stamp.json"))
    stamp = parse_stamp(stamp_bytes)
    manifest = read_regular(File.join(ARTIFACT_ROOT, pointer, "input.manifest"))
    stable_ir = File.join(path, "stable.ll")
    binary_sha = sha256_regular(File.join(path, "quartz"), executable: true)
    raise GuardError, "artifact binary SHA mismatch" unless binary_sha == stamp["candidate_sha256"]
    raise GuardError, "artifact manifest SHA mismatch" unless Digest::SHA256.hexdigest(manifest) == stamp["input_manifest_sha256"]
    raise GuardError, "artifact stable IR SHA mismatch" unless sha256_regular(stable_ir) == stamp["stable_ir_sha256"]
    stamp_sha = Digest::SHA256.hexdigest(stamp_bytes)
    raise GuardError, "artifact directory identity mismatch" unless pointer == "#{binary_sha}-#{stamp["input_manifest_sha256"]}-#{stamp_sha}"
    { "id" => pointer, "path" => path, "stamp" => stamp, "pointer" => pointer_state }
  rescue Errno::ENOENT
    raise GuardError, "guard artifact pointer is incomplete"
  end

  def read_pointer
    pointer = JSON.parse(read_regular(POINTER))
    raise GuardError, "invalid guard artifact pointer fields" unless pointer.keys.sort == %w[current previous schema]
    raise GuardError, "invalid guard artifact pointer schema" unless pointer["schema"] == 1
    pattern = /\A[0-9a-f]{64}-[0-9a-f]{64}-[0-9a-f]{64}\z/
    raise GuardError, "invalid current guard artifact pointer" unless pointer["current"].is_a?(String) && pointer["current"].match?(pattern)
    raise GuardError, "invalid previous guard artifact pointer" unless pointer["previous"].nil? || (pointer["previous"].is_a?(String) && pointer["previous"].match?(pattern))
    pointer
  rescue JSON::ParserError => e
    raise GuardError, "invalid guard artifact pointer: #{e.message}"
  end

  def prune_artifacts!
    pointer = read_pointer
    keep = [pointer["current"], pointer["previous"]].compact
    root = File.join(@root, ARTIFACT_ROOT)
    Dir.children(root).each do |name|
      next if keep.include?(name) || name.start_with?(".tmp-")
      path = File.join(root, name)
      stat = File.lstat(path)
      raise GuardError, "unexpected non-directory guard artifact: #{name}" unless stat.directory? && !stat.symlink?
      FileUtils.rm_rf(path)
    end
    fsync_directory(root)
  end

  def synchronize_live_pair!(artifact)
    reject_symlink_parents!(File.join(@root, BINARY))
    reject_symlink_parents!(File.join(@root, STAMP))
    durable_replace(File.join(artifact, "quartz"), File.join(@root, BINARY), 0o755)
    durable_replace(File.join(artifact, "stamp.json"), File.join(@root, STAMP), 0o644)
  end

  def regular_file_matches?(left, right, executable: false)
    sha256_regular(left, executable: executable) == sha256_regular(right, executable: executable)
  rescue GuardError
    false
  end

  def parse_stamp(bytes)
    stamp = JSON.parse(bytes)
    keys = %w[schema mode source_manifest_sha256 input_manifest_sha256 candidate_sha256 seed_sha256 seed_provenance stable_ir_sha256 target flags toolchain environment commands policy_transition claim_scope validated_at validation]
    raise GuardError, "stamp fields are not exact" unless stamp.keys.sort == keys.sort
    raise GuardError, "unsupported stamp schema" unless stamp["schema"] == STAMP_SCHEMA
    raise GuardError, "invalid stamp mode" unless %w[staged worktree].include?(stamp["mode"])
    %w[source_manifest_sha256 input_manifest_sha256 candidate_sha256 seed_sha256 stable_ir_sha256].each do |key|
      raise GuardError, "invalid stamp #{key}" unless stamp[key].is_a?(String) && stamp[key].match?(/\A[0-9a-f]{64}\z/)
    end
    raise GuardError, "invalid stamp flags" unless stamp["flags"].is_a?(Array) && stamp["flags"].all? { |value| value.is_a?(String) }
    raise GuardError, "invalid stamp target" unless stamp["target"].is_a?(String) && !stamp["target"].empty?
    raise GuardError, "invalid stamp toolchain" unless stamp["toolchain"].is_a?(Hash)
    raise GuardError, "invalid stamp validation" unless stamp["validation"].is_a?(Array)
    raise GuardError, "invalid stamp claim scope" unless stamp["claim_scope"] == CLAIM_SCOPE
    transition = stamp["policy_transition"]
    raise GuardError, "invalid stamp policy transition" unless transition.is_a?(Hash) && transition.keys.sort == %w[add base_inventory_sha256 candidate_inventory_sha256 delete schema transition_sha256]
    %w[base_inventory_sha256 candidate_inventory_sha256 transition_sha256].each do |key|
      raise GuardError, "invalid stamp policy transition #{key}" unless transition[key].is_a?(String) && transition[key].match?(/\A[0-9a-f]{64}\z/)
    end
    provenance_pattern = /\A(?:artifact:[0-9a-f]{64}-[0-9a-f]{64}-[0-9a-f]{64}|commit:[0-9a-f]{40,64}|recovery:\/.+)\z/
    raise GuardError, "invalid stamp seed provenance" unless stamp["seed_provenance"].is_a?(String) && stamp["seed_provenance"].match?(provenance_pattern)
    Time.iso8601(stamp.fetch("validated_at"))
    expected_tool_keys = %w[bash compiler_seed file libraries linker llc opt ruby sdk]
    raise GuardError, "invalid stamp toolchain keys" unless stamp["toolchain"].keys.sort == expected_tool_keys
    %w[bash compiler_seed file linker llc opt ruby].each do |name|
      identity = stamp["toolchain"].fetch(name)
      valid_identity = identity.is_a?(Hash) && identity.keys.sort == %w[argv path sha256 version]
      valid_identity &&= identity["argv"].is_a?(Array) && identity["argv"].all? { |value| value.is_a?(String) }
      valid_identity &&= %w[path sha256 version].all? { |key| identity[key].is_a?(String) }
      valid_identity &&= identity["path"].start_with?("/") && identity["sha256"].match?(/\A[0-9a-f]{64}\z/)
      raise GuardError, "invalid stamp tool identity" unless valid_identity
    end
    raise GuardError, "invalid stamp SDK identity" unless stamp["toolchain"]["sdk"].is_a?(Hash)
    raise GuardError, "invalid stamp library identities" unless stamp["toolchain"]["libraries"].is_a?(Hash)
    environment_keys = %w[CFLAGS CPATH CXXFLAGS LDFLAGS LIBRARY_PATH MACOSX_DEPLOYMENT_TARGET PATH SDKROOT]
    valid_environment = stamp["environment"].is_a?(Hash) && stamp["environment"].keys.sort == environment_keys
    valid_environment &&= stamp["environment"].values.all? { |value| value.is_a?(String) }
    raise GuardError, "invalid stamp environment" unless valid_environment
    valid_commands = stamp["commands"].is_a?(Array) && !stamp["commands"].empty?
    valid_commands &&= stamp["commands"].all? do |record|
      record.is_a?(Hash) && record.keys.sort == %w[argv cwd deadline_ms env grace_ms stage stderr stdout] &&
        record["stage"].is_a?(String) && !record["stage"].empty? &&
        record["argv"].is_a?(Array) && !record["argv"].empty? && record["argv"].all? { |value| value.is_a?(String) } &&
        record["env"].is_a?(Hash) && record["env"].all? { |key, value| key.is_a?(String) && value.is_a?(String) } &&
        record["cwd"] == "$REPO" && record["deadline_ms"].is_a?(Integer) && record["deadline_ms"].positive? &&
        record["grace_ms"].is_a?(Integer) && record["grace_ms"].positive? &&
        record["stdout"].is_a?(String) && record["stderr"].is_a?(String)
    end
    raise GuardError, "invalid stamp commands" unless valid_commands
    stamp
  rescue JSON::ParserError, ArgumentError => e
    raise GuardError, "invalid structured stamp: #{e.message}"
  end

  def read_regular(path)
    absolute = path.start_with?("/") ? path : File.join(@root, clean_relative(path))
    stat = File.lstat(absolute)
    raise GuardError, "symlink rejected: #{path}" if stat.symlink?
    raise GuardError, "nonregular file rejected: #{path}" unless stat.file?
    File.binread(absolute)
  rescue Errno::ENOENT
    raise GuardError, "required file missing: #{path}"
  end

  def sha256_regular(path, executable: false)
    stat = File.lstat(path)
    raise GuardError, "symlink rejected: #{path}" if stat.symlink?
    raise GuardError, "nonregular file rejected: #{path}" unless stat.file?
    raise GuardError, "file is not executable: #{path}" if executable && (stat.mode & 0o111).zero?
    Digest::SHA256.file(path).hexdigest
  rescue Errno::ENOENT
    raise GuardError, "required file missing: #{path}"
  end

  def reject_symlink_parents!(path)
    relative = Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(@root)).to_s
    raise GuardError, "path escapes repository: #{path}" if relative == ".." || relative.start_with?("../")
    current = @root
    relative.split(File::SEPARATOR)[0...-1].each do |component|
      current = File.join(current, component)
      next unless File.exist?(current) || File.symlink?(current)
      stat = File.lstat(current)
      raise GuardError, "symlink parent rejected: #{current}" if stat.symlink?
      raise GuardError, "non-directory parent rejected: #{current}" unless stat.directory?
    end
  end

  def require_nonempty(path, stage)
    raise GuardError, "#{stage} did not produce a regular nonempty file" unless File.file?(path) && !File.symlink?(path) && File.size(path).positive?
  end

  def durable_write(path, bytes, mode)
    FileUtils.mkdir_p(File.dirname(path))
    flags = File::WRONLY | File::CREAT | File::EXCL
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    io = File.open(path, flags, mode)
    io.binmode
    io.write(bytes)
    io.flush
    io.fsync
    io.close
  ensure
    io&.close unless io&.closed?
  end

  def durable_copy(source, destination, mode)
    durable_write(destination, File.binread(source), mode)
  end

  def durable_replace(source, destination, mode)
    temporary = "#{destination}.tmp-#{Process.pid}-#{SecureRandom.hex(4)}"
    durable_copy(source, temporary, mode)
    File.rename(temporary, destination)
    fsync_directory(File.dirname(destination))
  ensure
    FileUtils.rm_f(temporary) if temporary
  end

  def atomic_write(path, bytes, mode, fsync_parent: false)
    temporary = "#{path}.tmp-#{Process.pid}-#{SecureRandom.hex(4)}"
    FileUtils.mkdir_p(File.dirname(path))
    durable_write(temporary, bytes, mode)
    File.rename(temporary, path)
    fsync_directory(File.dirname(path)) if fsync_parent
  ensure
    FileUtils.rm_f(temporary) if temporary
  end

  def fsync_directory(path)
    File.open(path, File::RDONLY) { |io| io.fsync }
  end

  def capture!(*argv, binary: false)
    stdout, stderr, status = Open3.capture3(*argv, chdir: @root, binmode: binary)
    raise GuardError, "command failed: #{argv.shelljoin}: #{stderr.strip}" unless status.success?
    stdout
  end
end

def usage
  warn "usage: tools/quartz_guard.rb run MODE | check MODE | reproduce REF|index | reproduce-bootstrap REF|index | status | recover"
  exit 2
end

begin
  command = ARGV.shift || usage
  guard = QuartzGuard.new
  case command
  when "run" then guard.run(ARGV.shift || usage)
  when "check" then guard.check(ARGV.shift || usage)
  when "reproduce" then guard.reproduce(ARGV.shift || usage)
  when "reproduce-bootstrap" then guard.reproduce(ARGV.shift || usage, legacy: true)
  when "status" then guard.status
  when "recover" then guard.recover
  else usage
  end
rescue GuardError, Interrupt => e
  warn "guard: #{e.message}"
  exit 1
end
