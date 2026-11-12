#!/usr/bin/env ruby

require "json"

abort "usage: qspec_runner_manifest_test.rb DIR" unless ARGV.length == 1
dir = ARGV.fetch(0)

def load_manifest(dir, name)
  JSON.parse(File.read(File.join(dir, "#{name}.json")))
end

def assert(condition, message)
  abort "manifest assertion failed: #{message}" unless condition
end

names = %w[pass1 pass2 nested nested_concurrent subresult_constructor nested_bulk nested_cap nested_exit124 nested_signal nested_timeout nested_orphan nested_cancelled nested_spawn_failure nested_ignored_signal nested_missing_completion nested_service_death nested_evidence_truncated-qsi nested_evidence_unknown-qsi nested_evidence_truncated-qse nested_evidence_unknown-qss forged_stdout forged_report mixed_schema legacy_v2 oversized_result source_mutating leading_whitespace trailing_whitespace embedded_marker hidden_v2 unknown_protocol malformed_protocol_line feature_exclusion fast_exclusion wasm_core wasm_data wasm_extended wasm_hof quarantine recovery persistent_failure zero missing_metrics malformed_metrics impossible_arithmetic duplicate_record arbitrary_exclusion exit_mismatch spoofed_record crash injection empty_filter concurrent_a concurrent_b]
manifests = names.to_h { |name| [name, load_manifest(dir, name)] }
pass1 = manifests.fetch("pass1")
pass2 = manifests.fetch("pass2")

parent = ->(manifest) { manifest.dig("files", 0, "parent_observed") }
reported = ->(manifest) { manifest.dig("files", 0, "test_reported", "metrics") }
shared = ->(manifest) { manifest.dig("files", 0, "test_reported", "shared_protocol") }
evaluated = ->(manifest) { manifest.dig("files", 0, "runner_evaluated") }
parent_total = ->(manifest, key) { manifest.dig("totals", "parent_observed", key) }
reported_total = ->(manifest, key) { manifest.dig("totals", "test_reported", key) }
evaluated_total = ->(manifest, key) { manifest.dig("totals", "runner_evaluated", key) }
protocol_total = ->(manifest, key) { manifest.dig("totals", "test_reported", "shared_protocol", key) }

expected_top_keys = %w[schema evidence_contract run_id gate_result duration_ms worker_count worker_mode cache_mode publication_error selection totals files]
expected_file_keys = %w[file parent_observed test_reported runner_evaluated]
assert(pass1.keys == expected_top_keys, "stable top-level schema order")
assert(pass1.fetch("files").first.keys == expected_file_keys, "stable file schema order")
assert(pass1.fetch("schema") == "quartz.qspec.run/v3", "schema version")
assert(pass1.dig("evidence_contract", "parent_observed") == "raw parent and supervisor facts only", "parent authority contract")
assert(pass1.dig("evidence_contract", "test_reported").include?("arbitrary test code shares"), "self-report threat model")
assert(pass1.dig("evidence_contract", "runner_evaluated").include?("depends on test_reported"), "combined classification contract")
assert(pass1.fetch("gate_result") == "passed", "normal pass is green")
assert(reported.call(pass1).fetch("authority") == "test_reported", "case aggregates are self-report")
assert(reported.call(pass1).fetch("cases") == 1, "pass case count")
assert(reported.call(pass1).fetch("case_failures") == 0, "case failures separated")
assert(reported.call(pass1).fetch("framework_failures") == 0, "framework failures separated")
assert(!parent.call(pass1).fetch("selection", {}).fetch("selected_pre_execution_content_hash", "").empty?, "parent records selected pre-execution content hash")
assert((parent.call(pass1).keys & %w[initial_result final_result reason]).empty?, "parent contains no evaluated classifications")
assert(!parent.call(pass1).dig("compiler", "path").empty?, "parent records compiler path")
assert(manifests.dig("nested", "gate_result") == "passed", "normal nested pipeline passes")
assert(pass1.dig("selection", "expected_discovery", "enforced") == false, "fixture run does not enforce main-lane discovery")
stages = shared.call(manifests.fetch("nested")).fetch("supervision").map { |line| line.split("\t")[1] }
%w[compile llc link native-run nested-sdk nested-compile nested-llc nested-link nested-run nested-validate].each do |stage|
  assert(stages.include?(stage), "nested manifest preserves #{stage}")
end
assert(shared.call(manifests.fetch("nested")).fetch("supervision").all? { |line| line.end_with?("trusted-test-no-setsid:qsc3-pgid-anchor:detached-unknown") }, "threat-model limitation recorded")
assert(protocol_total.call(manifests.fetch("nested"), "nested_stages_issued") == protocol_total.call(manifests.fetch("nested"), "nested_stages_recorded"), "nested stages reconcile exactly")
assert(protocol_total.call(manifests.fetch("nested"), "nested_stage_reconciliation_errors") == 0, "normal nested evidence reconciles")
assert(manifests.dig("nested_concurrent", "gate_result") == "passed", "concurrent nested calls pass")
assert(protocol_total.call(manifests.fetch("nested_concurrent"), "nested_stages_issued") == protocol_total.call(manifests.fetch("nested_concurrent"), "nested_stages_recorded"), "concurrent nested calls retain every record")
assert(protocol_total.call(manifests.fetch("nested_concurrent"), "nested_stages_issued") >= 8, "concurrent nested calls were all issued")
assert(manifests.dig("subresult_constructor", "gate_result") == "passed", "three-field SubResult constructor compiles and keeps defaults")
assert(manifests.dig("nested_bulk", "gate_result") == "passed", "greater-than-64 nested stages pass")
assert(protocol_total.call(manifests.fetch("nested_bulk"), "nested_stages_issued") > 64, "stage evidence is not truncated at 64")
assert(protocol_total.call(manifests.fetch("nested_bulk"), "nested_stages_issued") == protocol_total.call(manifests.fetch("nested_bulk"), "nested_stages_recorded"), "bulk nested stages reconcile exactly")

exit124 = manifests.fetch("nested_exit124")
assert(exit124.fetch("gate_result") == "passed", "normal exit 124 remains distinct from timeout")
assert(protocol_total.call(exit124, "nested_stage_timeouts") == 0, "normal exit 124 is not a timeout")
assert(protocol_total.call(exit124, "nested_stage_signals") == 0, "normal exit 124 is not a signal")
{
  "nested_signal" => "nested_stage_signals",
  "nested_timeout" => "nested_stage_timeouts",
  "nested_orphan" => "nested_stage_orphans",
  "nested_cancelled" => "nested_stage_cancelled",
  "nested_spawn_failure" => "nested_stage_spawn_failures",
}.each do |name, counter|
  assert(manifests.dig(name, "gate_result") == "failed", "#{name} is gate-fatal")
  assert(protocol_total.call(manifests.fetch(name), counter) > 0, "#{name} structured counter")
end
assert(protocol_total.call(manifests.fetch("nested_timeout"), "nested_stage_signals") == 0, "timeout escalation is not counted as a program signal")
assert(shared.call(manifests.fetch("nested_timeout")).dig("summary", "nested_signals") == 0, "timeout identity is exclusive")
cap = manifests.fetch("nested_cap")
assert(cap.fetch("gate_result") == "failed", "nested stage overflow is gate-fatal")
assert(protocol_total.call(cap, "nested_stages_issued") == 4096, "budget is enforced before QSI publication")
assert(protocol_total.call(cap, "nested_stage_overflows") == 1, "one bounded overflow marker is retained")
assert(protocol_total.call(cap, "nested_stage_reconciliation_errors") == 1, "overflow contributes exactly one reconciliation error")
assert(manifests.dig("nested_service_death", "gate_result") == "failed", "dead nested service fails closed")
assert(protocol_total.call(manifests.fetch("nested_service_death"), "nested_stage_reconciliation_errors") > 0, "dead service leaves explicit unreconciled evidence")
%w[truncated-qsi unknown-qsi truncated-qse unknown-qss].each do |kind|
  manifest = manifests.fetch("nested_evidence_#{kind}")
  assert(manifest.fetch("gate_result") == "failed", "#{kind} protocol-like evidence is gate-fatal")
  assert(protocol_total.call(manifest, "nested_stage_reconciliation_errors") > 0, "#{kind} is strictly classified malformed")
end
assert(manifests.dig("nested_ignored_signal", "gate_result") == "failed", "ignored abnormal SubResult remains gate-red")
assert(evaluated.call(manifests.fetch("nested_ignored_signal")).fetch("initial_result") == "passed", "ignored-result fixture itself passed")
assert(protocol_total.call(manifests.fetch("nested_ignored_signal"), "nested_stage_signals") == 1, "ignored signal evidence retained")
assert(manifests.dig("nested_missing_completion", "gate_result") == "failed", "missing nested completion fails closed")
assert(protocol_total.call(manifests.fetch("nested_missing_completion"), "nested_stage_reconciliation_errors") > 0, "missing nested completion is reconciled exactly")

assert(manifests.dig("forged_stdout", "gate_result") == "passed", "forged stdout ignored")
forged = manifests.fetch("forged_report")
assert(forged.fetch("gate_result") == "failed", "valid-credential forged report cannot override parent exit")
assert(reported.call(forged).fetch("assertions") == 999, "forged bytes are retained as test-reported")
assert(reported.call(forged).keys == %w[authority cases passed case_failures framework_failures pending skipped assertions duration_us], "self-report cannot contain process or selection facts")
assert(evaluated.call(forged).fetch("initial_result") == "failed", "runner evaluation remains red")
assert(evaluated.call(forged).fetch("depends_on_test_reported"), "combined result marks test-report dependency")
forged_stage = parent.call(forged).fetch("stage_status")
assert(forged_stage.fetch("exit_code") == 23, "parent records actual exit 23")
assert(forged_stage.fetch("signal") == 0 && !forged_stage.fetch("timed_out"), "forged report cannot override signal/timeout")
assert(!forged_stage.fetch("orphan"), "forged report cannot override orphan facts")
assert(parent.call(forged).dig("selection", "source_path").end_with?("forged_report.qz"), "forged report cannot override selection")
assert(evaluated.call(manifests.fetch("mixed_schema")).fetch("reason") == "mixed qspec result schemas", "mixed V2/V3 fails closed")
assert(evaluated.call(manifests.fetch("legacy_v2")).fetch("reason") == "unsupported qspec result schema", "V2 is rejected where V3 is required")
assert(evaluated.call(manifests.fetch("oversized_result")).fetch("reason") == "qspec result file exceeds 4194304 byte limit", "result bound enforced before parse")
%w[leading_whitespace trailing_whitespace embedded_marker hidden_v2 unknown_protocol malformed_protocol_line].each do |name|
  assert(evaluated.call(manifests.fetch(name)).fetch("reason") == "malformed qspec protocol line", "#{name} is strictly rejected")
end
mutation = manifests.fetch("source_mutating")
assert(parent.call(mutation).dig("selection", "selected_pre_execution_content_hash") == ENV.fetch("QSPEC_EXPECTED_SOURCE_HASH"), "selection identity uses pre-execution bytes")
assert(manifests.dig("recovery", "gate_result") == "failed", "recovery remains red")
if ENV["QSPEC_NO_RETRY"] == "1"
  assert(evaluated_total.call(manifests.fetch("recovery"), "recoveries") == 0, "no-retry gate did not recover")
  assert(evaluated.call(manifests.fetch("recovery")).fetch("final_result") == "failed", "no-retry initial failure retained")
else
  assert(evaluated_total.call(manifests.fetch("recovery"), "recoveries") == 1, "recovery counted")
  assert(evaluated.call(manifests.fetch("recovery")).fetch("final_result") == "recovered", "recovery classified")
end

persistent = manifests.fetch("persistent_failure")
expected_persistent = ENV["QSPEC_NO_RETRY"] == "1" ? "failed" : "persistent_failure"
assert(evaluated.call(persistent).fetch("final_result") == expected_persistent, "persistent failure classified")
assert(parent.call(persistent).fetch("output").include?("persistent initial output sentinel"), "initial output retained")
if ENV["QSPEC_NO_RETRY"] != "1"
  assert(evaluated.call(persistent).dig("retry_result", "output").include?("persistent initial output sentinel"), "retry output retained separately")
end

assert(reported_total.call(manifests.fetch("zero"), "zero_case_files") == 1, "zero-case counted")
assert(evaluated.call(manifests.fetch("missing_metrics")).fetch("reason") == "missing qspec result record", "missing record fails closed")
assert(evaluated.call(manifests.fetch("malformed_metrics")).fetch("reason") == "malformed qspec metrics", "malformed record fails closed")
assert(evaluated.call(manifests.fetch("impossible_arithmetic")).fetch("reason") == "malformed qspec metrics", "impossible arithmetic rejected")
assert(evaluated.call(manifests.fetch("duplicate_record")).fetch("reason") == "duplicate qspec metrics", "duplicate record rejected")
assert(evaluated.call(manifests.fetch("exit_mismatch")).fetch("reason") == "qspec result/exit mismatch", "process exit consistency enforced")
assert(evaluated.call(manifests.fetch("spoofed_record")).fetch("reason") == "malformed qspec metrics", "identity-spoofed record rejected")
assert(parent.call(manifests.fetch("crash")).dig("stage_status", "signal") == 11, "crash signal recorded")

feature = manifests.fetch("feature_exclusion")
assert(feature.fetch("gate_result") == "passed", "allowlisted feature exclusion is structured")
assert(%w[lli native-run].include?(parent.call(feature).dig("stage_status", "stage")), "feature exclusion retains raw supervisor stage")
assert(feature.dig("selection", "skipped") == ["feature_exclusion"], "feature exclusion listed")
fast = manifests.fetch("fast_exclusion")
assert(fast.fetch("gate_result") == "passed", "fast exclusion is structured")
assert(parent.call(fast).fetch("stage_status").nil?, "fast exclusion publishes execution stage as unobserved")
assert(evaluated.call(fast).fetch("initial_result") == "skipped", "fast exclusion classification is runner-evaluated")
assert(evaluated.call(fast).fetch("reason") == "fast-mode exclusion", "fast exclusion reason is runner-evaluated")
assert(shared.call(fast).fetch("supervision").any? { |line| line.split("\t")[1] == "compile" }, "fast exclusion retains compile supervision separately")
%w[wasm_core wasm_data wasm_extended wasm_hof].each do |name|
  manifest = manifests.fetch(name)
  assert(manifest.fetch("gate_result") == "passed", "#{name} exclusion accepted")
  assert(%w[lli native-run].include?(parent.call(manifest).dig("stage_status", "stage")), "#{name} exclusion raw stage")
  assert(evaluated.call(manifest).fetch("reason").include?("wasm backend feature"), "#{name} exclusion reason")
end
assert(evaluated.call(manifests.fetch("arbitrary_exclusion")).fetch("reason").include?("unregistered feature exclusion"), "arbitrary exclusion rejected")

quarantine = manifests.fetch("quarantine")
assert(quarantine.dig("selection", "quarantine_inventory").include?("quarantine"), "quarantine inventory listed")
assert(quarantine.dig("selection", "quarantine_selected") == ["quarantine"], "quarantine selected separately")
assert(quarantine.dig("selection", "quarantine_excluded") == [], "selected quarantine not excluded")

assert(manifests.dig("injection", "gate_result") == "failed", "injection-shaped selector rejected")
assert(manifests.dig("injection", "selection", "excluded", 0, "reason").include?("strict allowlist"), "selector rejection reason")
assert(manifests.dig("empty_filter", "gate_result") == "failed", "empty filter publishes failed manifest")
assert(parent_total.call(manifests.fetch("empty_filter"), "selected_files") == 0, "empty selection retained")
excluded_names = manifests.dig("empty_filter", "selection", "excluded").map { |entry| entry.fetch("file") }
assert(excluded_names == excluded_names.sort, "excluded files are deterministic")
%w[concurrent_a concurrent_b].each do |name|
  assert(manifests.dig(name, "gate_result") == "passed", "#{name} concurrent run passed")
  assert(manifests.dig(name, "cache_mode") == "prewarm-read-only", "#{name} used its run-local cache")
end

normalize = lambda do |value|
  case value
  when Hash
    value.each_with_object({}) do |(key, child), out|
      next if %w[run_id duration_ms duration_us].include?(key)
      out[key] = normalize.call(child)
    end
  when Array
    value.map { |child| normalize.call(child) }
  when String
    if value.start_with?("QSS2\t")
      fields = value.split("\t", -1)
      fields[9] = "<elapsed>"
      fields.join("\t")
    else
      value
    end
  else
    value
  end
end
assert(normalize.call(pass1) == normalize.call(pass2), "deterministic manifest content")

puts "qspec runner adversarial fixtures: PASS"
