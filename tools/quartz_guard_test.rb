#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "securerandom"
require "tmpdir"

class QuartzGuardProtocolTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  GUARD = File.join(ROOT, "tools/quartz_guard.rb")
  SUPERVISOR = File.join(ROOT, "tools/qspec_supervise.rb")
  STAGES = %w[gen1 canonical_verify candidate gen2 fixpoint debug_verify architecture smoke_brainfuck smoke_expr_eval smoke_style_demo cache_ro cache_warm].freeze

  def setup
    @dir = Dir.mktmpdir("quartz-guard-protocol-")
    @external = Dir.mktmpdir("quartz-guard-external-")
    git("init", "-q")
    write("self-hosted/quartz.qz", "compiler = staged\nfrom dep import helper\n")
    write("std/prelude.qz", "prelude = 1\n")
    write("std/dep.qz", "helper = 1\n")
    write("self-hosted/bin/quartz", "installed-seed\n", mode: 0o755)
    write("self-hosted/.fixpoint", "legacy-stamp\n")
    FileUtils.mkdir_p(File.join(@dir, "tools"))
    FileUtils.copy_file(SUPERVISOR, File.join(@dir, "tools/qspec_supervise.rb"))
    File.chmod(0o755, File.join(@dir, "tools/qspec_supervise.rb"))
    FileUtils.copy_file(GUARD, File.join(@dir, "tools/quartz_guard.rb"))
    File.chmod(0o755, File.join(@dir, "tools/quartz_guard.rb"))
    write_policy
    tracked = %w[
      self-hosted/quartz.qz self-hosted/bin/quartz self-hosted/.fixpoint
      std/prelude.qz std/dep.qz tools/qspec_supervise.rb tools/quartz_guard.rb tools/quartz_guard_inputs.json
      tools/quartz_guard_policy_transition.json
    ]
    tracked.each { |path| stage(path) }
    commit_index

    @recovery = File.join(@external, "recovery-seed")
    File.binwrite(@recovery, "immutable-recovery-seed\n")
    File.chmod(0o555, @recovery)
    @tool = File.join(@external, "fixture-tool")
    File.write(@tool, <<~'RUBY')
      #!/usr/bin/env ruby
      if ARGV.include?("-dumpmachine")
        puts "fixture-host"
      else
        puts "fixture-tool 1.0"
      end
    RUBY
    File.chmod(0o755, @tool)
    @mock = File.join(@external, "mock_guard_stage.rb")
    File.write(@mock, <<~'RUBY')
      #!/usr/bin/env ruby
      require "fileutils"
      stage = ENV.fetch("GUARD_STAGE")
      if ENV["GUARD_HANG_STAGE"] == stage
        Signal.trap("TERM", "IGNORE")
        spawn(RbConfig.ruby, "-e", "Signal.trap('TERM', 'IGNORE'); sleep 30")
        sleep 30
      end
      source = File.binread(File.join(ENV.fetch("GUARD_SNAPSHOT"), "self-hosted/quartz.qz"))
      if stage == "gen1" && source.include?("from missing import")
        warn "unknown import"
        exit 1
      end
      case stage
      when "gen1"
        File.binwrite(ENV.fetch("GUARD_GEN1"), "IR:" + source)
      when "candidate"
        File.binwrite(ENV.fetch("GUARD_CANDIDATE"), "candidate:" + source)
        File.chmod(0o755, ENV.fetch("GUARD_CANDIDATE"))
      when "gen2"
        FileUtils.copy_file(ENV.fetch("GUARD_GEN1"), ENV.fetch("GUARD_GEN2"))
      when "debug_verify"
        File.binwrite(ENV.fetch("GUARD_DEBUG"), "DEBUG:" + source)
      end
    RUBY
    File.chmod(0o755, @mock)
    @base_env = {
      "QUARTZ_GUARD_TEST_TRUST_CHECKER" => "1",
      "QUARTZ_GUARD_MOCK_COMMAND" => "#{RbConfig.ruby} #{@mock}",
      "QUARTZ_GUARD_OPT" => @tool,
      "QUARTZ_GUARD_LLC" => @tool,
      "QUARTZ_GUARD_LINKER" => @tool,
      "QUARTZ_GUARD_RECOVERY_SEED" => @recovery,
      "QUARTZ_GUARD_RECOVERY_SEED_SHA256" => Digest::SHA256.file(@recovery).hexdigest,
      "QUARTZ_GUARD_STAGE_TIMEOUT_MS" => "1000"
    }
  end

  def teardown
    FileUtils.rm_rf(@dir)
    FileUtils.rm_rf(@external)
  end

  def test_every_gate_failure_preserves_live_pair_pointer_and_index
    STAGES.each do |stage|
      before = trusted_state
      _out, err, status = guard("run", "staged", "QUARTZ_GUARD_FAIL_STAGE" => stage)
      refute status.success?, "#{stage} unexpectedly passed"
      assert_includes err, stage
      assert_equal before, trusted_state, "#{stage} changed trusted state"
      assert_no_temporary_artifacts
    end
  end

  def test_staged_blob_materialization_ignores_unstaged_and_from_import_is_covered
    write("self-hosted/quartz.qz", "compiler = staged-a\nfrom dep import helper\n")
    stage("self-hosted/quartz.qz")
    write("self-hosted/quartz.qz", "compiler = unstaged-b\nfrom dep import helper\n")
    assert_success guard("run", "staged")
    assert_equal "candidate:compiler = staged-a\nfrom dep import helper\n", read("self-hosted/bin/quartz")
    stage("self-hosted/bin/quartz")
    stage("self-hosted/.fixpoint")

    write("std/dep.qz", "helper = 2\n")
    stage("std/dep.qz")
    _out, err, status = guard("check", "staged")
    refute status.success?
    assert_includes err, "input manifest mismatch"
  end

  def test_partial_staging_is_exact_and_worktree_mode_is_explicit
    write("self-hosted/quartz.qz", "compiler = index-a\n")
    stage("self-hosted/quartz.qz")
    write("self-hosted/quartz.qz", "compiler = worktree-b\n")
    assert_success guard("run", "staged")
    assert_equal "staged", JSON.parse(read("self-hosted/.fixpoint")).fetch("mode")
    assert_success guard("run", "worktree")
    assert_equal "worktree", JSON.parse(read("self-hosted/.fixpoint")).fetch("mode")
    assert_equal "candidate:compiler = worktree-b\n", read("self-hosted/bin/quartz")
  end

  def test_unknown_import_fails_closed_before_publication
    write("self-hosted/quartz.qz", "from missing import value\n")
    stage("self-hosted/quartz.qz")
    before = trusted_state
    _out, err, status = guard("run", "staged")
    refute status.success?
    assert_includes err, "supervised failure"
    assert_equal before, trusted_state
  end

  def test_checked_inventory_rejects_new_tracked_source_until_policy_updates
    write("std/new_dependency.qz", "value = 1\n")
    stage("std/new_dependency.qz")
    assert_failure guard("run", "staged"), "unapproved compiler inputs"
  end

  def test_base_policy_allows_constrained_addition_with_transition_evidence
    write("std/new_dependency.qz", "value = 1\n")
    stage("std/new_dependency.qz")
    set_policy_transition(add: [{ "path" => "std/new_dependency.qz", "mode" => "100644" }])
    assert_success guard("run", "staged")
    evidence = JSON.parse(read("self-hosted/.fixpoint")).fetch("policy_transition")
    assert_equal ["std/new_dependency.qz"], evidence.fetch("add").map { |rule| rule.fetch("path") }
  end

  def test_base_policy_allows_constrained_deletion_but_protects_trust_files
    git("update-index", "--force-remove", "std/dep.qz")
    set_policy_transition(delete: [{ "path" => "std/dep.qz", "mode" => "100644" }])
    assert_success guard("run", "staged")

    setup_protected_delete = [{ "path" => "tools/qspec_supervise.rb", "mode" => "100755" }]
    write_policy
    stage("tools/quartz_guard_inputs.json")
    set_policy_transition(delete: setup_protected_delete)
    assert_failure guard("run", "staged"), "cannot delete protected input"
  end

  def test_staged_symlink_gitlink_and_wrong_executable_mode_are_rejected
    blob = git("hash-object", "-w", "--stdin", stdin_data: "target").strip
    git("update-index", "--cacheinfo", "120000", blob, "self-hosted/quartz.qz")
    assert_failure guard("run", "staged"), "symlink input rejected"

    stage("self-hosted/quartz.qz")
    git("update-index", "--cacheinfo", "100644", git("hash-object", "-w", "--", "self-hosted/bin/quartz").strip, "self-hosted/bin/quartz")
    assert_failure guard("run", "staged"), "expected 100755"

    stage("self-hosted/bin/quartz")
    git("update-index", "--cacheinfo", "160000", git("rev-parse", "HEAD").strip, "std/dep.qz")
    assert_failure guard("run", "staged"), "gitlink input rejected"
  end

  def test_worktree_rejects_symlink_even_when_index_is_regular
    File.delete(File.join(@dir, "std/dep.qz"))
    File.symlink("prelude.qz", File.join(@dir, "std/dep.qz"))
    assert_failure guard("run", "worktree"), "worktree symlink input rejected"
  end

  def test_worktree_rejects_symlinked_parent_directory
    File.rename(File.join(@dir, "std"), File.join(@dir, "std-real"))
    File.symlink("std-real", File.join(@dir, "std"))
    assert_failure guard("run", "worktree"), "symlink parent rejected"
  end

  def test_seed_requires_explicit_recovery_and_detects_corruption
    assert_failure guard("run", "staged", "QUARTZ_GUARD_RECOVERY_SEED" => nil, "QUARTZ_GUARD_RECOVERY_SEED_SHA256" => nil), "no trusted published seed"
    assert_failure guard("run", "staged", "QUARTZ_GUARD_RECOVERY_SEED_SHA256" => "0" * 64), "recovery seed SHA mismatch"
    live = File.join(@dir, "self-hosted/bin/quartz")
    assert_failure guard("run", "staged", "QUARTZ_GUARD_RECOVERY_SEED" => live, "QUARTZ_GUARD_RECOVERY_SEED_SHA256" => Digest::SHA256.file(live).hexdigest), "must not be the installed live compiler"
    File.chmod(0o755, @recovery)
    assert_failure guard("run", "staged"), "recovery seed must be read-only"
    File.chmod(0o555, @recovery)
    assert_success guard("run", "staged")
    artifact_binary = current_artifact_file("quartz")
    File.binwrite(artifact_binary, "corrupt\n")
    File.chmod(0o755, artifact_binary)
    assert_failure guard("run", "staged"), "artifact binary SHA mismatch"
  end

  def test_advisory_lock_excludes_live_owner_but_ignores_stale_metadata
    lock = File.open(File.join(@dir, ".git", "quartz-guard.lock"), File::RDWR | File::CREAT, 0o600)
    lock.flock(File::LOCK_EX | File::LOCK_NB)
    File.write(File.join(@dir, ".git", "quartz-guard.owner.json"), "{\"pid\":4242}\n")
    assert_failure guard("run", "staged"), '"pid":4242'
    lock.flock(File::LOCK_UN)
    lock.close
    assert_success guard("run", "staged")
  end

  def test_crash_after_pointer_is_detected_and_recovered
    assert_success guard("run", "staged")
    write("self-hosted/quartz.qz", "compiler = generation-two\n")
    stage("self-hosted/quartz.qz")
    live_before = read("self-hosted/bin/quartz")
    assert_failure guard("run", "staged", "QUARTZ_GUARD_FAIL_PUBLICATION" => "after-pointer"), "publication crash after pointer"
    assert_equal live_before, read("self-hosted/bin/quartz")
    assert_failure guard("check", "staged"), "interrupted publication detected"
    assert_success guard("recover")
    assert_equal "candidate:compiler = generation-two\n", read("self-hosted/bin/quartz")
  end

  def test_actual_sigkill_after_pointer_is_recovered
    assert_success guard("run", "staged")
    write("self-hosted/quartz.qz", "compiler = sigkill-generation\n")
    stage("self-hosted/quartz.qz")
    env = @base_env.merge("QUARTZ_GUARD_SIGKILL_BOUNDARY" => "after-pointer")
    pid = Process.spawn(env, RbConfig.ruby, GUARD, "run", "staged", chdir: @dir, out: File::NULL, err: File::NULL)
    Process.wait(pid)
    assert $?.signaled? && $?.termsig == Signal.list.fetch("KILL"), "guard was not killed at boundary"
    assert_failure guard("check", "staged"), "interrupted publication detected"
    assert_success guard("recover")
    assert_equal "candidate:compiler = sigkill-generation\n", read("self-hosted/bin/quartz")
    assert_empty Dir.glob(File.join(@dir, "tmp/guard/*"))
  end

  def test_artifact_retention_is_current_plus_one_predecessor
    3.times do |index|
      write("self-hosted/quartz.qz", "compiler = retention-#{index}\n")
      stage("self-hosted/quartz.qz")
      assert_success guard("run", "staged")
    end
    artifacts = Dir.children(File.join(@dir, "self-hosted/.guard/artifacts")).reject { |name| name.start_with?(".tmp-") }
    assert_equal 2, artifacts.length
    pointer = JSON.parse(read("self-hosted/.guard/current"))
    assert_equal artifacts.sort, [pointer.fetch("current"), pointer.fetch("previous")].sort
  end

  def test_independent_reproduction_rejects_forged_binary_and_stamp
    assert_success guard("run", "staged")
    stage("self-hosted/bin/quartz")
    stage("self-hosted/.fixpoint")
    assert_success reproduce("index")

    forged = "forged-binary\n"
    write("self-hosted/bin/quartz", forged, mode: 0o755)
    stage("self-hosted/bin/quartz")
    stamp = JSON.parse(read("self-hosted/.fixpoint"))
    stamp["candidate_sha256"] = Digest::SHA256.hexdigest(forged)
    write("self-hosted/.fixpoint", JSON.generate(stamp) + "\n")
    stage("self-hosted/.fixpoint")
    assert_failure reproduce("index"), "independent candidate binary reproduction mismatch"
  end

  def test_reproduction_never_executes_candidate_supervisor
    marker = File.join(@dir, "candidate-supervisor-executed")
    write("tools/qspec_supervise.rb", "#!/bin/bash\ntouch #{marker}\nexit 0\n", mode: 0o755)
    stage("tools/qspec_supervise.rb")
    assert_success guard("run", "staged")
    stage("self-hosted/bin/quartz")
    stage("self-hosted/.fixpoint")
    assert_failure reproduce("index"), "trust component change lacks exact external approval"
    supervisor_sha = Digest::SHA256.hexdigest(git("show", ":tools/qspec_supervise.rb"))
    rotation = trust_rotation(components: [{ "path" => "tools/qspec_supervise.rb", "mode" => "100755", "sha256" => supervisor_sha }])
    assert_success reproduce("index", rotation)
    refute File.exist?(marker), "candidate supervisor executed"
  end

  def test_checker_takeover_requires_exact_external_rotation
    write("tools/quartz_guard.rb", "#!/usr/bin/env ruby\nexit 0\n", mode: 0o755)
    stage("tools/quartz_guard.rb")
    assert_success guard("run", "staged")
    stage("self-hosted/bin/quartz")
    stage("self-hosted/.fixpoint")
    assert_failure reproduce("index"), "trust component change lacks exact external approval"
    wrong = trust_rotation(components: [{ "path" => "tools/quartz_guard.rb", "mode" => "100755", "sha256" => "0" * 64 }])
    assert_failure reproduce("index", wrong), "trust component change lacks exact external approval"
    checker_sha = Digest::SHA256.hexdigest(git("show", ":tools/quartz_guard.rb"))
    approved = trust_rotation(components: [{ "path" => "tools/quartz_guard.rb", "mode" => "100755", "sha256" => checker_sha }])
    assert_success reproduce("index", approved)
  end

  def test_meta_policy_weakening_requires_approved_full_policy_sha
    policy = JSON.parse(read("tools/quartz_guard_inputs.json"))
    policy["transition"]["protected"] = []
    write("tools/quartz_guard_inputs.json", JSON.pretty_generate(policy) + "\n")
    stage("tools/quartz_guard_inputs.json")
    assert_success guard("run", "staged")
    stage("self-hosted/bin/quartz")
    stage("self-hosted/.fixpoint")
    assert_failure reproduce("index"), "meta-policy change lacks externally approved full policy SHA"
    wrong = trust_rotation(next_policy_sha256: "0" * 64)
    assert_failure reproduce("index", wrong), "meta-policy change lacks externally approved full policy SHA"
    policy_sha = Digest::SHA256.hexdigest(git("show", ":tools/quartz_guard_inputs.json"))
    approved = trust_rotation(next_policy_sha256: policy_sha)
    assert_success reproduce("index", approved)
  end

  def test_candidate_cannot_self_authorize_trust_rotation
    write("tools/quartz_guard.rb", "#!/usr/bin/env ruby\nexit 0\n", mode: 0o755)
    stage("tools/quartz_guard.rb")
    assert_success guard("run", "staged")
    stage("self-hosted/bin/quartz")
    stage("self-hosted/.fixpoint")
    checker_sha = Digest::SHA256.hexdigest(git("show", ":tools/quartz_guard.rb"))
    declared = {
      "schema" => 1,
      "base_policy_sha256" => Digest::SHA256.hexdigest(git("show", "HEAD:tools/quartz_guard_inputs.json")),
      "next_policy_sha256" => nil,
      "components" => [{ "path" => "tools/quartz_guard.rb", "mode" => "100755", "sha256" => checker_sha }]
    }
    write("tools/candidate-trust-rotation.json", JSON.generate(declared) + "\n")
    File.chmod(0o400, File.join(@dir, "tools/candidate-trust-rotation.json"))
    env = {
      "QUARTZ_GUARD_TRUST_ROTATION" => File.join(@dir, "tools/candidate-trust-rotation.json"),
      "QUARTZ_GUARD_TRUST_ROTATION_SHA256" => Digest::SHA256.file(File.join(@dir, "tools/candidate-trust-rotation.json")).hexdigest
    }
    assert_failure reproduce("index", env), "must be outside the candidate repository"
  end

  def test_legacy_bootstrap_reproduction_uses_every_external_pin
    assert_success guard("run", "staged")
    stage("self-hosted/bin/quartz")
    stage("self-hosted/.fixpoint")
    assert_success bootstrap_reproduce("index")
    assert_failure bootstrap_reproduce("index", "QUARTZ_GUARD_LEGACY_POLICY_SHA256" => "0" * 64), "legacy policy SHA mismatch"
    assert_failure bootstrap_reproduce("index", "QUARTZ_GUARD_LEGACY_SUPERVISOR_SHA256" => "0" * 64), "legacy supervisor SHA mismatch"
    assert_failure bootstrap_reproduce("index", "QUARTZ_GUARD_LEGACY_BASE_SEED_SHA256" => "0" * 64), "legacy base seed SHA mismatch"
    assert_failure bootstrap_reproduce("index", "QUARTZ_GUARD_LEGACY_TRUST_SET_SHA256" => "0" * 64), "legacy initial trust set SHA mismatch"
  end

  def test_reproduction_rejects_provenance_tamper_matrix
    assert_success guard("run", "staged")
    stage("self-hosted/bin/quartz")
    original = JSON.parse(read("self-hosted/.fixpoint"))
    mutations = {
      "seed_sha256" => "1" * 64,
      "target" => "forged-host",
      "flags" => ["--no-cache"],
      "toolchain" => original.fetch("toolchain").merge("opt" => original.dig("toolchain", "opt").merge("version" => "forged")),
      "environment" => original.fetch("environment").merge("PATH" => "/forged"),
      "commands" => original.fetch("commands").map.with_index { |record, index| index.zero? ? record.merge("argv" => ["forged"]) : record },
      "input_manifest_sha256" => "2" * 64,
      "source_manifest_sha256" => "3" * 64,
      "stable_ir_sha256" => "4" * 64,
      "validation" => [],
      "policy_transition" => original.fetch("policy_transition").merge("transition_sha256" => "5" * 64)
    }
    mutations.each do |field, value|
      write("self-hosted/.fixpoint", JSON.generate(original.merge(field => value)) + "\n")
      stage("self-hosted/.fixpoint")
      _out, _err, status = reproduce("index")
      refute status.success?, "reproduction accepted tampered #{field}"
    end
  end

  def test_target_relabel_is_rejected
    assert_failure guard("run", "staged", "QUARTZ_GUARD_TARGET" => "x86_64-unknown-linux-gnu"), "unsupported"
  end

  def test_all_structured_stamp_fields_are_enforced
    assert_success guard("run", "staged")
    stage("self-hosted/bin/quartz")
    original = JSON.parse(read("self-hosted/.fixpoint"))
    mutations = {
      "mode" => "worktree", "input_manifest_sha256" => "0" * 64, "seed_sha256" => "1" * 64,
      "target" => "relabeled", "flags" => ["--unsafe"], "toolchain" => {}, "validation" => []
    }
    mutations.each do |field, value|
      write("self-hosted/.fixpoint", JSON.generate(original.merge(field => value)) + "\n")
      stage("self-hosted/.fixpoint")
      _out, _err, status = guard("check", "staged")
      refute status.success?, "tampered #{field} was accepted"
    end
  end

  def test_installed_and_staged_binary_mismatches_are_rejected
    assert_success guard("run", "staged")
    stage("self-hosted/bin/quartz")
    stage("self-hosted/.fixpoint")
    FileUtils.rm_rf(File.join(@dir, "self-hosted/.guard"))
    write("self-hosted/bin/quartz", "corrupt-installed\n", mode: 0o755)
    assert_failure guard("check", "staged"), "installed binary SHA mismatch"
    stage("self-hosted/bin/quartz")
    assert_failure guard("check", "staged"), "index binary SHA mismatch"
  end

  def test_hook_executes_staged_checker_not_unstaged_checker
    marker = File.join(@dir, "hook-marker")
    staged_checker = <<~'RUBY'
      #!/usr/bin/env ruby
      File.write(ENV.fetch("HOOK_MARKER"), File.read(__FILE__))
    RUBY
    write("tools/quartz_guard.rb", staged_checker, mode: 0o755)
    stage("tools/quartz_guard.rb")
    write("tools/quartz_guard.rb", "#!/usr/bin/env ruby\nabort 'unstaged checker ran'\n", mode: 0o755)
    stdout, stderr, status = Open3.capture3({ "HOOK_MARKER" => marker }, "bash", File.join(ROOT, ".githooks/pre-commit"), chdir: @dir)
    refute status.success?, "no-op staged checker bypassed trusted HEAD checker"
    refute File.exist?(marker), "staged no-op checker executed"
    assert_includes stderr, "guard:"
  end

  def test_success_and_failures_leave_index_byte_identical
    before = index_bytes
    assert_success guard("run", "staged")
    assert_equal before, index_bytes
    before = index_bytes
    assert_failure guard("run", "staged", "QUARTZ_GUARD_FAIL_STAGE" => "gen2"), "gen2"
    assert_equal before, index_bytes
  end

  def test_supervisor_times_out_and_reaps_resistant_process_tree
    before = trusted_state
    _out, err, status = guard(
      "run", "staged", "GUARD_HANG_STAGE" => "gen1",
      "QUARTZ_GUARD_STAGE_TIMEOUT_MS" => "100"
    )
    refute status.success?
    assert_includes err, "timeout=1"
    assert_includes err, "orphan=0"
    assert_equal before, trusted_state
  end

  def test_clean_clone_ci_provenance_check
    assert_success guard("run", "staged")
    stage("self-hosted/bin/quartz")
    stage("self-hosted/.fixpoint")
    commit_index
    clone = Dir.mktmpdir("quartz-guard-clean-clone-")
    begin
      stdout, stderr, status = Open3.capture3("git", "clone", "-q", @dir, clone)
      assert status.success?, "clone failed: #{stdout} #{stderr}"
      clone_checker = File.join(clone, "tools/quartz_guard.rb")
      clone_env = @base_env.reject { |key, _value| key == "QUARTZ_GUARD_TEST_TRUST_CHECKER" }
      result = Open3.capture3(clone_env, RbConfig.ruby, clone_checker, "check", "staged", chdir: clone)
      assert_success result
      committed_seed_env = clone_env.reject { |key, _value| key.start_with?("QUARTZ_GUARD_RECOVERY_SEED") }
      result = Open3.capture3(committed_seed_env, RbConfig.ruby, clone_checker, "run", "staged", chdir: clone)
      assert_success result
    ensure
      FileUtils.rm_rf(clone)
    end
  end

  private

  def write_policy
    policy = {
      "schema" => 1,
      "trees" => [
        { "root" => "self-hosted", "suffix" => ".qz", "mode" => "100644" },
        { "root" => "std", "suffix" => ".qz", "mode" => "100644" }
      ],
      "files" => [
        { "path" => "tools/qspec_supervise.rb", "mode" => "100755" },
        { "path" => "tools/quartz_guard.rb", "mode" => "100755" },
        { "path" => "tools/quartz_guard_inputs.json", "mode" => "100644" },
        { "path" => "tools/quartz_guard_policy_transition.json", "mode" => "100644" }
      ],
      "transition" => {
        "path" => "tools/quartz_guard_policy_transition.json",
        "protected" => %w[tools/qspec_supervise.rb tools/quartz_guard.rb tools/quartz_guard_inputs.json tools/quartz_guard_policy_transition.json],
        "roots" => [
          { "root" => "self-hosted", "suffixes" => [".qz"], "mode" => "100644" },
          { "root" => "std", "suffixes" => [".qz"], "mode" => "100644" },
          { "root" => "tools", "suffixes" => [".rb", ".json"], "mode" => "100644" }
        ]
      },
      "meta_policy" => {
        "schema" => 1,
        "transition_authority" => "protected-base-or-pinned-external",
        "trust_components" => [
          { "path" => "tools/quartz_guard.rb", "mode" => "100755", "kind" => "immutable" },
          { "path" => "tools/qspec_supervise.rb", "mode" => "100755", "kind" => "immutable" },
          { "path" => "tools/quartz_guard_inputs.json", "mode" => "100644", "kind" => "policy-meta" }
        ]
      }
    }
    inventory = %w[self-hosted/quartz.qz std/dep.qz std/prelude.qz].to_h { |path| [path, "100644"] }
    inventory["tools/qspec_supervise.rb"] = "100755"
    inventory["tools/quartz_guard.rb"] = "100755"
    inventory["tools/quartz_guard_inputs.json"] = "100644"
    inventory["tools/quartz_guard_policy_transition.json"] = "100644"
    framed = inventory.sort.map { |path, mode| frame("path", path) + frame("mode", mode) }.join
    policy["inventory_sha256"] = Digest::SHA256.hexdigest(framed)
    write("tools/quartz_guard_inputs.json", JSON.pretty_generate(policy) + "\n")
    transition_path = File.join(@dir, "tools/quartz_guard_policy_transition.json")
    unless File.file?(transition_path)
      transition = {
        "schema" => 1, "base_inventory_sha256" => policy["inventory_sha256"],
        "candidate_inventory_sha256" => policy["inventory_sha256"], "add" => [], "delete" => []
      }
      write("tools/quartz_guard_policy_transition.json", JSON.pretty_generate(transition) + "\n")
    end
  end

  def set_policy_transition(add: [], delete: [])
    base_policy = JSON.parse(git("show", "HEAD:tools/quartz_guard_inputs.json"))
    base_inventory = inventory_from_policy(base_policy)
    candidate_inventory = base_inventory.dup
    delete.each { |rule| candidate_inventory.delete(rule.fetch("path")) }
    add.each { |rule| candidate_inventory[rule.fetch("path")] = rule.fetch("mode") }
    candidate_sha = inventory_sha(candidate_inventory)
    candidate_policy = JSON.parse(read("tools/quartz_guard_inputs.json"))
    candidate_policy["inventory_sha256"] = candidate_sha
    write("tools/quartz_guard_inputs.json", JSON.pretty_generate(candidate_policy) + "\n")
    stage("tools/quartz_guard_inputs.json")
    transition = {
      "schema" => 1, "base_inventory_sha256" => base_policy.fetch("inventory_sha256"),
      "candidate_inventory_sha256" => candidate_sha, "add" => add, "delete" => delete
    }
    write("tools/quartz_guard_policy_transition.json", JSON.pretty_generate(transition) + "\n")
    stage("tools/quartz_guard_policy_transition.json")
  end

  def inventory_from_policy(policy)
    entries = git("ls-tree", "-rz", "HEAD").split("\0").filter_map do |record|
      metadata, path = record.split("\t", 2)
      next unless path
      mode = metadata.split.first
      [path, mode] if policy.fetch("trees").any? { |rule| path.start_with?(rule.fetch("root") + "/") && path.end_with?(rule.fetch("suffix")) }
    end.to_h
    policy.fetch("files").each { |rule| entries[rule.fetch("path")] = rule.fetch("mode") }
    entries
  end

  def inventory_sha(entries)
    Digest::SHA256.hexdigest(entries.sort.map { |path, mode| frame("path", path) + frame("mode", mode) }.join)
  end

  def guard(*args)
    extra = args.last.is_a?(Hash) ? args.pop : {}
    env = @base_env.merge(extra.compact)
    extra.each_key { |key| env.delete(key) if extra[key].nil? }
    Open3.capture3(env, RbConfig.ruby, GUARD, *args, chdir: @dir)
  end

  def reproduce(candidate, overrides = {})
    checker = File.join(@external, "trusted-base-checker.rb")
    FileUtils.rm_f(checker)
    File.binwrite(checker, git("show", "HEAD:tools/quartz_guard.rb"))
    File.chmod(0o500, checker)
    env = @base_env.merge(
      "QUARTZ_GUARD_TRUSTED_CHECKER_SHA256" => Digest::SHA256.file(checker).hexdigest,
      "QUARTZ_GUARD_BASE_REF" => "HEAD",
      "QUARTZ_GUARD_BASE_SEED" => @recovery,
      "QUARTZ_GUARD_BASE_SEED_SHA256" => Digest::SHA256.file(@recovery).hexdigest
    ).merge(overrides)
    Open3.capture3(env, RbConfig.ruby, checker, "reproduce", candidate, chdir: @dir)
  end

  def bootstrap_reproduce(candidate, overrides = {})
    checker = File.join(@external, "legacy-checker.rb")
    policy = File.join(@external, "legacy-policy.json")
    supervisor = File.join(@external, "legacy-supervisor.rb")
    [[checker, GUARD], [policy, File.join(@dir, "tools/quartz_guard_inputs.json")], [supervisor, File.join(@dir, "tools/qspec_supervise.rb")]].each do |destination, source|
      FileUtils.rm_f(destination)
      FileUtils.copy_file(source, destination)
      File.chmod(destination == policy ? 0o400 : 0o500, destination)
    end
    trust_set = File.join(@external, "legacy-trust-set.json")
    FileUtils.rm_f(trust_set)
    components = JSON.parse(File.read(policy)).dig("meta_policy", "trust_components").filter_map do |component|
      next if component["kind"] == "policy-meta"
      bytes = git("show", ":#{component.fetch("path")}")
      { "path" => component.fetch("path"), "mode" => component.fetch("mode"), "sha256" => Digest::SHA256.hexdigest(bytes) }
    end
    approval = {
      "schema" => 1, "base_policy_sha256" => Digest::SHA256.file(policy).hexdigest,
      "next_policy_sha256" => Digest::SHA256.file(policy).hexdigest, "components" => components
    }
    File.binwrite(trust_set, JSON.generate(approval) + "\n")
    File.chmod(0o400, trust_set)
    env = @base_env.merge(
      "QUARTZ_GUARD_LEGACY_CHECKER" => checker,
      "QUARTZ_GUARD_LEGACY_CHECKER_SHA256" => Digest::SHA256.file(checker).hexdigest,
      "QUARTZ_GUARD_LEGACY_POLICY" => policy,
      "QUARTZ_GUARD_LEGACY_POLICY_SHA256" => Digest::SHA256.file(policy).hexdigest,
      "QUARTZ_GUARD_LEGACY_SUPERVISOR" => supervisor,
      "QUARTZ_GUARD_LEGACY_SUPERVISOR_SHA256" => Digest::SHA256.file(supervisor).hexdigest,
      "QUARTZ_GUARD_LEGACY_BASE_SEED" => @recovery,
      "QUARTZ_GUARD_LEGACY_BASE_SEED_SHA256" => Digest::SHA256.file(@recovery).hexdigest,
      "QUARTZ_GUARD_LEGACY_TRUST_SET" => trust_set,
      "QUARTZ_GUARD_LEGACY_TRUST_SET_SHA256" => Digest::SHA256.file(trust_set).hexdigest
    ).merge(overrides)
    Open3.capture3(env, RbConfig.ruby, checker, "reproduce-bootstrap", candidate, chdir: @dir)
  end

  def trust_rotation(components: [], next_policy_sha256: nil)
    path = File.join(@external, "trust-rotation-#{SecureRandom.hex(4)}.json")
    base_policy = git("show", "HEAD:tools/quartz_guard_inputs.json")
    approval = {
      "schema" => 1, "base_policy_sha256" => Digest::SHA256.hexdigest(base_policy),
      "next_policy_sha256" => next_policy_sha256, "components" => components
    }
    File.binwrite(path, JSON.generate(approval) + "\n")
    File.chmod(0o400, path)
    {
      "QUARTZ_GUARD_TRUST_ROTATION" => path,
      "QUARTZ_GUARD_TRUST_ROTATION_SHA256" => Digest::SHA256.file(path).hexdigest
    }
  end

  def frame(key, value)
    "#{key.bytesize}:#{key}#{value.bytesize}:#{value}\n"
  end

  def git(*args, env: {}, stdin_data: "")
    stdout, stderr, status = Open3.capture3(env, "git", *args, chdir: @dir, stdin_data: stdin_data)
    raise "git #{args.join(" ")} failed: #{stderr}" unless status.success?
    stdout
  end

  def stage(path, mode: nil)
    absolute = File.join(@dir, path)
    mode ||= File.executable?(absolute) ? "100755" : "100644"
    blob = git("hash-object", "-w", "--", path).strip
    git("update-index", "--add", "--cacheinfo", mode, blob, path)
  end

  def commit_index
    tree = git("write-tree").strip
    env = {
      "GIT_AUTHOR_NAME" => "Guard Test", "GIT_AUTHOR_EMAIL" => "guard@example.invalid",
      "GIT_COMMITTER_NAME" => "Guard Test", "GIT_COMMITTER_EMAIL" => "guard@example.invalid",
      "GIT_AUTHOR_DATE" => "2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE" => "2000-01-01T00:00:00Z"
    }
    parents = git("rev-parse", "--verify", "HEAD", env: env).strip rescue ""
    args = ["commit-tree", tree]
    args += ["-p", parents] unless parents.empty?
    commit = git(*args, env: env, stdin_data: "fixture\n")
    git("update-ref", "HEAD", commit.strip)
  end

  def write(path, contents, mode: nil)
    absolute = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, contents)
    File.chmod(mode, absolute) if mode
  end

  def read(path)
    File.binread(File.join(@dir, path))
  end

  def index_bytes
    File.binread(File.join(@dir, ".git", "index"))
  end

  def trusted_state
    paths = %w[self-hosted/bin/quartz self-hosted/.fixpoint self-hosted/.guard/current]
    result = paths.to_h do |path|
      absolute = File.join(@dir, path)
      [path, File.file?(absolute) ? Digest::SHA256.file(absolute).hexdigest : nil]
    end
    result["index"] = Digest::SHA256.hexdigest(index_bytes)
    result
  end

  def current_artifact_file(name)
    id = JSON.parse(read("self-hosted/.guard/current")).fetch("current")
    File.join(@dir, "self-hosted/.guard/artifacts", id, name)
  end

  def assert_success(result)
    out, err, status = result
    assert status.success?, "command failed:\n#{out}\n#{err}"
  end

  def assert_failure(result, message)
    _out, err, status = result
    refute status.success?, "command unexpectedly passed"
    assert_includes err, message
  end

  def assert_no_temporary_artifacts
    assert_empty Dir.glob(File.join(@dir, "tmp", "guard", "*"))
    assert_empty Dir.glob(File.join(@dir, "self-hosted", ".guard", "artifacts", ".tmp-*"))
  end

end
