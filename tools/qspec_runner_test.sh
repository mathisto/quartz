#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/qspec-runner-test.XXXXXX")
marker="$tmp/recovery.marker"
injected="$tmp/injected"
mutating_source="spec/qspec/runner_fixtures/source_mutating.qz"
mutating_backup="$tmp/source_mutating.qz"
cp "$mutating_source" "$mutating_backup"
cleanup() {
  cp "$mutating_backup" "$mutating_source"
  if [[ ${QSPEC_RUNNER_TEST_KEEP_TMP:-0} == 1 ]]; then
    printf '%s\n' "qspec runner fixture artifacts: $tmp" >&2
  else
    rm -rf "$tmp"
  fi
}
trap cleanup EXIT

cd "$root"

ruby -e 'source = File.read("Quakefile.qz"); abort "supervisor append whole-reads result bytes" if source.match?(/write_file\(record_path,\s*read_file\(record_path\)/); abort "supervisor record does not use append" unless source.include?("file.file_append(record_path,")'
./self-hosted/bin/quake qspec_discovery_contract_test

run_pass() {
  local fixture=$1
  local manifest=$2
  QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE="$fixture" QSPEC_WORKERS=1 QSPEC_PREWARM=0 \
    QSPEC_MANIFEST="$manifest" ./self-hosted/bin/quake qspec >"$manifest.log" 2>&1
}

run_red() {
  local fixture=$1
  local manifest=$2
  if QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE="$fixture" QSPEC_WORKERS=1 QSPEC_PREWARM=0 \
    QSPEC_NO_RETRY=1 QSPEC_MANIFEST="$manifest" ./self-hosted/bin/quake qspec >"$manifest.log" 2>&1; then
    printf '%s\n' "expected red runner fixture to fail: $fixture" >&2
    exit 1
  fi
}

run_retry_red() {
  local fixture=$1
  local manifest=$2
  if QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE="$fixture" QSPEC_WORKERS=1 QSPEC_PREWARM=0 \
    QSPEC_RETRY=1 QSPEC_RECOVERY_MARKER="$marker" QSPEC_MANIFEST="$manifest" \
    ./self-hosted/bin/quake qspec >"$manifest.log" 2>&1; then
    printf '%s\n' "expected retrying runner fixture to remain red: $fixture" >&2
    exit 1
  fi
}

run_pattern_pass() {
  local pattern=$1
  local manifest=$2
  QSPEC_PATTERN="$pattern" QSPEC_WORKERS=1 QSPEC_PREWARM=0 QSPEC_NO_RETRY=1 \
    QSPEC_MANIFEST="$manifest" ./self-hosted/bin/quake qspec >"$manifest.log" 2>&1
}

run_stage_red() {
  local stage=$1
  local fixture=$2
  local manifest=$3
  local mode=${4:-hang}
  local compile_timeout=20
  if [[ $stage == compile ]]; then
    compile_timeout=1
  fi
  if QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE="$fixture" QSPEC_RUNNER_TEST_STAGE="$stage" \
    QSPEC_RUNNER_TEST_MODE="$mode" QSPEC_WORKERS=1 QSPEC_PREWARM=0 QSPEC_NO_RETRY=1 \
    QSPEC_TIMEOUT=1 QSPEC_COMPILE_TIMEOUT="$compile_timeout" QSPEC_TOOL_TIMEOUT=1 QSPEC_MANIFEST="$manifest" \
    ./self-hosted/bin/quake qspec >"$manifest.log" 2>&1; then
    printf '%s\n' "expected supervised stage to time out: $stage" >&2
    exit 1
  fi
}

run_nested_outcome() {
  local mode=$1
  local outcome=$2
  local manifest=$3
  local expected_status=$4
  local missing=${QSPEC_SUB_TEST_MISSING:-$tmp}
  local status=0
  QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE=nested QSPEC_SUB_TEST_STAGE=nested-outcome \
    QSPEC_SUB_TEST_MODE="$mode" QSPEC_SUB_EXPECT_OUTCOME="$outcome" QSPEC_SUB_TEST_MISSING="$missing" \
    QSPEC_SUB_TIMEOUT=1 QSPEC_WORKERS=1 QSPEC_PREWARM=0 QSPEC_NO_RETRY=1 QSPEC_TIMEOUT=8 \
    QSPEC_MANIFEST="$manifest" ./self-hosted/bin/quake qspec >"$manifest.log" 2>&1 || status=$?
  if [[ $expected_status == pass && $status -ne 0 ]]; then
    printf '%s\n' "expected nested outcome to pass: $mode" >&2
    exit 1
  fi
  if [[ $expected_status == red && $status -eq 0 ]]; then
    printf '%s\n' "expected nested outcome to fail gate: $mode" >&2
    exit 1
  fi
}

run_nested_evidence_red() {
  local evidence=$1
  local manifest=$2
  if QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE=nested QSPEC_SUB_TEST_STAGE=nested-ignored \
    QSPEC_SUB_IGNORE_RESULT=1 QSPEC_SUB_TEST_EVIDENCE="$evidence" QSPEC_WORKERS=1 QSPEC_PREWARM=0 QSPEC_NO_RETRY=1 \
    QSPEC_MANIFEST="$manifest" ./self-hosted/bin/quake qspec >"$manifest.log" 2>&1; then
    printf '%s\n' "expected protocol-like nested evidence to fail: $evidence" >&2
    exit 1
  fi
}

run_pass pass "$tmp/pass1.json"
run_pass pass "$tmp/pass2.json"
run_pass nested "$tmp/nested.json"
run_pass nested_concurrent "$tmp/nested_concurrent.json"
run_pass subresult_constructor "$tmp/subresult_constructor.json"
QSPEC_SUB_BULK=1 run_pass nested "$tmp/nested_bulk.json"
run_pass forged_stdout "$tmp/forged_stdout.json"
run_red forged_report "$tmp/forged_report.json"
run_red mixed_schema "$tmp/mixed_schema.json"
run_red legacy_v2 "$tmp/legacy_v2.json"
run_red oversized_result "$tmp/oversized_result.json"
QSPEC_MUTATE_SOURCE=0 run_pass source_mutating "$tmp/source_identity_baseline.json"
expected_source_hash=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("files", 0, "parent_observed", "selection", "selected_pre_execution_content_hash")' "$tmp/source_identity_baseline.json")
QSPEC_MUTATE_SOURCE=1 run_pass source_mutating "$tmp/source_mutating.json"
if cmp -s "$mutating_backup" "$mutating_source"; then
  printf '%s\n' "source-mutating fixture did not alter selected source" >&2
  exit 1
fi
cp "$mutating_backup" "$mutating_source"
for fixture in leading_whitespace trailing_whitespace embedded_marker hidden_v2 unknown_protocol malformed_protocol_line; do
  run_red "$fixture" "$tmp/$fixture.json"
done
run_pass feature_exclusion "$tmp/feature_exclusion.json"
QSPEC_FAST=1 run_pass fast_exclusion "$tmp/fast_exclusion.json"
run_pattern_pass wasm_core_spec "$tmp/wasm_core.json"
run_pattern_pass wasm_data_spec "$tmp/wasm_data.json"
run_pattern_pass wasm_extended_spec "$tmp/wasm_extended.json"
run_pattern_pass wasm_hof_spec "$tmp/wasm_hof.json"
QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE=quarantine QSPEC_SLOW=1 QSPEC_WORKERS=1 QSPEC_PREWARM=0 \
  QSPEC_MANIFEST="$tmp/quarantine.json" ./self-hosted/bin/quake qspec >"$tmp/quarantine.json.log" 2>&1

run_retry_red recovery "$tmp/recovery.json"
run_retry_red persistent_failure "$tmp/persistent_failure.json"
run_red zero "$tmp/zero.json"
run_red missing_metrics "$tmp/missing_metrics.json"
run_red malformed_metrics "$tmp/malformed_metrics.json"
run_red impossible_arithmetic "$tmp/impossible_arithmetic.json"
run_red duplicate_record "$tmp/duplicate_record.json"
run_red arbitrary_exclusion "$tmp/arbitrary_exclusion.json"
run_red exit_mismatch "$tmp/exit_mismatch.json"
run_red spoofed_record "$tmp/spoofed_record.json"
run_red crash "$tmp/crash.json"

run_nested_outcome exit124 exit "$tmp/nested_exit124.json" pass
run_nested_outcome signal2 signal "$tmp/nested_signal.json" red
run_nested_outcome hang timeout "$tmp/nested_timeout.json" red
run_nested_outcome orphan orphan "$tmp/nested_orphan.json" red
run_nested_outcome cancelled cancelled "$tmp/nested_cancelled.json" red
QSPEC_SUB_TEST_MISSING="$tmp" run_nested_outcome spawn-failure spawn_failure "$tmp/nested_spawn_failure.json" red

QSPEC_SUB_CAP=1 run_red nested "$tmp/nested_cap.json"
for evidence in truncated-qsi unknown-qsi truncated-qse unknown-qss; do
  run_nested_evidence_red "$evidence" "$tmp/nested_evidence_${evidence}.json"
done

service_orphan_marker="$tmp/service-death-orphan"
if QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE=nested QSPEC_SUB_TEST_STAGE=nested-outcome \
  QSPEC_SUB_TEST_MODE=service-death QSPEC_SUB_EXPECT_OUTCOME=protocol_failure \
  QSPEC_SUB_TEST_SKIP_SDK=1 QSPEC_SUB_TEST_ORPHAN_MARKER="$service_orphan_marker" \
  QSPEC_SUPERVISOR_TEST_CRASH_BOUNDARY=postclaim QSPEC_SUB_TIMEOUT=5 QSPEC_WORKERS=1 \
  QSPEC_PREWARM=0 QSPEC_NO_RETRY=1 QSPEC_TIMEOUT=8 QSPEC_MANIFEST="$tmp/nested_service_death.json" \
  ./self-hosted/bin/quake qspec >"$tmp/nested_service_death.log" 2>&1; then
  printf '%s\n' "expected dead nested service to fail closed" >&2
  exit 1
fi
sleep 1.2
test ! -e "$service_orphan_marker"

if QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE=nested QSPEC_SUB_TEST_STAGE=nested-ignored \
  QSPEC_SUB_TEST_MODE=signal2 QSPEC_SUB_IGNORE_RESULT=1 QSPEC_WORKERS=1 QSPEC_PREWARM=0 \
  QSPEC_NO_RETRY=1 QSPEC_MANIFEST="$tmp/nested_ignored_signal.json" \
  ./self-hosted/bin/quake qspec >"$tmp/nested_ignored_signal.log" 2>&1; then
  printf '%s\n' "ignored nested signal incorrectly left gate green" >&2
  exit 1
fi

if QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE=nested QSPEC_SUB_TEST_STAGE=nested-ignored \
  QSPEC_SUB_IGNORE_RESULT=1 QSPEC_SUB_TEST_DROP_COMPLETION=1 QSPEC_WORKERS=1 QSPEC_PREWARM=0 \
  QSPEC_NO_RETRY=1 QSPEC_MANIFEST="$tmp/nested_missing_completion.json" \
  ./self-hosted/bin/quake qspec >"$tmp/nested_missing_completion.log" 2>&1; then
  printf '%s\n' "missing nested completion incorrectly left gate green" >&2
  exit 1
fi

ruby tools/qspec_supervisor_test.rb
run_stage_red compile pass "$tmp/supervise_compile.json"
run_stage_red compile pass "$tmp/supervise_compile_signal2.json" signal2
run_stage_red compile pass "$tmp/supervise_compile_signal9.json" signal9
run_stage_red lli pass "$tmp/supervise_lli.json"
run_stage_red llc pass "$tmp/supervise_llc.json"
run_stage_red link pass "$tmp/supervise_link.json"
run_stage_red native-run pass "$tmp/supervise_native_run.json"
run_stage_red native-run pass "$tmp/supervise_exit124.json" exit124
run_stage_red native-run pass "$tmp/supervise_exit130.json" exit130
run_stage_red native-run pass "$tmp/supervise_exit137.json" exit137
run_stage_red native-run pass "$tmp/supervise_signal2.json" signal2
run_stage_red native-run pass "$tmp/supervise_signal9.json" signal9
run_stage_red lli pass "$tmp/supervise_lli_exit130.json" exit130
run_stage_red lli pass "$tmp/supervise_lli_exit137.json" exit137
run_stage_red lli pass "$tmp/supervise_lli_signal2.json" signal2
run_stage_red lli pass "$tmp/supervise_lli_signal9.json" signal9
QSPEC_RUNNER_TEST_MISSING="$tmp" run_stage_red compile pass "$tmp/supervise_spawn_failure.json" spawn-failure

for malformed in numeric boolean bounds combination sentinel fields; do
  manifest="$tmp/malformed_outer_${malformed}.json"
  if QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE=pass QSPEC_RUNNER_TEST_STAGE=compile \
    QSPEC_RUNNER_TEST_STATUS="$malformed" QSPEC_WORKERS=1 QSPEC_PREWARM=0 QSPEC_NO_RETRY=1 \
    QSPEC_MANIFEST="$manifest" ./self-hosted/bin/quake qspec >"$manifest.log" 2>&1; then
    printf '%s\n' "expected malformed outer status rejection: $malformed" >&2
    exit 1
  fi

  nested_manifest="$tmp/malformed_nested_${malformed}.json"
  if QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE=nested QSPEC_SUB_TEST_STAGE=nested-compile \
    QSPEC_SUB_TEST_STATUS="$malformed" QSPEC_WORKERS=1 QSPEC_PREWARM=0 QSPEC_NO_RETRY=1 \
    QSPEC_MANIFEST="$nested_manifest" ./self-hosted/bin/quake qspec >"$nested_manifest.log" 2>&1; then
    printf '%s\n' "expected malformed nested status rejection: $malformed" >&2
    exit 1
  fi
done

for stage in nested-compile nested-llc nested-link nested-validate nested-run; do
  manifest="$tmp/supervise_${stage//-/_}.json"
  if QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE=nested QSPEC_SUB_TEST_STAGE="$stage" \
    QSPEC_SUB_TEST_MODE=hang QSPEC_SUB_TIMEOUT=1 QSPEC_WORKERS=1 QSPEC_PREWARM=0 \
    QSPEC_NO_RETRY=1 QSPEC_TIMEOUT=8 QSPEC_MANIFEST="$manifest" \
    ./self-hosted/bin/quake qspec >"$manifest.log" 2>&1; then
    printf '%s\n' "expected nested supervised stage to fail: $stage" >&2
    exit 1
  fi
done

if QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE=nested QSPEC_SUB_TEST_STAGE=nested-sdk \
  QSPEC_SUB_TEST_MODE=hang QSPEC_SUB_SDK_TIMEOUT=1 QSPEC_WORKERS=1 QSPEC_PREWARM=0 \
  QSPEC_NO_RETRY=1 QSPEC_MANIFEST="$tmp/supervise_nested_sdk.json" \
  ./self-hosted/bin/quake qspec >"$tmp/supervise_nested_sdk.log" 2>&1; then
  printf '%s\n' "expected nested SDK timeout to fail gate" >&2
  exit 1
fi

if QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_TEST_STAGE=compile QSPEC_RUNNER_TEST_MODE=hang \
  QSPEC_COMPILE_TIMEOUT=1 FILE=spec/qspec/runner_fixtures/pass.qz \
  ./self-hosted/bin/quake qspec_file >"$tmp/qspec_file_timeout.log" 2>&1; then
  printf '%s\n' "expected qspec_file compile timeout" >&2
  exit 1
fi

ruby -e '
  env = {
    "QSPEC_RUNNER_TEST" => "1", "QSPEC_RUNNER_TEST_STAGE" => "compile",
    "QSPEC_RUNNER_TEST_MODE" => "hang", "QSPEC_COMPILE_TIMEOUT" => "20",
    "FILE" => "spec/qspec/runner_fixtures/pass.qz",
  }
  log = File.open(ARGV[0], "w")
  pid = Process.spawn(env, "./self-hosted/bin/quake", "qspec_file", out: log, err: log, pgroup: true)
  sleep 0.5
  Process.kill("INT", -pid)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 6
  loop do
    waited = Process.waitpid(pid, Process::WNOHANG)
    break if waited
    abort "interrupted qspec_file did not quiesce" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.05
  end
  log.close
' "$tmp/qspec_file_interrupt.log"

ruby -rjson -e '
  env = {
    "QSPEC_RUNNER_TEST" => "1", "QSPEC_RUNNER_TEST_TWO" => "1",
    "QSPEC_RUNNER_TEST_STAGE" => "compile", "QSPEC_RUNNER_TEST_MODE" => "hang",
    "QSPEC_WORKERS" => "2", "QSPEC_PREWARM" => "0", "QSPEC_NO_RETRY" => "1",
    "QSPEC_COMPILE_TIMEOUT" => "20", "QSPEC_MANIFEST" => ARGV[0],
  }
  log = File.open(ARGV[1], "w")
  pid = Process.spawn(env, "./self-hosted/bin/quake", "qspec", out: log, err: log, pgroup: true)
  sleep 0.8
  Process.kill("INT", -pid)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 7
  loop do
    waited = Process.waitpid(pid, Process::WNOHANG)
    break if waited
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      Process.kill("KILL", -pid) rescue nil
      abort "two-stage cancellation did not quiesce"
    end
    sleep 0.05
  end
  log.close
  manifest = JSON.parse(File.read(ARGV[0]))
  abort "cancel manifest not red" unless manifest["gate_result"] == "failed"
  results = manifest.fetch("files").map { |file| file.fetch("runner_evaluated").fetch("initial_result") }
  abort "partial/unrun cancellation records missing" unless results.include?("unrun") || results.include?("cancelled")
' "$tmp/two_cancel.json" "$tmp/two_cancel.log"

ruby -rjson -e '
  expected = {
    "supervise_compile.json" => "COMPILE TIMEOUT",
    "supervise_lli.json" => "TIMEOUT",
    "supervise_llc.json" => "LLC TIMEOUT",
    "supervise_link.json" => "LINK TIMEOUT",
    "supervise_native_run.json" => "TIMEOUT",
  }
  expected.each do |file, reason|
    manifest = JSON.parse(File.read(File.join(ARGV[0], file)))
    parent = manifest.dig("files", 0, "parent_observed")
    abort "#{file}: wrong timeout stage" unless manifest.dig("files", 0, "runner_evaluated", "reason").include?(reason)
    abort "#{file}: timeout not recorded" unless parent.dig("stage_status", "timed_out")
  end
  [124, 130, 137].each do |code|
    manifest = JSON.parse(File.read(File.join(ARGV[0], "supervise_exit#{code}.json")))
    parent = manifest.dig("files", 0, "parent_observed")
    record = manifest.dig("files", 0, "test_reported", "shared_protocol", "supervision").find { |line| line.split("\t")[1] == "native-run" }
    abort "normal #{code} status misclassified" unless record && record.split("\t")[4] == code.to_s && record.split("\t")[5] == "0" && record.split("\t")[6] == "0"
    abort "normal #{code} inferred as signal" unless parent.dig("stage_status", "signal") == 0
    abort "normal #{code} manifest timeout flag" if parent.dig("stage_status", "timed_out")
  end
  [2, 9].each do |signal|
    manifest = JSON.parse(File.read(File.join(ARGV[0], "supervise_signal#{signal}.json")))
    parent = manifest.dig("files", 0, "parent_observed")
    record = manifest.dig("files", 0, "test_reported", "shared_protocol", "supervision").find { |line| line.split("\t")[1] == "native-run" }
    abort "true signal #{signal} missing from status" unless record && record.split("\t")[5] == signal.to_s
    abort "true signal #{signal} missing from manifest" unless parent.dig("stage_status", "signal") == signal
  end
  [2, 9].each do |signal|
    manifest = JSON.parse(File.read(File.join(ARGV[0], "supervise_compile_signal#{signal}.json")))
    parent = manifest.dig("files", 0, "parent_observed")
    record = manifest.dig("files", 0, "test_reported", "shared_protocol", "supervision").find { |line| line.split("\t")[1] == "compile" }
    abort "compile signal #{signal} missing from QSS2" unless record && record.split("\t")[5] == signal.to_s
    abort "compile signal #{signal} missing from aggregate" unless parent.dig("stage_status", "signal") == signal
  end
  [130, 137].each do |code|
    manifest = JSON.parse(File.read(File.join(ARGV[0], "supervise_lli_exit#{code}.json")))
    parent = manifest.dig("files", 0, "parent_observed")
    record = manifest.dig("files", 0, "test_reported", "shared_protocol", "supervision").find { |line| line.split("\t")[1] == "lli" }
    abort "lli normal #{code} status misclassified" unless record && record.split("\t")[4] == code.to_s && record.split("\t")[5] == "0"
    abort "lli normal #{code} inferred as signal" unless parent.dig("stage_status", "signal") == 0
  end
  [2, 9].each do |signal|
    manifest = JSON.parse(File.read(File.join(ARGV[0], "supervise_lli_signal#{signal}.json")))
    abort "lli true signal #{signal} missing" unless manifest.dig("files", 0, "parent_observed", "stage_status", "signal") == signal
  end
  spawn_failure = JSON.parse(File.read(File.join(ARGV[0], "supervise_spawn_failure.json")))
  abort "spawn error not classified" unless spawn_failure.dig("files", 0, "runner_evaluated", "reason").include?("ENOENT")
  %w[nested_compile nested_llc nested_link nested_validate nested_run].each do |suffix|
    manifest = JSON.parse(File.read(File.join(ARGV[0], "supervise_#{suffix}.json")))
    stage = suffix.tr("_", "-")
    record = manifest.dig("files", 0, "test_reported", "shared_protocol", "supervision").find { |line| line.split("\t")[1] == stage }
    abort "#{stage}: missing nested classification" unless record && record.split("\t")[6] == "1"
  end
  sdk = JSON.parse(File.read(File.join(ARGV[0], "supervise_nested_sdk.json")))
  sdk_record = sdk.dig("files", 0, "test_reported", "shared_protocol", "supervision").find { |line| line.split("\t")[1] == "nested-sdk" }
  abort "SDK timeout missing" unless sdk_record && sdk_record.split("\t")[6] == "1"
  abort "SDK probe escaped secure root" unless Dir.glob("/tmp/_qspec_sdk_*").empty?
  Dir.glob("tmp/qspec-runs/run.*/work/*").each { |path| abort "run work leaked: #{path}" }
' "$tmp"

if QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE="pass;touch $injected" QSPEC_WORKERS=1 QSPEC_PREWARM=0 \
  QSPEC_MANIFEST="$tmp/injection.json" ./self-hosted/bin/quake qspec >"$tmp/injection.json.log" 2>&1; then
  printf '%s\n' "expected injection-shaped fixture selector to fail" >&2
  exit 1
fi
test ! -e "$injected"

if QSPEC_PATTERN=__qspec_runner_empty_filter__ QSPEC_MANIFEST="$tmp/empty_filter.json" \
  ./self-hosted/bin/quake qspec >"$tmp/empty_filter.json.log" 2>&1; then
  printf '%s\n' "expected empty filter to fail" >&2
  exit 1
fi

printf '%s\n' "retained sentinel" >"$tmp/retained_conflict.json"
if QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE=pass QSPEC_WORKERS=1 QSPEC_PREWARM=0 \
  QSPEC_MANIFEST="$tmp/retained_conflict.json" ./self-hosted/bin/quake qspec >"$tmp/retained_conflict.log" 2>&1; then
  printf '%s\n' "expected retained manifest conflict to fail" >&2
  exit 1
fi
test "$(cat "$tmp/retained_conflict.json")" = "retained sentinel"
ruby -e 'log = File.read(ARGV[0]); path = log[%r{tmp/qspec-runs/run\.[A-Za-z0-9]+/manifest\.json}]; abort "missing run manifest path" unless path; abort "retained-conflict run directory leaked" if File.exist?(File.dirname(path))' \
  "$tmp/retained_conflict.log"

cat >"$tmp/public_api_probe.qz" <<'QZ'
import * from qspec
def main(): Int
  qspec_emit_machine_result()
  qspec_emit_harness_pass()
  return qspec_main_without_result()
end
QZ
if ./self-hosted/bin/quartz --no-cache -I std -I . "$tmp/public_api_probe.qz" >"$tmp/public_api_probe.ll" 2>"$tmp/public_api_probe.err"; then
  printf '%s\n' "synthetic result APIs remain publicly callable" >&2
  exit 1
fi
ruby -e 'e = File.read(ARGV[0]); %w[qspec_emit_machine_result qspec_emit_harness_pass qspec_main_without_result].each { |name| abort "missing private API rejection: #{name}" unless e.include?(name) }' "$tmp/public_api_probe.err"

# A dead, old lock can be atomically displaced; a live owner's lock is retained.
stale_history="$tmp/stale_durations.tsv"
mkdir "$stale_history.lock"
ruby -e 'File.write(ARGV[0], "999999\t#{(Time.now.to_f * 1000).to_i - 1000}\tstale-token\told-start\n")' "$stale_history.lock/owner"
QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE=pass QSPEC_WORKERS=1 QSPEC_PREWARM=0 \
  QSPEC_DURATIONS_PATH="$stale_history" QSPEC_DURATION_LOCK_STALE_MS=100 \
  QSPEC_MANIFEST="$tmp/stale_lock.json" ./self-hosted/bin/quake qspec >"$tmp/stale_lock.log" 2>&1
test -f "$stale_history"
test ! -e "$stale_history.lock"

live_history="$tmp/live_durations.tsv"
sleep 5 &
live_owner=$!
mkdir "$live_history.lock"
ruby -e 'start = `ps -o lstart= -p #{ARGV[1]}`.strip; File.write(ARGV[0], "#{ARGV[1]}\t#{(Time.now.to_f * 1000).to_i - 1000}\tlive-token\t#{start}\n")' "$live_history.lock/owner" "$live_owner"
QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE=pass QSPEC_WORKERS=1 QSPEC_PREWARM=0 \
  QSPEC_DURATIONS_PATH="$live_history" QSPEC_DURATION_LOCK_STALE_MS=100 QSPEC_DURATION_LOCK_ATTEMPTS=2 \
  QSPEC_MANIFEST="$tmp/live_lock.json" ./self-hosted/bin/quake qspec >"$tmp/live_lock.log" 2>&1
test -d "$live_history.lock"
kill "$live_owner" 2>/dev/null || true
wait "$live_owner" 2>/dev/null || true
rm -rf "$live_history.lock"

reused_history="$tmp/reused_durations.tsv"
sleep 5 &
reused_owner=$!
mkdir "$reused_history.lock"
ruby -e 'File.write(ARGV[0], "#{ARGV[1]}\t#{(Time.now.to_f * 1000).to_i - 1000}\treused-token\tdifferent-process-start\n")' "$reused_history.lock/owner" "$reused_owner"
QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE=pass QSPEC_WORKERS=1 QSPEC_PREWARM=0 \
  QSPEC_DURATIONS_PATH="$reused_history" QSPEC_DURATION_LOCK_STALE_MS=100 \
  QSPEC_MANIFEST="$tmp/reused_lock.json" ./self-hosted/bin/quake qspec >"$tmp/reused_lock.log" 2>&1
test ! -e "$reused_history.lock"
kill "$reused_owner" 2>/dev/null || true
wait "$reused_owner" 2>/dev/null || true

# Deliberate bounded concurrency: two runs prewarm independently while merging
# distinct duration keys into one history file.
duration_history="$tmp/concurrent_durations.tsv"
QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE=pass QSPEC_WORKERS=1 QSPEC_DURATIONS_PATH="$duration_history" QSPEC_DURATION_LOCK_HOLD_MS=200 \
  QSPEC_MANIFEST="$tmp/concurrent_a.json" ./self-hosted/bin/quake qspec >"$tmp/concurrent_a.log" 2>&1 &
pid_a=$!
QSPEC_RUNNER_TEST=1 QSPEC_RUNNER_FIXTURE=forged_stdout QSPEC_WORKERS=1 QSPEC_DURATIONS_PATH="$duration_history" QSPEC_DURATION_LOCK_HOLD_MS=200 \
  QSPEC_MANIFEST="$tmp/concurrent_b.json" ./self-hosted/bin/quake qspec >"$tmp/concurrent_b.log" 2>&1 &
pid_b=$!
status_a=0
status_b=0
wait "$pid_a" || status_a=$?
wait "$pid_b" || status_b=$?
test "$status_a" -eq 0
test "$status_b" -eq 0
ruby -e '
  logs = ARGV.take(2).map { |path| File.read(path) }
  caches = logs.map { |log| log[%r{tmp/qspec-runs/run\.[A-Za-z0-9]+/cache}] }
  abort "missing run-local cache path" if caches.any?(&:nil?)
  abort "concurrent runs shared a cache" unless caches.uniq.length == 2
  abort "run-owned cache was not cleaned" if caches.any? { |path| File.exist?(path) }
  rows = File.readlines(ARGV.fetch(2), chomp: true).map { |line| line.split("\t", -1) }
  abort "duration history malformed" unless rows.all? { |row| row.length == 2 && row[1].match?(/\A\d+\z/) }
  names = rows.map(&:first)
  abort "concurrent duration merge lost entries" unless names.include?("pass") && names.include?("forged_stdout")
' "$tmp/concurrent_a.log" "$tmp/concurrent_b.log" "$duration_history"

if compgen -G "$tmp/*.tmp.*" >/dev/null; then
  printf '%s\n' "manifest temporary file leaked" >&2
  exit 1
fi

QSPEC_EXPECTED_SOURCE_HASH="$expected_source_hash" ruby tools/qspec_runner_manifest_test.rb "$tmp"

ruby -e '
  paths = %w[std/qspec/subprocess.qz spec/qspec/wasm_core_spec.qz spec/qspec/wasm_hof_spec.qz]
  offenders = paths.select { |path| File.read(path).match?(/\bsystem\s*\(/) }
  abort "shell-backed payload launch remains in supervised QSpec core/HOF paths: #{offenders.join(", ")}" unless offenders.empty?
  supervisor = File.read("tools/qspec_supervise.rb")
  abort "payload argv is not executed directly" unless supervisor.include?("exec(*request[:argv])")
  abort "service launch is not argv-based Process.spawn" unless supervisor.include?("Process.spawn(RbConfig.ruby, File.expand_path(__FILE__), \"--serve\"")
  quake = File.read("Quakefile.qz")
  abort "outer shell-backed launch blocker disappeared without an argv primitive" unless quake.include?(%q[posix_spawn_wait("ruby tools/qspec_supervise.rb #{command_path} #{status_path}")])
'

ruby -rdigest -e '
  contract = File.readlines("tools/spec/qspec-main-identities.txt", chomp: true)
  quarantined = %w[actor_spec actor_supervisor_spec backpressure_spec barrier_spec broadcast_channel_spec buffered_net_spec https_spec macro_hygiene_spec tls_spec]
  discovered = Dir["spec/qspec/*_spec.qz"].reject { |path| quarantined.include?(File.basename(path, ".qz")) }.sort
  abort "identity manifest digest changed" unless Digest::SHA256.file("tools/spec/qspec-main-identities.txt").hexdigest == "21fb2c2a22b1d2ad87bf3d3ad3059b0d544f29074aea9dbb36c751706279ccd1"
  frozen = "spec/qspec/_stress_large_program_spec.qz"
  abort "identity manifest is not 903 unique sorted portable paths" unless contract.length == 903 && contract == contract.sort && contract.uniq == contract && contract.all? { |path| path == frozen || path.match?(%r{\Aspec/qspec/[A-Za-z0-9][A-Za-z0-9_-]*_spec\.qz\z}) }
  abort "current main-lane discovery differs from exact identity manifest" unless discovered == contract
  wasm = %w[wasm_core wasm_data wasm_extended wasm_hof].map { |name| "spec/qspec/#{name}_spec.qz" }
  abort "registered WASM exclusions are absent from selected identities" unless (wasm - contract).empty?
'
