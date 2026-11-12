#!/usr/bin/env ruby

require "tmpdir"

ROOT = File.expand_path("..", __dir__)
SUPERVISOR = File.join(ROOT, "tools/qspec_supervise.rb")
STAGES = Integer(ENV.fetch("QSPEC_SUPERVISOR_BENCH_STAGES", "120"), 10)
RUNS = Integer(ENV.fetch("QSPEC_SUPERVISOR_BENCH_RUNS", "3"), 10)
abort "benchmark requires at least 100 stages" if STAGES < 100

def field(value)
  value = value.to_s.b
  "#{value.bytesize}\n#{value}\n"
end

def request_body(root, stage)
  body = +"QSP2\n"
  [stage, 1_000, 200, "", "/dev/null", "/dev/null", 0, "", root].each { |value| body << field(value) }
  body << "1\n" << field("/usr/bin/true") << "0\n"
end

def queue_body(id, token, request, status)
  submitted = (Time.now.to_f * 1_000).to_i
  body = +"QSQ2\n"
  [id, token, submitted, submitted + 5_000, request, status].each { |value| body << field(value) }
  body
end

def elapsed
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
end

def median(values)
  sorted = values.sort
  middle = sorted.length / 2
  sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
end

Dir.mktmpdir("qspec-supervisor-benchmark.") do |dir|
  direct = Array.new(STAGES) { elapsed { system("/usr/bin/true", out: File::NULL, err: File::NULL) or abort "direct stage failed" } }
  direct_median = median(direct)
  baseline_runs = []
  pipeline_runs = []

  RUNS.times do |run|
    baseline = []
    STAGES.times do |index|
      request = File.join(dir, "baseline-#{run}-#{index}.request")
      status = File.join(dir, "baseline-#{run}-#{index}.status")
      baseline << elapsed do
        File.write(request, request_body(dir, "baseline-#{index}"), mode: "wb")
        system("ruby", SUPERVISOR, request, status, out: File::NULL, err: File::NULL) or abort "one-shot stage failed"
      end
      File.delete(request, status)
    end
    baseline_runs << median(baseline.map { |ms| [ms - direct_median, 0].max })

    service_ready = File.join(dir, ".qspec-supervisor.ready")
    startup_ms = elapsed do
      system("ruby", SUPERVISOR, "--ensure-service", dir, Process.pid.to_s, out: File::NULL, err: File::NULL) or abort "service ensure failed"
    end
    ready = File.read(service_ready).strip.split("\t", -1)
    abort "service ready malformed" unless ready.length == 7 && ready[0] == "QSR2"
    service_pid = Integer(ready[1])
    token = ready[5]
    service_samples = STAGES.times.map do |index|
      request = File.join(dir, "service-#{run}-#{index}.request")
      status = File.join(dir, "service-#{run}-#{index}.status")
      queue = File.join(dir, "service-#{run}-#{index}.queue")
      stage_ms = elapsed do
        File.write(request, request_body(dir, "service-#{index}"), mode: "wb")
        queue_tmp = "#{queue}.tmp"
        File.write(queue_tmp, queue_body("service-#{run}-#{index}", token, request, status), mode: "wb")
        File.rename(queue_tmp, queue)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        until File.exist?(status)
          abort "supervisor service lost stage" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.001
        end
      end
      File.delete(request, status)
      [stage_ms + startup_ms / STAGES - direct_median, 0].max
    end
    Process.kill("TERM", service_pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.01 while File.exist?(service_ready) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    pipeline_runs << median(service_samples)
  end

  before = median(baseline_runs)
  after = median(pipeline_runs)
  puts "qspec supervisor benchmark: #{STAGES} stages x #{RUNS} runs"
  puts format("direct child median: %.2fms/stage", direct_median)
  puts format("normal one-shot overhead median: %.2fms/stage", before)
  puts format("service overhead median: %.2fms/stage", after)
  puts format("reduction: %.1f%%", (1.0 - after / before) * 100)
  abort format("service overhead %.2fms/stage exceeds 10ms", after) unless after < 10
end
