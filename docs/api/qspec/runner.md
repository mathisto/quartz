# qspec/runner

## Functions

### `_test_new(): Int` *(std/qspec/runner.qz:33)*

QSpec Test Runner

Core test execution engine with describe/it DSL, hooks,
focus/skip, and timing.

Usage:
  import qspec/runner
  import qspec/matchers

  describe("My Module") do ->
    it "does something" do
      expect(42).to_eq(42)
    end
  end

---

### `_suite_new(): Int` *(std/qspec/runner.qz:49)*

---

### `_init_stats(): Void` *(std/qspec/runner.qz:75)*

---

### `_inc_stat(): Void` *(std/qspec/runner.qz:87)*

---

### `_add_duration(): Void` *(std/qspec/runner.qz:92)*

---

### `_init_focus(): Void` *(std/qspec/runner.qz:102)*

---

### `_set_has_focus(): Void` *(std/qspec/runner.qz:108)*

---

### `_is_focus_mode(): Bool` *(std/qspec/runner.qz:113)*

---

### `_current_suite(): Int` *(std/qspec/runner.qz:123)*

Get the current suite from the top of the suite stack.

---

### `describe(): Void` *(std/qspec/runner.qz:128)*

Define a test suite. Nests when called inside another describe.

---

### `context(): Void` *(std/qspec/runner.qz:148)*

Alias for describe — reads as "given this precondition"

---

### `it(): Void` *(std/qspec/runner.qz:154)*

Define a test case and execute it immediately.
Results are stored for later reporting.

---

### `it_pending(): Void` *(std/qspec/runner.qz:209)*

Define a pending test (no block)

---

### `fit(): Void` *(std/qspec/runner.qz:222)*

Focused test — only focused tests run when any exist

---

### `xit(): Void` *(std/qspec/runner.qz:228)*

Skipped test

---

### `skip_unless(): Void` *(std/qspec/runner.qz:246)*

Skip the current test at runtime if condition is false.
Call at the top of an `it` block:
  it "needs QEMU" do
    skip_unless(shell_ok("which qemu-system-aarch64"), "QEMU not installed")
    # ... rest of test only runs if QEMU is available
  end

---

### `skip_test(): Void` *(std/qspec/runner.qz:253)*

Skip unconditionally with a reason.

---

### `_init_skip(): Void` *(std/qspec/runner.qz:257)*

---

### `_set_skip(): Void` *(std/qspec/runner.qz:264)*

---

### `_clear_skip(): Void` *(std/qspec/runner.qz:270)*

---

### `_is_skipped(): Int` *(std/qspec/runner.qz:276)*

---

### `before(): Void` *(std/qspec/runner.qz:284)*

Register a before hook — calls the hook before each test in this suite.
Note: Due to Quartz's type system, hooks are called at registration time.
The hook function is called once here to set up state.

---

### `after(): Void` *(std/qspec/runner.qz:291)*

Register an after hook

---

### `test(): Void` *(std/qspec/runner.qz:301)*

Flat test definition (creates an implicit top-level suite)

---

### `qspec_run(): Int` *(std/qspec/runner.qz:320)*

Run reporting — tests have already been executed during registration.
Returns number of failures.

---

### `qspec_total(): Int` *(std/qspec/runner.qz:326)*

Accessors for stats

---

### `qspec_passed(): Int` *(std/qspec/runner.qz:331)*

---

### `qspec_failed(): Int` *(std/qspec/runner.qz:336)*

---

### `qspec_pending(): Int` *(std/qspec/runner.qz:341)*

---

### `qspec_skipped(): Int` *(std/qspec/runner.qz:346)*

---

### `qspec_duration_us(): Int` *(std/qspec/runner.qz:351)*

---

### `qspec_assertions(): Int` *(std/qspec/runner.qz:356)*

---

### `qspec_root_suites(): Int` *(std/qspec/runner.qz:362)*

Get root suites for formatter access

---

### `qspec_suite_name(): String` *(std/qspec/runner.qz:367)*

Get a suite's name

---

### `qspec_suite_tests(): Int` *(std/qspec/runner.qz:372)*

Get a suite's tests vec

---

### `qspec_suite_children(): Int` *(std/qspec/runner.qz:377)*

Get a suite's children vec

---

### `qspec_test_name(): String` *(std/qspec/runner.qz:382)*

Get test case accessors

---

### `qspec_test_status(): Int` *(std/qspec/runner.qz:386)*

---

### `qspec_test_duration(): Int` *(std/qspec/runner.qz:390)*

---

### `qspec_test_failure(): String` *(std/qspec/runner.qz:394)*

---

