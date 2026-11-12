// Quartz WASM Browser Runtime
//
// Provides WASI preview1 imports for running Quartz WASM programs in-browser.
//
// The Quartz compiler's --backend wasm produces SELF-CONTAINED binaries that
// synthesize all runtime functions (strings, vecs, hashmaps, options, math,
// etc.) directly into WASM bytecodes. These binaries only import two WASI
// functions: proc_exit and fd_write. The env:: fallback imports below are
// provided for legacy compatibility but are unused by self-contained modules.

export function createRuntime(opts = {}) {
  const output = opts.output || [];
  let memory = null;
  let heapPtr = 0;

  // ---- Memory helpers ----

  function getMemory() {
    return new DataView(memory.buffer);
  }

  function readI64(addr) {
    return getMemory().getBigInt64(addr, true);
  }

  function writeI64(addr, val) {
    getMemory().setBigInt64(addr, val, true);
  }

  function readI32(addr) {
    return getMemory().getInt32(addr, true);
  }

  function writeI32(addr, val) {
    getMemory().setInt32(addr, val, true);
  }

  // ---- String helpers ----
  // Quartz strings: [i64 len] [data bytes] [null]
  // Pointer points to data[0], length at ptr - 8

  function readQzString(ptr) {
    const p = Number(ptr);
    const dv = getMemory();
    const len = Number(dv.getBigInt64(p - 8, true));
    const bytes = new Uint8Array(memory.buffer, p, len);
    return new TextDecoder().decode(bytes);
  }

  function allocQzString(str) {
    const encoded = new TextEncoder().encode(str);
    const len = encoded.length;
    // Allocate: 8 (len prefix) + len + 1 (null) aligned to 8
    const totalSize = 8 + len + 1;
    const aligned = (totalSize + 7) & ~7;
    const base = bump(aligned);
    writeI64(base, BigInt(len));
    const dataPtr = base + 8;
    new Uint8Array(memory.buffer, dataPtr, len).set(encoded);
    new Uint8Array(memory.buffer)[dataPtr + len] = 0;
    return BigInt(dataPtr);
  }

  function bump(size) {
    // Simple bump allocator mirroring the WASM global
    const ptr = heapPtr;
    heapPtr = (heapPtr + size + 7) & ~7;
    // Grow memory if needed
    const pages = memory.buffer.byteLength / 65536;
    while (heapPtr > pages * 65536) {
      memory.grow(1);
    }
    return ptr;
  }

  // ---- Vec helpers ----
  // Vec layout: [i64 data_ptr] [i64 size] [i64 capacity]

  function vecNew() {
    const addr = bump(24);
    const dataAddr = bump(64); // initial capacity 8
    writeI64(addr, BigInt(dataAddr));
    writeI64(addr + 8, 0n);
    writeI64(addr + 16, 8n);
    return BigInt(addr);
  }

  function vecPush(vecPtr, value) {
    const v = Number(vecPtr);
    let dataPtr = Number(readI64(v));
    let size = Number(readI64(v + 8));
    let cap = Number(readI64(v + 16));
    if (size >= cap) {
      const newCap = cap * 2;
      const newData = bump(newCap * 8);
      new Uint8Array(memory.buffer, newData, size * 8).set(
        new Uint8Array(memory.buffer, dataPtr, size * 8)
      );
      dataPtr = newData;
      writeI64(v, BigInt(newData));
      writeI64(v + 16, BigInt(newCap));
      cap = newCap;
    }
    writeI64(dataPtr + size * 8, BigInt(value));
    writeI64(v + 8, BigInt(size + 1));
    return 0n;
  }

  function vecSize(vecPtr) {
    return readI64(Number(vecPtr) + 8);
  }

  function vecGet(vecPtr, index) {
    const v = Number(vecPtr);
    const dataPtr = Number(readI64(v));
    const idx = Number(index);
    return readI64(dataPtr + idx * 8);
  }

  // ---- Hashmap stubs ----

  function hashmapNew() { return vecNew(); }

  // ---- WASI preview1 ----

  const wasi_snapshot_preview1 = {
    proc_exit(code) {
      throw new WasmExit(code);
    },
    fd_write(fd, iovs, iovsLen, nwrittenPtr) {
      let written = 0;
      const dv = getMemory();
      for (let i = 0; i < iovsLen; i++) {
        const bufPtr = dv.getInt32(iovs + i * 8, true);
        const bufLen = dv.getInt32(iovs + i * 8 + 4, true);
        const bytes = new Uint8Array(memory.buffer, bufPtr, bufLen);
        const text = new TextDecoder().decode(bytes);
        output.push(text);
        written += bufLen;
      }
      dv.setInt32(nwrittenPtr, written, true);
      return 0;
    },
  };

  // ---- env:: imports ----

  const env = {
    // String operations
    str_concat(a, b) {
      const sa = readQzString(a);
      const sb = readQzString(b);
      return allocQzString(sa + sb);
    },
    str_from_int(n) {
      return allocQzString(String(n));
    },
    to_str(n) {
      return allocQzString(String(n));
    },
    str_eq(a, b) {
      return readQzString(a) === readQzString(b) ? 1n : 0n;
    },
    str_starts_with(str, prefix) {
      return readQzString(str).startsWith(readQzString(prefix)) ? 1n : 0n;
    },
    str_ends_with(str, suffix) {
      return readQzString(str).endsWith(readQzString(suffix)) ? 1n : 0n;
    },
    str_contains(str, substr) {
      return readQzString(str).includes(readQzString(substr)) ? 1n : 0n;
    },
    str_trim(s) {
      return allocQzString(readQzString(s).trim());
    },
    str_downcase(s) {
      return allocQzString(readQzString(s).toLowerCase());
    },
    str_upcase(s) {
      return allocQzString(readQzString(s).toUpperCase());
    },
    str_substr(s, start, len) {
      const str = readQzString(s);
      return allocQzString(str.substring(Number(start), Number(start) + Number(len)));
    },
    str_index_of(s, sub) {
      const idx = readQzString(s).indexOf(readQzString(sub));
      return BigInt(idx);
    },
    str_replace(s, from, to) {
      const str = readQzString(s);
      const f = readQzString(from);
      const t = readQzString(to);
      return allocQzString(str.split(f).join(t));
    },
    str_split(s, delim) {
      const parts = readQzString(s).split(readQzString(delim));
      const vec = vecNew();
      for (const part of parts) {
        vecPush(vec, allocQzString(part));
      }
      return vec;
    },

    // Vec operations
    vec_new() { return vecNew(); },
    vec_push(v, val) { return vecPush(v, val); },
    vec_size(v) { return vecSize(v); },
    vec_get(v, i) { return vecGet(v, i); },
    vec_set(v, i, val) {
      const vp = Number(v);
      const dataPtr = Number(readI64(vp));
      writeI64(dataPtr + Number(i) * 8, BigInt(val));
      return 0n;
    },
    vec_pop(v) {
      const vp = Number(v);
      let size = Number(readI64(vp + 8));
      if (size <= 0) return 0n;
      size--;
      const dataPtr = Number(readI64(vp));
      const val = readI64(dataPtr + size * 8);
      writeI64(vp + 8, BigInt(size));
      return val;
    },

    // Hashmap/IntMap — now synthesized in self-contained WASM.
    // Legacy fallback stubs for older compilation modes.
    hashmap_new() { return hashmapNew(); },
    hashmap_set() { return 0n; },
    hashmap_get() { return 0n; },
    hashmap_has() { return 0n; },
    hashmap_size() { return 0n; },
    intmap_new() { return hashmapNew(); },
    intmap_set() { return 0n; },
    intmap_get() { return 0n; },
    intmap_has() { return 0n; },
    intmap_size() { return 0n; },

    // Math
    print_int(n) { output.push(String(n)); },
    eprint_int(n) { /* stderr - ignore in browser */ },

    // I/O stubs
    open_file() { return 0n; },
    close_file() { return 0n; },
    read_file() { return allocQzString(""); },
    write_file() { return 0n; },
    fwrite() { return 0n; },
    fread() { return 0n; },
    system() { return 0n; },
    getenv() { return allocQzString(""); },
    getcwd() { return allocQzString("/playground"); },

    // Time
    time_epoch_ms() { return BigInt(Date.now()); },
    time_mono_ns() { return BigInt(Math.floor(performance.now() * 1e6)); },

    // Misc
    qz_free() {},
    mem_peak_rss() { return 0n; },
    mem_current_rss() { return 0n; },
    option_some(v) {
      const addr = bump(16);
      writeI64(addr, 0n); // tag = Some
      writeI64(addr + 8, BigInt(v));
      return BigInt(addr);
    },
    option_none() {
      const addr = bump(16);
      writeI64(addr, 1n); // tag = None
      writeI64(addr + 8, 0n);
      return BigInt(addr);
    },
  };

  return {
    setMemory(mem) {
      memory = mem;
      // Read initial heap pointer from global
      heapPtr = 1024; // Will be overwritten by actual global
    },
    setHeapPtr(ptr) {
      heapPtr = ptr;
    },
    imports: { wasi_snapshot_preview1, env },
    output,
  };
}

export class WasmExit {
  constructor(code) {
    this.code = code;
  }
}
