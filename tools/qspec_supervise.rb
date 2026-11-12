#!/usr/bin/env ruby

require "fileutils"
require "fiddle/import"
require "rbconfig"
require "securerandom"
require "digest"
require "tmpdir"

NOFOLLOW = File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0
OWNERSHIP = "trusted-test-no-setsid:qsc3-wrapper-pgid:detached-unknown"
READY_NAME = ".qspec-supervisor.ready"
LOCK_NAME = ".qspec-supervisor.start.lock"
SEALED_NAME = ".qspec-supervisor.sealed"
MAX_WAL_BYTES = 16_384
$atomic_counter = 0

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def epoch_ms
  (Time.now.to_r * 1_000).to_i
end

class UnsupportedProcessIdentity < StandardError; end

module DarwinProc
  PROC_PIDTBSDINFO = 3
  BSDINFO_SIZE = 136

  if RbConfig::CONFIG["host_os"].match?(/darwin/)
    extend Fiddle::Importer
    dlload "/usr/lib/libproc.dylib"
    extern "int proc_pidinfo(int, int, unsigned long long, void *, int)"
    extern "int proc_listallpids(void *, int)"
    extern "int proc_listchildpids(int, void *, int)"
  end

  def self.info(pid)
    raise UnsupportedProcessIdentity, "unsupported process birth identity: macOS libproc is required" unless respond_to?(:proc_pidinfo)
    buffer = "\0" * BSDINFO_SIZE
    return nil unless proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buffer, buffer.bytesize) == BSDINFO_SIZE
    {
      pid: buffer.byteslice(12, 4).unpack1("L<"),
      ppid: buffer.byteslice(16, 4).unpack1("L<"),
      pgid: buffer.byteslice(100, 4).unpack1("L<"),
      birth: buffer.byteslice(120, 16).unpack("Q<Q<").join("."),
    }
  end

  def self.all
    raise UnsupportedProcessIdentity, "unsupported process inventory: macOS libproc is required" unless respond_to?(:proc_listallpids)
    size = [proc_listallpids(nil, 0), 1].max * 2
    buffer = "\0" * (size * 4)
    count = proc_listallpids(buffer, buffer.bytesize)
    return [] if count <= 0
    buffer.unpack("L<#{count}").filter_map { |pid| pid.zero? ? nil : info(pid) }
  end

  def self.children(pid)
    raise UnsupportedProcessIdentity, "unsupported process inventory: macOS libproc is required" unless respond_to?(:proc_listchildpids)
    capacity = [proc_listchildpids(pid, nil, 0), 1].max * 2
    buffer = "\0" * (capacity * 4)
    count = proc_listchildpids(pid, buffer, buffer.bytesize)
    count <= 0 ? [] : buffer.unpack("L<#{count}").reject(&:zero?)
  end
end

def process_identity(pid)
  DarwinProc.info(pid)&.fetch(:birth)
end

def process_matches?(pid, identity)
  current = process_identity(pid)
  !current.nil? && current == identity
end

def reject_unsafe_destination(path)
  stat = File.lstat(path)
  raise ArgumentError, "writable destination is a symlink" if stat.symlink?
  raise ArgumentError, "writable destination is not regular" unless stat.file?
rescue Errno::ENOENT
  nil
end

def secure_create_or_truncate(path)
  reject_unsafe_destination(path)
  flags = File::WRONLY | File::CREAT | NOFOLLOW
  flags |= File.exist?(path) ? File::TRUNC : File::EXCL
  io = IO.new(IO.sysopen(path, flags, 0o600), "wb")
  raise ArgumentError, "writable destination is not regular" unless io.stat.file?
  io
end

def secure_read(path)
  stat = File.lstat(path)
  raise ArgumentError, "request file is a symlink" if stat.symlink?
  raise ArgumentError, "request file is not regular" unless stat.file?
  io = File.open(path, File::RDONLY | NOFOLLOW)
  raise ArgumentError, "request file changed type" unless io.stat.file?
  return io unless block_given?
  begin
    yield io
  ensure
    io.close
  end
end

def secure_temp(path)
  io = IO.new(IO.sysopen(path, File::WRONLY | File::CREAT | File::EXCL | NOFOLLOW, 0o600), "wb")
  raise ArgumentError, "temporary destination is not regular" unless io.stat.file?
  io
end

def sync_directory(path)
  File.open(File.dirname(path), File::RDONLY) { |directory| directory.fsync }
end

def atomic_write(path, body, sync: false)
  raise ArgumentError, "record too large" if body.bytesize > MAX_WAL_BYTES
  counter = $atomic_counter
  $atomic_counter += 1
  tmp = "#{path}.tmp.#{Process.pid}.#{counter}"
  io = secure_temp(tmp)
  io.write(body)
  io.flush
  io.fsync if sync
  io.close
  reject_unsafe_destination(path)
  File.rename(tmp, path)
  sync_directory(path) if sync
ensure
  File.delete(tmp) if defined?(tmp) && File.exist?(tmp)
end

def canonical_uint?(raw, minimum: 0, maximum: (1 << 63) - 1)
  raw.match?(/\A(?:0|[1-9]\d*)\z/) && raw.bytesize <= 19 && Integer(raw, 10).between?(minimum, maximum)
rescue ArgumentError
  false
end

def canonical_birth?(raw)
  parts = raw.split(".", -1)
  parts.length == 2 && canonical_uint?(parts[0], maximum: (1 << 63) - 1) &&
    canonical_uint?(parts[1], maximum: 999_999)
end

def bounded_snapshot(source, destination, root_path, limit)
  root = File.realpath(root_path)
  raise ArgumentError, "source escapes owner root" unless contained_path?(source, root)
  raise ArgumentError, "snapshot escapes owner root" unless contained_path?(destination, root)
  body = secure_read(source) do |io|
    raise ArgumentError, "result file exceeds #{limit} byte limit" if io.stat.size > limit
    bytes = io.read(limit + 1)
    raise ArgumentError, "result file exceeds #{limit} byte limit" if bytes.bytesize > limit
    bytes
  end
  atomic_write(destination, body)
end

def contained_path?(path, root)
  return true if path.empty? || path == "/dev/null"
  expanded = File.expand_path(path)
  parent = File.realpath(File.dirname(expanded))
  parent == root || parent.start_with?(root + File::SEPARATOR)
end

def read_field(io)
  line = io.gets or raise ArgumentError, "truncated field length"
  raise ArgumentError, "invalid field length" unless line.match?(/\A\d+\n\z/)
  length = Integer(line, 10)
  raise ArgumentError, "field too large" if length > 1_048_576
  value = io.read(length)
  raise ArgumentError, "truncated field" unless value&.bytesize == length
  raise ArgumentError, "missing field terminator" unless io.read(1) == "\n"
  raise ArgumentError, "NUL is not permitted" if value.include?("\0")
  value
end

def read_count(io)
  line = io.gets or raise ArgumentError, "truncated count"
  raise ArgumentError, "invalid count" unless line.match?(/\A\d+\n\z/)
  count = Integer(line, 10)
  raise ArgumentError, "count too large" if count > 1024
  count
end

def parse_request(request_path, status_path, on_header = nil)
  secure_read(request_path) do |io|
    raise ArgumentError, "invalid protocol header" unless io.gets == "QSP2\n"
    stage = read_field(io)
    raise ArgumentError, "invalid stage" unless stage.match?(/\A[a-z0-9_-]+\z/)
    deadline_raw = read_field(io)
    grace_raw = read_field(io)
    raise ArgumentError, "invalid deadline" unless deadline_raw.match?(/\A\d+\z/) && grace_raw.match?(/\A\d+\z/)
    deadline_ms = Integer(deadline_raw, 10)
    grace_ms = Integer(grace_raw, 10)
    on_header.call(stage, deadline_ms) if on_header
    raise ArgumentError, "deadline out of range" unless deadline_ms.between?(1, 3_600_000)
    raise ArgumentError, "grace out of range" unless grace_ms.between?(1, 10_000)
    cwd = read_field(io)
    stdout_path = read_field(io)
    stderr_path = read_field(io)
    merge_raw = read_field(io)
    cancel_path = read_field(io)
    owner_root = read_field(io)
    raise ArgumentError, "invalid merge flag" unless %w[0 1].include?(merge_raw)
    argv = Array.new(read_count(io)) { read_field(io) }
    raise ArgumentError, "empty argv" if argv.empty? || argv.first.empty?
    env = {}
    read_count(io).times do
      key = read_field(io)
      value = read_field(io)
      raise ArgumentError, "invalid environment key" unless key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
      env[key] = value
    end
    raise ArgumentError, "trailing protocol data" unless io.read.empty?
    root = File.realpath(owner_root)
    raise ArgumentError, "request file escapes owner root" unless contained_path?(request_path, root)
    raise ArgumentError, "status file escapes owner root" unless contained_path?(status_path, root)
    raise ArgumentError, "stdout escapes owner root" unless contained_path?(stdout_path, root)
    raise ArgumentError, "stderr escapes owner root" unless contained_path?(stderr_path, root)
    raise ArgumentError, "cancel marker escapes owner root" unless contained_path?(cancel_path, root)
    {
      stage: stage, deadline_ms: deadline_ms, grace_ms: grace_ms, argv: argv,
      env: env, cwd: cwd, stdout: stdout_path, stderr: stderr_path,
      merge: merge_raw == "1", cancel: cancel_path, root: root,
    }
  end
end

def parse_ready(path)
  fields = secure_read(path, &:read).strip.split("\t", -1)
  return nil unless fields.length == 7 && fields[0] == "QSR2" && fields[6] == OWNERSHIP
  return nil unless fields[1].match?(/\A[1-9]\d*\z/) && fields[3].match?(/\A[1-9]\d*\z/)
  return nil unless fields[5].match?(/\A[0-9a-f]{32}\z/)
  { service_pid: Integer(fields[1]), service_start: fields[2], owner_pid: Integer(fields[3]), owner_start: fields[4], token: fields[5], raw: fields.join("\t") }
rescue StandardError
  nil
end

def ready_live?(ready, owner_pid, owner_start)
  ready && ready[:owner_pid] == owner_pid && ready[:owner_start] == owner_start &&
    process_matches?(ready[:service_pid], ready[:service_start]) && process_matches?(owner_pid, owner_start)
end

def acquire_start_lock(root)
  lock = File.join(root, LOCK_NAME)
  deadline = monotonic + 15
  identity = process_identity(Process.pid) || "unknown"
  owner_tmp = File.join(root, ".qspec-supervisor.lock-owner.#{Process.pid}.#{SecureRandom.hex(4)}")
  File.write(owner_tmp, "QSL1\t#{Process.pid}\t#{identity}\t#{epoch_ms}\n", mode: "wb")
  loop do
    begin
      Dir.mkdir(lock, 0o700)
      File.rename(owner_tmp, File.join(lock, "owner"))
      return lock
    rescue Errno::EEXIST
      stale = false
      begin
        fields = File.read(File.join(lock, "owner")).strip.split("\t", -1)
        if fields.length == 4 && fields[1].match?(/\A[1-9]\d*\z/) && fields[3].match?(/\A\d+\z/)
          stale = !process_matches?(Integer(fields[1]), fields[2])
        else
          stale = File.mtime(lock) < Time.now - 1
        end
      rescue Errno::ENOENT
        begin
          stale = File.mtime(lock) < Time.now - 1
        rescue Errno::ENOENT
          next
        end
      rescue StandardError
        stale = File.exist?(lock) && File.mtime(lock) < Time.now - 1
      end
      if stale
        displaced = "#{lock}.stale.#{Process.pid}.#{SecureRandom.hex(4)}"
        begin
          File.rename(lock, displaced)
          FileUtils.rm_rf(displaced)
        rescue Errno::ENOENT
          nil
        end
      else
        raise "service startup lock timed out" if monotonic >= deadline
        sleep 0.005
      end
    end
  end
ensure
  File.delete(owner_tmp) if defined?(owner_tmp) && File.exist?(owner_tmp)
end

def ensure_service(root_path, owner_pid, pgroup: nil)
  root = File.realpath(root_path)
  raise "supervisor root is sealed" if File.exist?(File.join(root, SEALED_NAME))
  owner_start = process_identity(owner_pid) or raise "owner process is not live"
  lock = acquire_start_lock(root)
  begin
    ready_path = File.join(root, READY_NAME)
    ready = parse_ready(ready_path) if File.exist?(ready_path)
    return ready if ready_live?(ready, owner_pid, owner_start)
    File.delete(ready_path) rescue nil
    inspect_stale_claims(root)
    token = SecureRandom.hex(16)
    spawn_options = { in: File::NULL, out: File::NULL, err: File::NULL }
    spawn_options[:pgroup] = pgroup if pgroup
    Process.spawn(RbConfig.ruby, File.expand_path(__FILE__), "--serve", root, owner_pid.to_s, owner_start, token, **spawn_options)
    deadline = monotonic + 5
    loop do
      ready = parse_ready(ready_path) if File.exist?(ready_path)
      return ready if ready_live?(ready, owner_pid, owner_start) && ready[:token] == token
      raise "supervisor service startup timed out" if monotonic >= deadline
      sleep 0.005
    end
  ensure
    FileUtils.rm_rf(lock)
  end
end

def parse_queue(path, root)
  secure_read(path) do |io|
    raise ArgumentError, "invalid queue header" unless io.gets == "QSQ2\n"
    request_id = read_field(io)
    token = read_field(io)
    submitted_raw = read_field(io)
    expires_raw = read_field(io)
    request_path = read_field(io)
    status_path = read_field(io)
    raise ArgumentError, "trailing queue data" unless io.read.empty?
    raise ArgumentError, "invalid request id" unless request_id.match?(/\A[a-zA-Z0-9_.-]{1,160}\z/)
    raise ArgumentError, "invalid service token" unless token.match?(/\A[0-9a-f]{32}\z/)
    raise ArgumentError, "invalid submission time" unless submitted_raw.match?(/\A\d+\z/) && expires_raw.match?(/\A\d+\z/)
    raise ArgumentError, "queue path escapes owner root" unless contained_path?(request_path, root) && contained_path?(status_path, root)
    {
      id: request_id, token: token, submitted_ms: Integer(submitted_raw, 10),
      expires_ms: Integer(expires_raw, 10), request: request_path, status: status_path,
    }
  end
end

class ClaimLifecycle
  attr_reader :path

  def initialize(path, queue, service_pid, service_birth, request)
    stat = File.stat(request[:root])
    @path = path
    @status = queue[:status]
    @base = [queue[:id], request[:stage], queue[:token], Digest::SHA256.file(queue[:request]).hexdigest,
             File.realpath(queue[:request]), File.expand_path(queue[:status]), request[:root], stat.dev, stat.ino,
             queue[:submitted_ms], queue[:expires_ms], request[:deadline_ms], request[:grace_ms], service_pid, service_birth]
    @group = [0, "", 0, 0]
    @result = ["none", 0, 0, 0, 0, 0, 0, 0, ""]
  end

  def publish(state, group = nil, result = nil)
    @group = [group[:wrapper_pid], group[:wrapper_birth], group[:pgid], group[:sid]] if group
    if result
      @result = [result[:kind], result[:value], result[:timed_out] ? 1 : 0, result[:term_sent] ? 1 : 0,
                 result[:kill_sent] ? 1 : 0, result[:elapsed_ms], result[:orphan] ? 1 : 0,
                 result[:cancelled] ? 1 : 0, result[:message].to_s.gsub(/[\t\r\n]/, " ").byteslice(0, 1000)]
    end
    atomic_write(@path, ["QSC3", state, *@base, *@group, *@result, OWNERSHIP].join("\t") + "\n", sync: true)
  end

  def publish_final(group, result)
    publish("PUBLISHED", group, result)
    Process.kill("KILL", Process.pid) if ENV["QSPEC_SUPERVISOR_TEST_CRASH_BOUNDARY"] == "rename"
    reject_unsafe_destination(@status)
    File.rename(@path, @status)
    sync_directory(@status)
  end
end

def parse_claim(path)
  body = secure_read(path, &:read)
  return nil if body.bytesize > MAX_WAL_BYTES
  fields = body.strip.split("\t", -1)
  return { protocol: "QSC2" } if fields[0] == "QSC2"
  return nil unless fields.length == 31 && fields[0] == "QSC3" && fields[30] == OWNERSHIP
  return nil unless %w[PREPARED ACTIVE RESULT PUBLISHED].include?(fields[1])
  return nil unless fields[2].match?(/\A[A-Za-z0-9_.-]{1,160}\z/) && fields[3].match?(/\A[a-z0-9_-]{1,80}\z/)
  return nil unless fields[4].match?(/\A[0-9a-f]{32}\z/) && fields[5].match?(/\A[0-9a-f]{64}\z/)
  ranges = { 9 => [0, (1 << 63) - 1], 10 => [1, (1 << 63) - 1], 11 => [0, (1 << 63) - 1], 12 => [0, (1 << 63) - 1],
             13 => [1, 3_600_000], 14 => [1, 10_000], 15 => [1, (1 << 31) - 1], 17 => [0, (1 << 31) - 1],
             19 => [0, (1 << 31) - 1], 20 => [0, (1 << 31) - 1], 22 => [0, 255], 26 => [0, 3_615_000] }
  return nil unless ranges.all? { |i, bounds| canonical_uint?(fields[i], minimum: bounds[0], maximum: bounds[1]) }
  return nil unless canonical_birth?(fields[16]) && (fields[18].empty? || canonical_birth?(fields[18]))
  return nil unless %w[none exit signal error indeterminate].include?(fields[21])
  return nil unless [23, 24, 25, 27, 28].all? { |i| %w[0 1].include?(fields[i]) }
  return nil if fields[6, 4].any? { |value| value.empty? || value.bytesize > 4096 } || fields[29].bytesize > 1000
  keys = %i[protocol state id stage token request_hash request status root root_dev root_ino submitted_ms expires_ms deadline_ms grace_ms service_pid service_birth wrapper_pid wrapper_birth pgid sid kind value timed_out term_sent kill_sent elapsed_ms orphan cancelled message ownership]
  claim = keys.zip(fields).to_h
  [9, 10, 11, 12, 13, 14, 15, 17, 19, 20, 22, 26].each { |i| claim[keys[i]] = Integer(fields[i], 10) }
  [23, 24, 25, 27, 28].each { |i| claim[keys[i]] = fields[i] == "1" }
  claim
rescue StandardError
  nil
end

def seal_root(root, reason)
  message = reason.to_s.gsub(/[\t\r\n]/, " ").byteslice(0, 500)
  atomic_write(File.join(root, SEALED_NAME), "QSEAL1\t#{epoch_ms}\t#{message}\n", sync: true)
end

def process_group_alive?(pgid)
  Process.kill(0, -pgid)
  true
rescue Errno::ESRCH
  false
rescue Errno::EPERM
  raise
end

def active_claim_paths(pattern)
  Dir.glob(pattern).select { |path| File.basename(path).match?(/\.queue\.claim\.\d+\.[0-9a-f]{8}\z/) }
end

def validate_wrapper(claim)
  info = DarwinProc.info(claim[:wrapper_pid])
  return "wrapper identity is not live" unless info && info[:birth] == claim[:wrapper_birth]
  return "wrapper PID/PGID mismatch" unless claim[:wrapper_pid] == claim[:pgid] && info[:pgid] == claim[:pgid] && Process.getpgid(claim[:wrapper_pid]) == claim[:pgid]
  return "wrapper SID mismatch" unless Process.getsid(claim[:wrapper_pid]) == claim[:sid]
  nil
rescue Errno::ESRCH
  "wrapper identity raced dead"
rescue Errno::EPERM
  "wrapper identity permission denied"
end

def signal_group(signal, pgid)
  Process.kill(signal, -pgid)
  true
rescue Errno::ESRCH
  false
end

def validate_claim_binding(claim, root, status_path: nil, stage: nil)
  stat = File.stat(root)
  return "owner root binding mismatch" unless claim[:root] == root && claim[:root_dev] == stat.dev && claim[:root_ino] == stat.ino
  return "status path binding mismatch" if status_path && claim[:status] != File.expand_path(status_path)
  return "stage binding mismatch" if stage && claim[:stage] != stage
  return "request path escapes owner root" unless contained_path?(claim[:request], root)
  return "request hash mismatch" if File.exist?(claim[:request]) && Digest::SHA256.file(claim[:request]).hexdigest != claim[:request_hash]
  nil
end

def claim_group(claim)
  claim.slice(:wrapper_pid, :wrapper_birth, :pgid, :sid)
end

def claim_result(claim, message: claim[:message], term_sent: claim[:term_sent], kill_sent: claim[:kill_sent], orphan: claim[:orphan])
  { kind: claim[:kind], value: claim[:value], timed_out: claim[:timed_out], term_sent: term_sent,
    kill_sent: kill_sent, elapsed_ms: claim[:elapsed_ms], orphan: orphan, cancelled: claim[:cancelled], message: message }
end

def complete_claim(path, claim, result)
  lifecycle = ClaimLifecycle.allocate
  lifecycle.instance_variable_set(:@path, path)
  lifecycle.instance_variable_set(:@status, claim[:status])
  lifecycle.instance_variable_set(:@base, [claim[:id], claim[:stage], claim[:token], claim[:request_hash], claim[:request], claim[:status],
                                           claim[:root], claim[:root_dev], claim[:root_ino], claim[:submitted_ms], claim[:expires_ms],
                                           claim[:deadline_ms], claim[:grace_ms], claim[:service_pid], claim[:service_birth]])
  lifecycle.publish_final(claim_group(claim), result)
end

def recover_active_claim(path, claim, root)
  if process_matches?(claim[:service_pid], claim[:service_birth])
    seal_root(root, "recorded supervisor service identity is still live")
    return 21
  end
  begin
    alive = process_group_alive?(claim[:pgid])
  rescue Errno::EPERM
    seal_root(root, "EPERM probing active process group")
    return 21
  end
  unless alive
    complete_claim(path, claim, claim_result(claim, message: "indeterminate: ACTIVE wrapper group already absent", orphan: false))
    return 20
  end
  if (reason = validate_wrapper(claim))
    seal_root(root, reason)
    return 21
  end
  Process.kill("KILL", claim[:wrapper_pid]) if ENV["QSPEC_SUPERVISOR_TEST_IDENTITY_RACE"] == "term"
  if (reason = validate_wrapper(claim))
    seal_root(root, "#{reason} before TERM")
    return 21
  end
  term_sent = signal_group("TERM", claim[:pgid])
  limit = monotonic + claim[:grace_ms] / 1000.0
  begin
    sleep 0.005 while process_group_alive?(claim[:pgid]) && monotonic < limit
    alive = process_group_alive?(claim[:pgid])
  rescue Errno::EPERM
    seal_root(root, "EPERM after TERM")
    return 21
  end
  if alive
    Process.kill("KILL", claim[:wrapper_pid]) if ENV["QSPEC_SUPERVISOR_TEST_IDENTITY_RACE"] == "kill"
    if (reason = validate_wrapper(claim))
      seal_root(root, "#{reason} before KILL")
      return 21
    end
    kill_sent = signal_group("KILL", claim[:pgid])
  else
    kill_sent = false
  end
  limit = monotonic + 1.0
  begin
    sleep 0.005 while process_group_alive?(claim[:pgid]) && monotonic < limit
    orphan = process_group_alive?(claim[:pgid])
  rescue Errno::EPERM
    orphan = true
  end
  orphan ||= ENV["QSPEC_SUPERVISOR_TEST_POSTKILL_SURVIVOR"] == "1"
  if orphan
    seal_root(root, "wrapper group not provably ESRCH after cleanup")
    return 21
  end
  complete_claim(path, claim, claim_result(claim, message: "indeterminate: supervisor died after ACTIVE; wrapper group recovered", term_sent: term_sent, kill_sent: kill_sent, orphan: false))
  20
end

def inspect_stale_claims(root)
  paths = active_claim_paths(File.join(root, "*.claim.*"))
  bases = paths.group_by { |path| path.sub(/\.claim\.\d+\.[0-9a-f]{8}\z/, "") }
  raise "replacement refused non-unique stale claims" if bases.any? { |_base, claims| claims.length != 1 }
  paths.each do |path|
    claim = parse_claim(path)
    unless claim
      seal_root(root, "replacement refused malformed stale claim")
      raise "replacement refused malformed stale claim"
    end
    raise "replacement refused unsupported legacy QSC2 claim" if claim[:protocol] == "QSC2"
    if (reason = validate_claim_binding(claim, root))
      seal_root(root, reason)
      raise "replacement refused #{reason}"
    end
    case claim[:state]
    when "ACTIVE"
      raise "replacement refused unrecovered active claim" unless recover_active_claim(path, claim, root) == 20
    when "RESULT", "PUBLISHED"
      complete_claim(path, claim, claim_result(claim))
    else
      seal_root(root, "replacement refused PREPARED spawn uncertainty")
      raise "replacement refused claim/spawn uncertainty"
    end
  end
end

def recover_claim_locked(root, queue_path, status_path, stage, deadline_ms)
  return 0 if File.exist?(queue_path)
  if File.exist?(status_path)
    published = parse_claim(status_path)
    return 20 if published && published[:state] == "PUBLISHED" && !validate_claim_binding(published, root, status_path: status_path, stage: stage)
  end
  claims = active_claim_paths("#{queue_path}.claim.*")
  if claims.length != 1
    seal_root(root, "service died with no unique claim")
    return 21
  end
  path = claims.first
  claim = parse_claim(path)
  if claim && claim[:protocol] == "QSC2"
    seal_root(root, "unsupported legacy QSC2 claim")
    return 21
  end
  unless claim
    seal_root(root, "malformed claim after service death")
    return 21
  end
  if (reason = validate_claim_binding(claim, root, status_path: status_path, stage: stage))
    seal_root(root, reason)
    return 21
  end
  return recover_active_claim(path, claim, root) if claim[:state] == "ACTIVE" && claim[:pgid] > 0 && claim[:wrapper_pid] > 0
  if %w[RESULT PUBLISHED].include?(claim[:state])
    complete_claim(path, claim, claim_result(claim))
    return 20
  end
  seal_root(root, "service died in PREPARED spawn uncertainty")
  21
end

def recover_claim(root_path, queue_path, status_path, stage, deadline_ms)
  root = File.realpath(root_path)
  raise ArgumentError, "recovery queue escapes owner root" unless contained_path?(queue_path, root) && contained_path?(status_path, root)
  lock = acquire_start_lock(root)
  begin
    recover_claim_locked(root, queue_path, status_path, stage, deadline_ms)
  ensure
    FileUtils.rm_rf(lock)
  end
end

class StageSupervisor
  attr_reader :elapsed_ms

  def initialize(request_path, status_path, cancellation = -> { nil }, lifecycle: nil, crash_boundary: "")
    @request_path = request_path
    @status_path = status_path
    @cancellation = cancellation
    @started = monotonic
    @stage = "protocol"
    @deadline_ms = 1
    @spawn_error = ""
    @pid = nil
    @anchor_pid = nil
    @group = nil
    @child_status = nil
    @timed_out = false
    @cancelled = false
    @term_sent = false
    @kill_sent = false
    @orphan = false
    @output_files = []
    @lifecycle = lifecycle
    @crash_boundary = crash_boundary
    @next_detachment_check = 0.0
    @detached_observed = false
  end

  def run(refuse_reason: nil)
    request = parse_request(@request_path, @status_path, ->(stage, deadline_ms) do
      @stage = stage
      @deadline_ms = deadline_ms.between?(1, 3_600_000) ? deadline_ms : 1
    end)
    reason = refuse_reason || cancellation_reason(request)
    if reason
      refuse(reason)
      return
    end
    spawn_options = { pgroup: true }
    spawn_options[:chdir] = request[:cwd] unless request[:cwd].empty?
    add_output(spawn_options, :out, request[:stdout]) unless request[:stdout].empty?
    if request[:merge]
      spawn_options[:err] = [:child, :out]
    elsif !request[:stderr].empty?
      add_output(spawn_options, :err, request[:stderr])
    end
    reason = cancellation_reason(request)
    if reason
      refuse(reason)
      return
    end
    gate_read, gate_write = IO.pipe
    ready_read, ready_write = IO.pipe
    result_read, result_write = IO.pipe
    error_read, error_write = IO.pipe
    error_write.close_on_exec = true
    @pid = Process.fork do
      gate_write.close
      ready_read.close
      result_read.close
      error_read.close
      Process.setpgid(0, 0)
      command_pid = Process.fork do
        ready_write.close
        result_write.close
        allowed = gate_read.read(1)
        exit! 125 unless allowed == "G"
        Dir.chdir(request[:cwd]) unless request[:cwd].empty?
        request[:env].each { |key, value| ENV[key] = value }
        $stdout.reopen(spawn_options[:out]) if spawn_options[:out]
        if spawn_options[:err] == [:child, :out]
          $stderr.reopen($stdout)
        elsif spawn_options[:err]
          $stderr.reopen(spawn_options[:err])
        end
        exec(*request[:argv])
      rescue StandardError => e
        error_write.write("#{e.class}: #{e.message}") rescue nil
        exit! 125
      end
      ready_write.write("R\t#{command_pid}\n")
      ready_write.close
      allowed = gate_read.read(1)
      gate_read.close
      unless allowed == "G"
        Process.kill("KILL", command_pid) rescue nil
        Process.waitpid(command_pid) rescue nil
        exit! 125
      end
      _, status = Process.waitpid2(command_pid)
      result = status.exited? ? "exit\t#{status.exitstatus}" : "signal\t#{status.termsig}"
      result_write.write("#{result}\n")
      result_write.close
      loop { sleep 60 }
    rescue StandardError => e
      error_write.write("#{e.class}: #{e.message}") rescue nil
      exit! 125
    end
    gate_read.close
    ready_write.close
    result_write.close
    error_write.close
    ready = ready_read.gets&.strip&.split("\t", -1)
    ready_read.close
    raise "wrapper process-group setup failed" unless ready&.length == 2 && ready[0] == "R" && canonical_uint?(ready[1], minimum: 1, maximum: (1 << 31) - 1)
    Process.setpgid(@pid, @pid)
    Process.kill("KILL", Process.pid) if @crash_boundary == "spawn"
    wrapper_birth = nil
    identity_deadline = monotonic + 0.25
    until wrapper_birth || monotonic >= identity_deadline
      wrapper_birth = process_identity(@pid)
      sleep 0.001 unless wrapper_birth
    end
    raise "could not establish wrapper process identity" unless wrapper_birth
    sid = Process.getsid(@pid)
    @group = { wrapper_pid: @pid, wrapper_birth: wrapper_birth, pgid: @pid, sid: sid }
    raise "wrapper PGID/SID validation failed" unless Process.getpgid(@pid) == @pid && Process.getsid(@pid) == sid
    @lifecycle&.publish("ACTIVE", @group)
    Process.kill("KILL", Process.pid) if @crash_boundary == "wal"
    prepare_nested_service(request)
    gate_write.write("GG")
    gate_write.close
    Process.kill("KILL", Process.pid) if %w[postclaim gate].include?(@crash_boundary)
    deadline = @started + @deadline_ms / 1000.0
    loop do
      observe_detachment
      if IO.select([result_read], nil, nil, 0.005)
        result = result_read.gets&.strip&.split("\t", -1)
        if result&.length == 2 && %w[exit signal].include?(result[0]) && canonical_uint?(result[1], maximum: 255)
          @result_kind = result[0]
          @result_value = Integer(result[1], 10)
        else
          @spawn_error = "wrapper returned malformed command result"
          @result_kind = "error"
          @result_value = 0
        end
        break
      end
      if (reason = cancellation_reason(request))
        @spawn_error = reason
        @cancelled = true
        terminate(request)
        break
      end
      if monotonic >= deadline
        @timed_out = true
        terminate(request)
        break
      end
    end
    result_read.close
    exec_error = error_read.read
    error_read.close
    @spawn_error = exec_error unless exec_error.empty?
    observe_detachment(force: true)
    reap_nested_service(0.25)
    @lifecycle&.publish("RESULT", @group, wal_result)
    Process.kill("KILL", Process.pid) if %w[result postreap].include?(@crash_boundary)
    terminate(request)
    reap_nested_service(1.0)
    recover_nested_claims
    @orphan = group_alive?
    if @detached_observed
      @spawn_error = "#{@spawn_error} observed descendant detached from recorded PGID/SID; containment is indeterminate".strip
      @orphan = true
    end
  rescue StandardError => e
    @spawn_error = "#{e.class}: #{e.message}"
    emergency_terminate
    begin
      reap_nested_service(1.0)
      recover_nested_claims
    rescue StandardError => recovery_error
      @spawn_error = "#{@spawn_error} nested recovery failed: #{recovery_error.class}: #{recovery_error.message}"
      @orphan = true
    end
  ensure
    publish_outputs
    publish_status
  end

  def success?
    @spawn_error.empty? && @result_kind == "exit" && @result_value == 0 &&
      !@timed_out && !@cancelled && !@orphan
  end

  private

  def observe_detachment(force: false)
    return unless @pid && @group
    now = monotonic
    return if !force && now < @next_detachment_check
    @next_detachment_check = now + 0.05
    queue = [[@pid, false]]
    until queue.empty?
      parent_pid, delegated = queue.shift
      DarwinProc.children(parent_pid).each do |pid|
        child_delegated = delegated || pid == @nested_service_pid
        queue << [pid, child_delegated]
        next if child_delegated
        sid = Process.getsid(pid) rescue nil
        @detached_observed = true if sid && sid != @group[:sid]
      end
    end
  rescue UnsupportedProcessIdentity
    raise
  end

  def prepare_nested_service(request)
    nested_root = request[:env]["QSPEC_SUB_ROOT"]
    return if nested_root.nil? || nested_root.empty?
    expanded = File.expand_path(nested_root)
    parent = File.realpath(File.dirname(expanded))
    raise ArgumentError, "nested supervisor root escapes owner root" unless parent == request[:root] || parent.start_with?(request[:root] + File::SEPARATOR)
    Dir.mkdir(expanded, 0o700) unless File.exist?(expanded)
    raise ArgumentError, "nested supervisor root is not a directory" unless File.directory?(expanded) && !File.lstat(expanded).symlink?
    @nested_root = expanded
    ready = ensure_service(expanded, @pid, pgroup: @pid)
    @nested_service_pid = ready[:service_pid]
  end

  def reap_nested_service(timeout)
    return unless @nested_service_pid
    deadline = monotonic + timeout
    loop do
      waited = Process.waitpid2(@nested_service_pid, Process::WNOHANG)
      if waited
        @nested_service_pid = nil
        return
      end
      return if monotonic >= deadline
      sleep 0.005
    end
  rescue Errno::ECHILD
    @nested_service_pid = nil
  end

  def recover_nested_claims
    return unless @nested_root && File.directory?(@nested_root)
    inspect_stale_claims(@nested_root)
  end

  def cancellation_reason(request)
    external = @cancellation.call
    return external.to_s unless external.nil? || external == false
    return "cancelled before spawn" if !request[:cancel].empty? && File.exist?(request[:cancel])
    nil
  end

  def refuse(reason)
    @cancelled = true
    @spawn_error = reason
  end

  def add_output(spawn_options, key, destination)
    if destination == "/dev/null"
      spawn_options[key] = "/dev/null"
      return
    end
    tmp = "#{destination}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
    io = secure_temp(tmp)
    spawn_options[key] = io
    @output_files << [io, tmp, destination]
  end

  def group_alive?
    raise Errno::EPERM if ENV["QSPEC_SUPERVISOR_TEST_EPERM_AFTER_REAP"] == "1"
    Process.kill(0, -@pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    @orphan = true
    true
  end

  def wait_for_group(limit)
    while monotonic < limit
      break unless group_alive?
      sleep 0.005
    end
  end

  def terminate(request)
    if group_alive? && !@term_sent
      validate_owned_wrapper!
      Process.kill("KILL", Process.pid) if @crash_boundary == "signal"
      @term_sent = true
      Process.kill("TERM", -@pid)
    end
    wait_for_group(monotonic + request[:grace_ms] / 1000.0)
    if group_alive? && !@kill_sent
      validate_owned_wrapper!
      @kill_sent = true
      Process.kill("KILL", -@pid)
    end
    reap_wrapper
    wait_for_group(monotonic + 1.0)
    @orphan = group_alive?
  rescue Errno::ESRCH
    reap_wrapper
    @orphan = group_alive?
  rescue Errno::EPERM
    @spawn_error = "#{@spawn_error} indeterminate: EPERM during wrapper cleanup".strip
    @orphan = true
  end

  def validate_owned_wrapper!
    reason = validate_wrapper(@group)
    raise "#{reason}; group signal refused" if reason
  end

  def reap_wrapper
    Process.waitpid(@pid)
  rescue Errno::ECHILD
    nil
  end

  def emergency_terminate
    return unless @pid
    begin
      Process.kill("TERM", -@pid)
      @term_sent = true
      sleep 0.1
      Process.kill("KILL", -@pid)
      @kill_sent = true
    rescue Errno::ESRCH
      nil
    end
    begin
      Process.waitpid(@pid)
    rescue Errno::ECHILD
      nil
    end
  end

  def publish_outputs
    @output_files.each do |io, tmp, destination|
      next unless File.exist?(tmp)
      unless io.closed?
        io.flush
        io.close
      end
      reject_unsafe_destination(destination)
      File.rename(tmp, destination)
    rescue StandardError => e
      @spawn_error = "#{@spawn_error} #{e.class}: #{e.message}".strip
    end
  end

  def publish_status
    @elapsed_ms = ((monotonic - @started) * 1000).round
    sanitize = ->(value) { value.to_s.gsub(/[\t\r\n]/, " ")[0, 1000] }
    exit_code = !@timed_out && !@cancelled && @spawn_error.empty? && @result_kind == "exit" ? @result_value : -1
    child_signal = !@timed_out && !@cancelled && @spawn_error.empty? && @result_kind == "signal" ? @result_value : 0
    fields = [
      "QSS2", @stage, @deadline_ms, sanitize.call(@spawn_error), exit_code, child_signal,
      @timed_out ? 1 : 0, @term_sent ? 1 : 0, @kill_sent ? 1 : 0, @elapsed_ms,
      @orphan ? 1 : 0, @cancelled ? 1 : 0, OWNERSHIP,
    ]
    if @lifecycle
      @lifecycle.publish_final(@group || { wrapper_pid: 0, wrapper_birth: "", pgid: 0, sid: 0 }, wal_result)
    else
      atomic_write(@status_path, fields.join("\t") + "\n")
    end
  rescue StandardError => e
    warn "qspec supervisor could not publish status: #{e.class}: #{e.message}"
    @publication_failed = true
  end


  def wal_result
    kind = if @timed_out || @cancelled || !@spawn_error.empty?
      "error"
    else
      @result_kind || "error"
    end
    { kind: kind, value: @result_value || 0, timed_out: @timed_out, term_sent: @term_sent,
      kill_sent: @kill_sent, elapsed_ms: ((monotonic - @started) * 1000).round,
      orphan: @orphan, cancelled: @cancelled, message: @spawn_error }
  end
end

if ARGV.first == "--secure-file"
  path, root_path = ARGV.drop(1)
  abort "usage: qspec_supervise.rb --secure-file PATH OWNER_ROOT" unless ARGV.length == 3
  root = File.realpath(root_path)
  parent = File.realpath(File.dirname(File.expand_path(path)))
  abort "secure file escapes owner root" unless parent == root || parent.start_with?(root + File::SEPARATOR)
  secure_create_or_truncate(path).close
  exit 0
end

if ARGV.first == "--ensure-service"
  root_path, owner_raw = ARGV.drop(1)
  abort "usage: qspec_supervise.rb --ensure-service OWNER_ROOT OWNER_PID" unless ARGV.length == 3 && owner_raw.match?(/\A[1-9]\d*\z/)
  ensure_service(root_path, Integer(owner_raw, 10))
  exit 0
end

if ARGV.first == "--recover-claim"
  root_path, queue_path, status_path, stage, deadline_raw = ARGV.drop(1)
  abort "usage: qspec_supervise.rb --recover-claim ROOT QUEUE STATUS STAGE DEADLINE_MS" unless ARGV.length == 6 && deadline_raw.match?(/\A\d+\z/)
  exit recover_claim(root_path, queue_path, status_path, stage, Integer(deadline_raw, 10))
end

if ARGV.first == "--bounded-snapshot"
  source, destination, root_path, limit_raw = ARGV.drop(1)
  abort "usage: qspec_supervise.rb --bounded-snapshot SOURCE DESTINATION OWNER_ROOT LIMIT" unless ARGV.length == 5 && limit_raw.match?(/\A\d+\z/)
  begin
    bounded_snapshot(source, destination, root_path, Integer(limit_raw, 10))
    exit 0
  rescue StandardError => e
    warn "qspec result snapshot rejected: #{e.class}: #{e.message}"
    exit 1
  end
end

requested_signal = nil
%w[INT TERM HUP].each do |name|
  Signal.trap(name) { requested_signal ||= "supervisor received #{name}" }
end

if ARGV.first == "--serve"
  root_path, owner_raw, owner_start, token = ARGV.drop(1)
  abort "usage: qspec_supervise.rb --serve OWNER_ROOT OWNER_PID OWNER_START TOKEN" unless ARGV.length == 5
  root = File.realpath(root_path)
  owner_pid = Integer(owner_raw, 10)
  abort "owner identity changed before service start" unless process_matches?(owner_pid, owner_start)
  service_start = process_identity(Process.pid) or abort "cannot identify supervisor service"
  ready_path = File.join(root, READY_NAME)
  ready_body = ["QSR2", Process.pid, service_start, owner_pid, owner_start, token, OWNERSHIP].join("\t") + "\n"
  atomic_write(ready_path, ready_body)
  next_owner_identity_check = 0.0
  owner_alive = lambda do
    begin
      Process.kill(0, owner_pid)
    rescue Errno::ESRCH
      next false
    end
    now = monotonic
    if now >= next_owner_identity_check
      next_owner_identity_check = now + 0.1
      next process_matches?(owner_pid, owner_start)
    end
    true
  end
  ready_owned = lambda do
    ready = parse_ready(ready_path)
    ready && ready[:service_pid] == Process.pid && ready[:service_start] == service_start && ready[:token] == token
  end
  cancellation = lambda do
    next requested_signal if requested_signal
    next "owner process identity is no longer live" unless owner_alive.call
    next "ready service identity changed" unless ready_owned.call
    nil
  end
  begin
    loop do
      break if cancellation.call
      queue_paths = Dir.glob(File.join(root, "*.queue")).sort
      if queue_paths.empty?
        sleep 0.001
        next
      end
      queue_paths.each do |queue_path|
        break if cancellation.call
        begin
          queue = parse_queue(queue_path, root)
          request = nil
          request_protocol_error = false
          begin
            request = parse_request(queue[:request], queue[:status])
          rescue StandardError
            request_protocol_error = true
          end
          refusal = nil
          refusal = "request submission expired" if epoch_ms > queue[:expires_ms]
          refusal ||= "cancelled before request claim" if request && !request[:cancel].empty? && File.exist?(request[:cancel])
          refusal ||= "ready service token mismatch" unless queue[:token] == token
          claim_path = "#{queue_path}.claim.#{Process.pid}.#{SecureRandom.hex(4)}"
          claim_delay = Integer(ENV.fetch("QSPEC_SUPERVISOR_TEST_CLAIM_DELAY_MS", "0"), 10)
          sleep(claim_delay / 1000.0) if claim_delay > 0
          crash_boundary = ENV.fetch("QSPEC_SUPERVISOR_TEST_CRASH_BOUNDARY", "")
          Process.kill("KILL", Process.pid) if crash_boundary == "preclaim"
          begin
            File.rename(queue_path, claim_path)
          rescue Errno::ENOENT
            next
          end
          begin
            refusal ||= cancellation.call
            refusal ||= "request submission expired" if epoch_ms > queue[:expires_ms]
            lifecycle = nil
            if request
              lifecycle = ClaimLifecycle.new(claim_path, queue, Process.pid, service_start, request)
              lifecycle.publish("PREPARED")
            end
            supervisor = StageSupervisor.new(
              queue[:request], queue[:status], cancellation,
              lifecycle: lifecycle, crash_boundary: crash_boundary,
            )
            if request_protocol_error
              supervisor.run
            else
              supervisor.run(refuse_reason: refusal)
            end
          end
        rescue StandardError => e
          # An unclaimed malformed marker is not authoritative and must not run.
          File.delete(queue_path) rescue nil
          warn "qspec supervisor rejected queue request: #{e.class}: #{e.message}"
        end
      end
    end
  ensure
    File.delete(ready_path) if ready_owned.call rescue nil
  end
  exit 0
end

request_path, status_path = ARGV
unless ARGV.length == 2
  warn "usage: qspec_supervise.rb REQUEST_FILE STATUS_FILE"
  exit 125
end
supervisor = StageSupervisor.new(request_path, status_path, -> { requested_signal })
supervisor.run
exit(supervisor.instance_variable_get(:@publication_failed) ? 125 : 0)
