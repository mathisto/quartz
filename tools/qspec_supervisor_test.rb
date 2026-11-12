#!/usr/bin/env ruby

require "tmpdir"

ROOT = File.expand_path("..", __dir__)
SUPERVISOR = File.join(ROOT, "tools/qspec_supervise.rb")

def field(value)
  value = value.to_s.b
  "#{value.bytesize}\n#{value}\n"
end

def write_request(path, stage:, argv:, timeout_ms: 1_000, grace_ms: 200, env: {}, stdout: "", stderr: "", merge: false, cancel: "")
  body = +"QSP2\n"
  [stage, timeout_ms, grace_ms, "", stdout, stderr, merge ? 1 : 0, cancel, File.dirname(path)].each { |value| body << field(value) }
  body << "#{argv.length}\n"
  argv.each { |value| body << field(value) }
  body << "#{env.length}\n"
  env.each { |key, value| body << field(key) << field(value) }
  File.write(path, body, mode: "wb")
end

def run_stage(dir, stage, argv, **options)
  request_path = File.join(dir, "#{stage}.request")
  status_path = File.join(dir, "#{stage}.status")
  write_request(request_path, stage: stage, argv: argv, **options)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  system("ruby", SUPERVISOR, request_path, status_path)
  abort "#{stage}: supervisor publication failed" unless $?.success?
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  [File.read(status_path).split("\t", -1), elapsed]
end

def assert_status(fields, stage)
  abort "#{stage}: malformed status" unless fields.length == 13 && fields[0] == "QSS2" && fields[1] == stage
  abort "#{stage}: containment limitation missing" unless fields[12].strip == "trusted-test-no-setsid:qsc3-pgid-anchor:detached-unknown"
  fields
end

def ready(dir)
  fields = File.read(File.join(dir, ".qspec-supervisor.ready")).strip.split("\t", -1)
  abort "malformed service ready record" unless fields.length == 7 && fields[0] == "QSR2"
  { pid: Integer(fields[1]), owner: Integer(fields[3]), token: fields[5], raw: fields.join("\t") }
end

def ensure_service(dir, owner = Process.pid)
  system("ruby", SUPERVISOR, "--ensure-service", dir, owner.to_s, out: File::NULL, err: File::NULL)
  abort "service ensure failed" unless $?.success?
  ready(dir)
end

def queue_stage(dir, service, id, stage, argv, expires_ms: nil, cancel: "", **options)
  request = File.join(dir, "#{id}.request")
  status = File.join(dir, "#{id}.status")
  queue = File.join(dir, "#{id}.queue")
  write_request(request, stage: stage, argv: argv, cancel: cancel, **options)
  submitted = (Time.now.to_f * 1_000).to_i
  expires_ms ||= submitted + 5_000
  body = +"QSQ2\n"
  [id, service[:token], submitted, expires_ms, request, status].each { |value| body << field(value) }
  tmp = "#{queue}.tmp"
  File.write(tmp, body, mode: "wb")
  File.rename(tmp, queue)
  [request, status, queue]
end

def wait_status(path, timeout: 5)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  until File.exist?(path)
    abort "status publication timed out: #{path}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.001
  end
  File.read(path).split("\t", -1)
end

def stop_service(service)
  Process.kill("TERM", service[:pid]) rescue nil
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
  while Process.kill(0, service[:pid]) == 1
    break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.01
  end
rescue Errno::ESRCH
  nil
end

def wait_process_gone(pid, timeout: 3)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    Process.kill(0, pid)
    abort "process #{pid} did not exit" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.005
  rescue Errno::ESRCH
    return
  end
end

def wait_claim(queue, timeout: 3)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    claim = Dir["#{queue}.claim.*"].first
    return claim if claim
    abort "claim publication timed out: #{queue}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.005
  end
end

def kill_group(pgid)
  Process.kill("KILL", -pgid)
rescue Errno::ESRCH
  nil
ensure
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
  begin
    while Process.kill(0, -pgid) == 1
      abort "test cleanup left process group #{pgid}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.005
    end
  rescue Errno::ESRCH
    nil
  end
end

Dir.mktmpdir("qspec-supervisor-test.") do |dir|
  resistant = ["ruby", "-e", "Signal.trap('TERM', 'IGNORE'); spawn('ruby', '-e', \"Signal.trap('TERM', 'IGNORE'); sleep 30\"); sleep 30"]
  %w[compile llc link lli native-run qspec-file nested-sdk nested-compile nested-llc nested-link nested-validate nested-run].each do |stage|
    fields, elapsed = run_stage(dir, stage, resistant)
    assert_status(fields, stage)
    abort "#{stage}: expected authoritative timeout: #{fields.inspect}" unless fields[6] == "1" && fields[7] == "1" && fields[8] == "1"
    abort "#{stage}: timeout exposed supervisor escalation as program signal" unless fields[4] == "-1" && fields[5] == "0"
    abort "#{stage}: orphan remained" unless fields[10] == "0"
    abort "#{stage}: teardown exceeded bound" unless elapsed < 4
  end

  [124, 130, 137].each do |code|
    fields, = run_stage(dir, "normal-#{code}", ["ruby", "-e", "exit #{code}"])
    assert_status(fields, "normal-#{code}")
    abort "normal exit #{code} misclassified" unless fields[4] == code.to_s && fields[5] == "0" && fields[6] == "0"
  end

  { 2 => "INT", 9 => "KILL" }.each do |number, name|
    signal_log = File.join(dir, "signal-#{number}.err")
    fields, = run_stage(dir, "signal-#{number}", ["ruby", "-e", "Process.kill('#{name}', Process.pid)"], stderr: signal_log)
    abort "signal #{number} was lost" unless assert_status(fields, "signal-#{number}")[5] == number.to_s && fields[4] == "-1"
  end

  crash_log = File.join(dir, "crash.err")
  fields, = run_stage(dir, "crash", ["ruby", "-e", "Process.kill('SEGV', Process.pid)"], stderr: crash_log)
  abort "crash signal was lost" unless assert_status(fields, "crash")[5] == "11"

  fields, = run_stage(dir, "spawn-failure", [File.join(dir, "missing-executable")])
  abort "spawn failure missing: #{fields.inspect}" unless assert_status(fields, "spawn-failure")[3].include?("ENOENT") && fields[4] == "-1"

  ENV["QSPEC_SUPERVISOR_TEST_EPERM_AFTER_REAP"] = "1"
  fields, = run_stage(dir, "post-reap-eperm", ["ruby", "-e", "exit 0"])
  ENV.delete("QSPEC_SUPERVISOR_TEST_EPERM_AFTER_REAP")
  abort "post-reap EPERM was treated as an owned live group" unless fields[4] == "0" && fields[7] == "0" && fields[8] == "0" && fields[10] == "0"

  missing_status = File.join(dir, "missing-request.status")
  system("ruby", SUPERVISOR, File.join(dir, "absent.request"), missing_status)
  missing_fields = File.read(missing_status).split("\t", -1)
  abort "request read error was not recorded" unless missing_fields[3].include?("ENOENT")

  escape_request = File.join(dir, "escape.request")
  escape_status = File.join(dir, "escape.status")
  escaped_output = File.join(File.dirname(dir), "qspec-supervisor-escaped")
  write_request(escape_request, stage: "containment", argv: ["ruby", "-e", "puts 'bad'"], stdout: escaped_output)
  system("ruby", SUPERVISOR, escape_request, escape_status)
  escape_fields = assert_status(File.read(escape_status).split("\t", -1), "containment")
  abort "redirection escape was accepted" unless escape_fields[3].include?("escapes owner root")
  abort "escaped output was created" if File.exist?(escaped_output)

  outside = File.join(File.dirname(dir), "qspec-supervisor-symlink-target")
  File.write(outside, "sentinel")
  linked_output = File.join(dir, "linked.out")
  File.symlink(outside, linked_output)
  fields, = run_stage(dir, "final-symlink", ["ruby", "-e", "puts 'overwrite'"], stdout: linked_output)
  abort "final output symlink was accepted" unless fields[3].include?("symlink")
  abort "final output symlink target changed" unless File.read(outside) == "sentinel"

  linked_secure = File.join(dir, "linked.result")
  File.symlink(outside, linked_secure)
  system("ruby", SUPERVISOR, "--secure-file", linked_secure, dir, out: File::NULL, err: File::NULL)
  abort "result symlink was accepted" if $?.success?
  abort "result symlink target changed" unless File.read(outside) == "sentinel"
  File.delete(outside)

  injected = File.join(dir, "injected")
  payload = ";touch #{injected}"
  output = File.join(dir, "argv.out")
  fields, = run_stage(dir, "argv-literal", ["ruby", "-e", "File.write(ARGV[1], ARGV[0])", payload, output])
  abort "literal argv was altered" unless fields[4] == "0" && File.read(output) == payload
  abort "argv injection executed" if File.exist?(injected)

  cancel = File.join(dir, "cancel")
  request = File.join(dir, "cancel.request")
  status = File.join(dir, "cancel.status")
  write_request(request, stage: "cancel", argv: resistant, timeout_ms: 20_000, grace_ms: 200, cancel: cancel)
  supervisor = Process.spawn("ruby", SUPERVISOR, request, status)
  sleep 0.2
  File.write(cancel, "cancel\n")
  Process.wait(supervisor)
  fields = assert_status(File.read(status).split("\t", -1), "cancel")
  abort "cancel was not authoritative" unless fields[11] == "1" && fields[10] == "0"
  abort "cancel exposed supervisor escalation as program outcome" unless fields[4] == "-1" && fields[5] == "0"

  # The outer transaction must allow a nested supervisor to reap its distinct
  # child group before escalation kills the nested supervisor itself.
  escaped_marker = File.join(dir, "escaped-grandchild")
  inner_request = File.join(dir, "nested-inner.request")
  inner_status = File.join(dir, "nested-inner.status")
  nested_child = [
    "ruby", "-e",
    "Signal.trap('TERM', 'IGNORE'); spawn('ruby', '-e', \"sleep 1.5; File.write(ARGV[0], 'escaped')\", ARGV[0]); sleep 30",
    escaped_marker,
  ]
  write_request(inner_request, stage: "nested-run", argv: nested_child, timeout_ms: 20_000, grace_ms: 200)
  fields, elapsed = run_stage(
    dir,
    "nested-parent",
    ["ruby", SUPERVISOR, inner_request, inner_status],
    timeout_ms: 300,
    grace_ms: 3_000,
  )
  assert_status(fields, "nested-parent")
  abort "nested parent timeout was not authoritative: #{fields.inspect}" unless fields[6] == "1" && fields[10] == "0"
  abort "nested cleanup exceeded outer bound" unless elapsed < 5
  inner_fields = assert_status(File.read(inner_status).split("\t", -1), "nested-run")
  abort "nested child group was not cancelled and reaped" unless inner_fields[11] == "1" && inner_fields[10] == "0"
  sleep 1.6
  abort "nested grandchild escaped outer cancellation" if File.exist?(escaped_marker)

  unrelated_marker = File.join(dir, "unrelated")
  unrelated = Process.spawn("ruby", "-e", "sleep 2; File.write(ARGV[0], 'alive')", unrelated_marker)
  run_stage(dir, "isolation", resistant)
  Process.wait(unrelated)
  abort "unrelated process was killed" unless File.exist?(unrelated_marker)

  [false, true].each do |resistant_grandchild|
    mode = resistant_grandchild ? "resistant" : "compliant"
    command = if resistant_grandchild
      ["ruby", "-e", "spawn('ruby', '-e', \"Signal.trap('TERM', 'IGNORE'); sleep 30\"); exit 0"]
    else
      ["ruby", "-e", "spawn('ruby', '-e', 'sleep 30'); exit 0"]
    end
    fields, elapsed = run_stage(dir, "leader-exit-#{mode}", command, timeout_ms: 2_000, grace_ms: 100)
    assert_status(fields, "leader-exit-#{mode}")
    abort "leader-exit #{mode} group was not contained" unless fields[4] == "0" && fields[10] == "0"
    abort "leader-exit #{mode} cleanup exceeded bound" unless elapsed < 4
  end

  detached_pid_path = File.join(dir, "detached.pid")
  detached_command = [
    "ruby", "-e",
    "pid = fork { Process.setsid; File.write(ARGV[0], Process.pid.to_s); sleep 30 }; sleep 0.3; exit 0",
    detached_pid_path,
  ]
  detached_fields, = run_stage(dir, "observed-detachment", detached_command, timeout_ms: 2_000, grace_ms: 100)
  assert_status(detached_fields, "observed-detachment")
  abort "observed setsid descendant was not gate-fatal" unless detached_fields[10] == "1" && detached_fields[3].include?("detached")
  detached_pid = Integer(File.read(detached_pid_path))
  Process.kill("KILL", detached_pid) rescue nil
  wait_process_gone(detached_pid)

  threads = 2.times.map do |index|
    Thread.new { run_stage(dir, "concurrent-#{index}", ["ruby", "-e", "sleep 0.2"], timeout_ms: 2_000).first[4] }
  end
  abort "concurrent supervisors interfered" unless threads.map(&:value) == ["0", "0"]


  truncated_request = File.join(dir, "truncated.request")
  truncated_status = File.join(dir, "truncated.status")
  File.write(truncated_request, "QSP2\n4\noops", mode: "wb")
  system("ruby", SUPERVISOR, truncated_request, truncated_status)
  truncated = assert_status(File.read(truncated_status).split("\t", -1), "protocol")
  abort "protocol error deadline was invalid" unless truncated[2] == "1" && !truncated[3].empty?

  service_dir = File.join(dir, "service")
  Dir.mkdir(service_dir)
  services = 5.times.flat_map do
    6.times.map { Thread.new { ensure_service(service_dir) } }.map(&:value)
  end
  abort "repeated ensure started multiple services" unless services.map { |item| item[:raw] }.uniq.length == 1
  service = services.first

  service_truncated_request = File.join(service_dir, "service-truncated.request")
  service_truncated_status = File.join(service_dir, "service-truncated.status")
  File.write(service_truncated_request, "QSP2\n4\noops", mode: "wb")
  submitted = (Time.now.to_f * 1_000).to_i
  service_truncated_queue = File.join(service_dir, "service-truncated.queue")
  body = +"QSQ2\n"
  ["service-truncated", service[:token], submitted, submitted + 5_000, service_truncated_request, service_truncated_status].each { |value| body << field(value) }
  File.write("#{service_truncated_queue}.tmp", body, mode: "wb")
  File.rename("#{service_truncated_queue}.tmp", service_truncated_queue)
  service_truncated = assert_status(wait_status(service_truncated_status), "protocol")
  abort "service protocol error deadline invalid" unless service_truncated[2] == "1" && !service_truncated[3].empty?

  once_marker = File.join(service_dir, "once.marker")
  _, once_status, = queue_stage(service_dir, service, "once", "service-once", ["ruby", "-e", "File.open(ARGV[0], 'a') { |f| f.puts('run') }", once_marker])
  once = assert_status(wait_status(once_status), "service-once")
  abort "service request failed" unless once[4] == "0"
  abort "service request executed more than once" unless File.readlines(once_marker).length == 1

  precancel_marker = File.join(service_dir, "precancel.marker")
  cancel = File.join(service_dir, "cancel")
  File.write(cancel, "cancel\n")
  _, precancel_status, = queue_stage(service_dir, service, "precancel", "precancel", ["ruby", "-e", "File.write(ARGV[0], 'bad')", precancel_marker], cancel: cancel)
  precancel = assert_status(wait_status(precancel_status), "precancel")
  abort "pre-cancel was not refused before spawn" unless precancel[11] == "1" && precancel[7] == "0" && precancel[3].include?("before request claim")
  abort "pre-cancelled command ran" if File.exist?(precancel_marker)

  expired_marker = File.join(service_dir, "expired.marker")
  _, expired_status, = queue_stage(service_dir, service, "expired", "expired", ["ruby", "-e", "File.write(ARGV[0], 'bad')", expired_marker], expires_ms: 1)
  expired = assert_status(wait_status(expired_status), "expired")
  abort "expired queue request ran" unless expired[11] == "1" && expired[3].include?("expired") && !File.exist?(expired_marker)

  concurrent = 12.times.map do |index|
    Thread.new do
      _, status, = queue_stage(service_dir, service, "client-#{index}", "client-#{index}", ["/usr/bin/true"])
      assert_status(wait_status(status), "client-#{index}")[4]
    end
  end
  abort "concurrent clients crossed responses" unless concurrent.map(&:value) == Array.new(12, "0")

  rss_before = `ps -o rss= -p #{service[:pid]}`.to_i
  1_000.times do |index|
    request, status, = queue_stage(service_dir, service, "scale-#{index}", "scale-#{index}", ["/usr/bin/true"])
    fields = assert_status(wait_status(status), "scale-#{index}")
    abort "scale request failed" unless fields[4] == "0"
    File.delete(request, status)
  end
  rss_after = `ps -o rss= -p #{service[:pid]}`.to_i
  abort "service RSS grew without bound: #{rss_before} -> #{rss_after} KiB" if rss_after - rss_before > 20_000
  claim_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
  sleep 0.005 while !Dir[File.join(service_dir, "*.{queue,claim.*}")].empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < claim_deadline
  abort "queue or claim leaked" unless Dir[File.join(service_dir, "*.{queue,claim.*}")].empty?

  old_pid = service[:pid]
  Process.kill("KILL", old_pid)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
  sleep 0.01 while Process.kill(0, old_pid) == 1 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline rescue nil
  restarted = ensure_service(service_dir)
  abort "stale ready did not restart service" if restarted[:pid] == old_pid
  _, restart_status, = queue_stage(service_dir, restarted, "restart", "restart", ["/usr/bin/true"])
  abort "restarted service failed request" unless assert_status(wait_status(restart_status), "restart")[4] == "0"
  stop_service(restarted)

  owner_dir = File.join(dir, "owner-death")
  Dir.mkdir(owner_dir)
  owner = Process.spawn("ruby", "-e", "sleep 30")
  owner_service = ensure_service(owner_dir, owner)
  escaped = File.join(owner_dir, "escaped")
  _, owner_status, = queue_stage(owner_dir, owner_service, "owner-active", "owner-active", ["ruby", "-e", "Signal.trap('TERM', 'IGNORE'); spawn('ruby', '-e', \"sleep 1; File.write(ARGV[0], 'escaped')\", ARGV[0]); sleep 30", escaped], timeout_ms: 20_000, grace_ms: 200)
  sleep 0.1
  Process.kill("KILL", owner)
  Process.wait(owner)
  owner_fields = assert_status(wait_status(owner_status), "owner-active")
  abort "owner death did not cancel active stage" unless owner_fields[11] == "1" && owner_fields[7] == "1" && owner_fields[10] == "0"
  sleep 1.2
  abort "owner-death grandchild escaped" if File.exist?(escaped)

  claim_dir = File.join(dir, "claim")
  Dir.mkdir(claim_dir)
  ENV["QSPEC_SUPERVISOR_TEST_CLAIM_DELAY_MS"] = "150"
  claim_service = ensure_service(claim_dir)
  ENV.delete("QSPEC_SUPERVISOR_TEST_CLAIM_DELAY_MS")
  claim_marker = File.join(claim_dir, "claim.marker")
  _, claim_status, claim_queue = queue_stage(claim_dir, claim_service, "claim-race", "claim-race", ["ruby", "-e", "File.write(ARGV[0], 'bad')", claim_marker])
  sleep 0.03
  stolen = "#{claim_queue}.stolen"
  File.rename(claim_queue, stolen)
  sleep 0.25
  abort "failed queue claim still executed" if File.exist?(claim_status) || File.exist?(claim_marker)
  stop_service(claim_service)

  %w[preclaim spawn postclaim].each do |boundary|
    crash_dir = File.join(dir, "crash-#{boundary}")
    Dir.mkdir(crash_dir)
    ENV["QSPEC_SUPERVISOR_TEST_CRASH_BOUNDARY"] = boundary
    crash_service = ensure_service(crash_dir)
    ENV.delete("QSPEC_SUPERVISOR_TEST_CRASH_BOUNDARY")
    starts = File.join(crash_dir, "starts")
    completions = File.join(crash_dir, "completions")
    command = [
      "ruby", "-e",
      "File.open(ARGV[0], 'a') { |f| f.puts('start') }; sleep 2; File.open(ARGV[1], 'a') { |f| f.puts('complete') }",
      starts, completions,
    ]
    request, status, queue = queue_stage(crash_dir, crash_service, "crash-#{boundary}", "crash-#{boundary}", command, timeout_ms: 10_000, grace_ms: 100)
    wait_process_gone(crash_service[:pid])
    system("ruby", SUPERVISOR, "--recover-claim", crash_dir, queue, status, "crash-#{boundary}", "10000", out: File::NULL, err: File::NULL)
    recovery = $?.exitstatus
    if boundary == "preclaim"
      abort "preclaim was not safely retryable" unless recovery == 0 && File.exist?(queue)
      File.delete(queue)
      replacement = ensure_service(crash_dir)
      _, retry_status, = queue_stage(crash_dir, replacement, "retry-preclaim", "crash-preclaim", command, timeout_ms: 10_000, grace_ms: 100)
      abort "preclaim retry failed" unless assert_status(wait_status(retry_status), "crash-preclaim")[4] == "0"
      stop_service(replacement)
      abort "preclaim retry execution count changed" unless File.readlines(starts).length == 1 && File.readlines(completions).length == 1
    elsif boundary == "spawn"
      abort "spawn uncertainty was not fail-closed" unless recovery == 21
      fields = assert_status(wait_status(status), "crash-spawn")
      abort "spawn uncertainty was not indeterminate" unless fields[10] == "1" && (fields[3].include?("uncertainty") || fields[3].include?("malformed claim"))
      abort "blocked spawn executed" if File.exist?(starts) || File.exist?(completions)
    else
      abort "active claim was not recovered" unless recovery == 20
      fields = assert_status(wait_status(status), "crash-postclaim")
      abort "active recovery was not controlled failure" unless fields[10] == "0" && fields[3].include?("QSC3 publication")
      abort "postclaim start count changed" unless File.readlines(starts).length == 1
      abort "postclaim command completed after recovery" if File.exist?(completions)
    end
  end

  quarantine_dir = File.join(dir, "legacy-qsc2")
  Dir.mkdir(quarantine_dir)
  stale_status = File.join(quarantine_dir, "stale.status")
  stale_claim = File.join(quarantine_dir, "stale.queue.claim.999999.abcdef12")
  stale_fields = ["QSC2", "stale", "999999", "dead-start", "0" * 32, "stale-stage", "1000", "100", stale_status, "active", "999998", "dead-child", "trusted-test-no-setsid:pgid-contained-detached-unknown"]
  File.write(stale_claim, stale_fields.join("\t") + "\n", mode: "wb")
  system("ruby", SUPERVISOR, "--recover-claim", quarantine_dir, stale_claim.sub(/\.claim\..*/, ""), stale_status, "stale-stage", "1000", out: File::NULL, err: File::NULL)
  abort "legacy QSC2 claim did not fail closed" unless $?.exitstatus == 21
  stale_fields = assert_status(wait_status(stale_status), "stale-stage")
  abort "legacy QSC2 migration was not explicit" unless stale_fields[10] == "1" && stale_fields[3].include?("unsupported legacy QSC2")
  abort "legacy QSC2 claim was mutated" unless File.exist?(stale_claim)
  system("ruby", SUPERVISOR, "--ensure-service", quarantine_dir, Process.pid.to_s, out: File::NULL, err: File::NULL)
  abort "replacement accepted legacy QSC2 claim" if $?.success?

  [["ensure-postclaim", false], ["concurrent-postclaim", true]].each do |name, concurrent|
    recovery_dir = File.join(dir, name)
    Dir.mkdir(recovery_dir)
    ENV["QSPEC_SUPERVISOR_TEST_CRASH_BOUNDARY"] = "postclaim"
    crashed_service = ensure_service(recovery_dir)
    ENV.delete("QSPEC_SUPERVISOR_TEST_CRASH_BOUNDARY")
    starts = File.join(recovery_dir, "starts")
    completions = File.join(recovery_dir, "completions")
    command = ["ruby", "-e", "File.open(ARGV[0], 'a') { |f| f.puts('start') }; sleep 2; File.open(ARGV[1], 'a') { |f| f.puts('complete') }", starts, completions]
    _, status, queue = queue_stage(recovery_dir, crashed_service, name, name, command, timeout_ms: 10_000, grace_ms: 100)
    wait_process_gone(crashed_service[:pid])
    replacement = nil
    if concurrent
      ensure_thread = Thread.new { ensure_service(recovery_dir) }
      recover_thread = Thread.new do
        system("ruby", SUPERVISOR, "--recover-claim", recovery_dir, queue, status, name, "10000", out: File::NULL, err: File::NULL)
        $?.exitstatus
      end
      replacement = ensure_thread.value
      abort "concurrent recover was not idempotent" unless recover_thread.value == 20
    else
      replacement = ensure_service(recovery_dir)
    end
    fields = assert_status(wait_status(status), name)
    abort "replacement did not publish indeterminate recovery" unless fields[10] == "0" && fields[3].include?("indeterminate:")
    abort "replacement replayed active request" unless File.readlines(starts).length == 1 && !File.exist?(completions)
    quarantined_claim = Dir[File.join(recovery_dir, "*.claim.*.quarantine.*")].first or abort "recovered claim was not quarantined"
    child_pid = Integer(File.read(quarantined_claim).split("\t", -1)[10])
    begin
      Process.kill(0, -child_pid)
      abort "recovered child PGID remained live"
    rescue Errno::ESRCH
      nil
    end
    stop_service(replacement)
  end

  postreap_dir = File.join(dir, "crash-postreap")
  Dir.mkdir(postreap_dir)
  ENV["QSPEC_SUPERVISOR_TEST_CRASH_BOUNDARY"] = "postreap"
  postreap_service = ensure_service(postreap_dir)
  ENV.delete("QSPEC_SUPERVISOR_TEST_CRASH_BOUNDARY")
  _, postreap_status, postreap_queue = queue_stage(
    postreap_dir, postreap_service, "postreap", "postreap",
    ["ruby", "-e", "spawn('ruby', '-e', \"Signal.trap('TERM', 'IGNORE'); sleep 30\"); exit 0"],
    timeout_ms: 10_000, grace_ms: 100,
  )
  wait_process_gone(postreap_service[:pid])
  system("ruby", SUPERVISOR, "--recover-claim", postreap_dir, postreap_queue, postreap_status, "postreap", "10000", out: File::NULL, err: File::NULL)
  abort "post-leader-reap live group was not recovered" unless $?.exitstatus == 20
  postreap = assert_status(wait_status(postreap_status), "postreap")
  abort "post-leader-reap recovery left an orphan" unless postreap[10] == "0" && postreap[3].include?("without direct-child reap")

  mismatch_dir = File.join(dir, "anchor-mismatch")
  Dir.mkdir(mismatch_dir)
  ENV["QSPEC_SUPERVISOR_TEST_CRASH_BOUNDARY"] = "postclaim"
  mismatch_service = ensure_service(mismatch_dir)
  ENV.delete("QSPEC_SUPERVISOR_TEST_CRASH_BOUNDARY")
  survivor = File.join(mismatch_dir, "survivor")
  _, mismatch_status, mismatch_queue = queue_stage(mismatch_dir, mismatch_service, "anchor-mismatch", "anchor-mismatch", ["ruby", "-e", "sleep 1; File.write(ARGV[0], 'alive'); sleep 30", survivor], timeout_ms: 10_000, grace_ms: 100)
  wait_process_gone(mismatch_service[:pid])
  mismatch_claim = wait_claim(mismatch_queue)
  mismatch_fields = File.read(mismatch_claim).strip.split("\t", -1)
  mismatch_pgid = Integer(mismatch_fields[10])
  mismatch_fields[15] = "1.1"
  File.write(mismatch_claim, mismatch_fields.join("\t") + "\n", mode: "wb")
  system("ruby", SUPERVISOR, "--recover-claim", mismatch_dir, mismatch_queue, mismatch_status, "anchor-mismatch", "10000", out: File::NULL, err: File::NULL)
  abort "anchor birth mismatch did not refuse signaling" unless $?.exitstatus == 21
  mismatch = assert_status(wait_status(mismatch_status), "anchor-mismatch")
  abort "anchor mismatch was not gate-fatal" unless mismatch[10] == "1" && mismatch[7] == "0" && mismatch[8] == "0" && mismatch[3].include?("anchor identity")
  sleep 1.1
  abort "anchor mismatch recovery signaled the live group" unless File.exist?(survivor)
  kill_group(mismatch_pgid)

  race_dir = File.join(dir, "anchor-race")
  Dir.mkdir(race_dir)
  ENV["QSPEC_SUPERVISOR_TEST_CRASH_BOUNDARY"] = "postclaim"
  race_service = ensure_service(race_dir)
  ENV.delete("QSPEC_SUPERVISOR_TEST_CRASH_BOUNDARY")
  _, race_status, race_queue = queue_stage(race_dir, race_service, "anchor-race", "anchor-race", ["ruby", "-e", "sleep 30"], timeout_ms: 10_000, grace_ms: 100)
  wait_process_gone(race_service[:pid])
  race_claim = wait_claim(race_queue)
  race_pgid = Integer(File.read(race_claim).split("\t", -1)[10])
  ENV["QSPEC_SUPERVISOR_TEST_RECOVERY_ANCHOR_RACE"] = "term"
  system("ruby", SUPERVISOR, "--recover-claim", race_dir, race_queue, race_status, "anchor-race", "10000", out: File::NULL, err: File::NULL)
  ENV.delete("QSPEC_SUPERVISOR_TEST_RECOVERY_ANCHOR_RACE")
  abort "anchor death race did not fail closed" unless $?.exitstatus == 21
  race = assert_status(wait_status(race_status), "anchor-race")
  abort "anchor death race sent a group signal" unless race[10] == "1" && race[7] == "0" && race[8] == "0"
  kill_group(race_pgid)

  survivor_dir = File.join(dir, "postkill-survivor")
  Dir.mkdir(survivor_dir)
  ENV["QSPEC_SUPERVISOR_TEST_CRASH_BOUNDARY"] = "postclaim"
  survivor_service = ensure_service(survivor_dir)
  ENV.delete("QSPEC_SUPERVISOR_TEST_CRASH_BOUNDARY")
  _, survivor_status, survivor_queue = queue_stage(survivor_dir, survivor_service, "postkill-survivor", "postkill-survivor", ["ruby", "-e", "Signal.trap('TERM', 'IGNORE'); sleep 30"], timeout_ms: 10_000, grace_ms: 100)
  wait_process_gone(survivor_service[:pid])
  unrelated_recovery_marker = File.join(survivor_dir, "unrelated-alive")
  unrelated_recovery = Process.spawn("ruby", "-e", "sleep 1; File.write(ARGV[0], 'alive')", unrelated_recovery_marker)
  ENV["QSPEC_SUPERVISOR_TEST_POSTKILL_SURVIVOR"] = "1"
  system("ruby", SUPERVISOR, "--recover-claim", survivor_dir, survivor_queue, survivor_status, "postkill-survivor", "10000", out: File::NULL, err: File::NULL)
  ENV.delete("QSPEC_SUPERVISOR_TEST_POSTKILL_SURVIVOR")
  abort "post-KILL survivor simulation was accepted" unless $?.exitstatus == 21
  survivor_fields = assert_status(wait_status(survivor_status), "postkill-survivor")
  abort "post-KILL survivor was not published orphan=true" unless survivor_fields[10] == "1" && survivor_fields[8] == "1"
  Process.wait(unrelated_recovery)
  abort "recovery harmed unrelated process" unless File.exist?(unrelated_recovery_marker)
end

puts "qspec process supervisor fixtures: PASS"
