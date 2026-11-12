# time

## Structs

### `Duration` *(std/time.qz:299)*

Duration represented as nanoseconds (Int).
Range: ±292 years (~int64 range).

| Field | Type |
|-------|------|
| `nanos` | `Int` |

## Constants

### `SECONDS_PER_MINUTE`

### `SECONDS_PER_HOUR`

### `SECONDS_PER_DAY`

## Functions

### `time_epoch(): Int` *(std/time.qz:18)*

Get current Unix epoch time in seconds.
Wraps the POSIX `time()` function.

---

### `time_epoch_ms(): Int` *(std/time.qz:24)*

Get current Unix epoch time in milliseconds.
Uses gettimeofday for microsecond precision, returns ms.

---

### `_time_read_i32(): Int` *(std/time.qz:34)*

---

### `_time_read_i64(): Int` *(std/time.qz:43)*

---

### `time_sleep_ms(): Void` *(std/time.qz:53)*

---

### `time_sleep(): Void` *(std/time.qz:59)*

Sleep for the given number of seconds.

---

### `time_elapsed(): Int` *(std/time.qz:64)*

Get elapsed seconds between two epoch timestamps.

---

### `is_leap_year(): Bool` *(std/time.qz:79)*

Check if a year is a leap year.
Rules: divisible by 4, except centuries, unless divisible by 400.

---

### `days_in_month(): Int` *(std/time.qz:90)*

Get the number of days in a given month (1-12) of a given year.

---

### `days_in_year(): Int` *(std/time.qz:134)*

Get the number of days in a year (365 or 366).

---

### `_epoch_to_days(): Int` *(std/time.qz:143)*

Convert epoch seconds to total days since 1970-01-01.
Handles negative epochs (dates before 1970).

---

### `epoch_to_year(): Int` *(std/time.qz:153)*

Convert epoch seconds to year.

---

### `epoch_to_month(): Int` *(std/time.qz:175)*

Convert epoch seconds to month (1-12).

---

### `epoch_to_day(): Int` *(std/time.qz:207)*

Convert epoch seconds to day of month (1-31).

---

### `epoch_to_hour(): Int` *(std/time.qz:238)*

Convert epoch seconds to hour (0-23).

---

### `epoch_to_minute(): Int` *(std/time.qz:247)*

Convert epoch seconds to minute (0-59).

---

### `epoch_to_second(): Int` *(std/time.qz:256)*

Convert epoch seconds to second (0-59).

---

### `day_of_week(): Int` *(std/time.qz:267)*

Get the day of the week for an epoch timestamp.
Returns 0=Sunday, 1=Monday, ..., 6=Saturday (POSIX convention).
Epoch 0 (1970-01-01) is a Thursday (day 4).

---

### `time_year(): Int` *(std/time.qz:279)*

Get the current year.
Uses proper calendar arithmetic (not the 365.25-day approximation).

---

### `time_month(): Int` *(std/time.qz:284)*

Get the current month (1-12).

---

### `time_day(): Int` *(std/time.qz:289)*

Get the current day of the month (1-31).

---

### `duration_from_secs(): Duration` *(std/time.qz:304)*

Constructors

---

### `duration_from_millis(): Duration` *(std/time.qz:308)*

---

### `duration_from_micros(): Duration` *(std/time.qz:312)*

---

### `duration_from_nanos(): Duration` *(std/time.qz:316)*

---

### `duration_zero(): Duration` *(std/time.qz:320)*

---

### `duration_to_secs(): Int` *(std/time.qz:325)*

Accessors (truncating conversion)

---

### `duration_to_millis(): Int` *(std/time.qz:329)*

---

### `duration_to_micros(): Int` *(std/time.qz:333)*

---

### `duration_to_nanos(): Int` *(std/time.qz:337)*

---

### `duration_add(): Duration` *(std/time.qz:342)*

Arithmetic

---

### `duration_sub(): Duration` *(std/time.qz:346)*

---

### `duration_mul(): Duration` *(std/time.qz:350)*

---

### `duration_cmp(): Int` *(std/time.qz:355)*

Comparison: returns -1, 0, or 1

---

### `duration_is_zero(): Bool` *(std/time.qz:366)*

Check if duration is zero

---

### `time_mono_ms(): Int` *(std/time.qz:376)*

Get monotonic time in milliseconds.
Uses the time_mono_ns intrinsic (POSIX clock_gettime CLOCK_MONOTONIC).

---

## FFI Functions

### `usleep(usec: Int): Int` *(std/time.qz:51)*

Sleep for the given number of milliseconds.
Uses POSIX usleep (microsecond sleep).

