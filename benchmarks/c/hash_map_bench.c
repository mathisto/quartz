/* Hash map benchmark — C equivalent
 * Open-addressing hash table with string keys and DYNAMIC RESIZE.
 * Resizes at 75% load factor (2x growth) to match Quartz stdlib HashMap.
 * Uses FNV-1a hashing (same algorithm as Quartz).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NUM_KEYS 100000
#define LOOKUP_ROUNDS 3
#define INITIAL_CAPACITY 16
#define LOAD_FACTOR_NUM 3    /* 75% = 3/4 */
#define LOAD_FACTOR_DEN 4

typedef struct {
    char *key;
    long value;
    int occupied;
} Entry;

typedef struct {
    Entry *entries;
    int capacity;
    int size;
} HashMap;

static unsigned long hash_str(const char *s) {
    unsigned long h = 14695981039346656037ULL;
    while (*s) {
        h ^= (unsigned char)*s++;
        h *= 1099511628211ULL;
    }
    return h;
}

static HashMap *hashmap_new(void) {
    HashMap *m = calloc(1, sizeof(HashMap));
    m->capacity = INITIAL_CAPACITY;
    m->size = 0;
    m->entries = calloc(INITIAL_CAPACITY, sizeof(Entry));
    return m;
}

/* Internal: insert into a specific entry table (no resize check) */
static void insert_into(Entry *entries, int capacity, char *key, long value) {
    unsigned long idx = hash_str(key) & (capacity - 1);
    while (entries[idx].occupied) {
        if (strcmp(entries[idx].key, key) == 0) {
            entries[idx].value = value;
            return;
        }
        idx = (idx + 1) & (capacity - 1);
    }
    entries[idx].key = key;  /* takes ownership of the pointer */
    entries[idx].value = value;
    entries[idx].occupied = 1;
}

/* Resize the table to 2x capacity, rehashing all entries */
static void hashmap_resize(HashMap *m) {
    int old_cap = m->capacity;
    Entry *old_entries = m->entries;
    int new_cap = old_cap * 2;
    Entry *new_entries = calloc(new_cap, sizeof(Entry));

    for (int i = 0; i < old_cap; i++) {
        if (old_entries[i].occupied) {
            insert_into(new_entries, new_cap, old_entries[i].key,
                        old_entries[i].value);
        }
    }

    m->entries = new_entries;
    m->capacity = new_cap;
    free(old_entries);
}

static void hashmap_set(HashMap *m, const char *key, long value) {
    /* Resize at 75% load */
    if (m->size * LOAD_FACTOR_DEN >= m->capacity * LOAD_FACTOR_NUM) {
        hashmap_resize(m);
    }

    unsigned long idx = hash_str(key) & (m->capacity - 1);
    while (m->entries[idx].occupied) {
        if (strcmp(m->entries[idx].key, key) == 0) {
            m->entries[idx].value = value;
            return;  /* update, no size change */
        }
        idx = (idx + 1) & (m->capacity - 1);
    }
    m->entries[idx].key = strdup(key);
    m->entries[idx].value = value;
    m->entries[idx].occupied = 1;
    m->size++;
}

static long hashmap_get(HashMap *m, const char *key) {
    unsigned long idx = hash_str(key) & (m->capacity - 1);
    while (m->entries[idx].occupied) {
        if (strcmp(m->entries[idx].key, key) == 0)
            return m->entries[idx].value;
        idx = (idx + 1) & (m->capacity - 1);
    }
    return 0;
}

static int hashmap_has(HashMap *m, const char *key) {
    unsigned long idx = hash_str(key) & (m->capacity - 1);
    while (m->entries[idx].occupied) {
        if (strcmp(m->entries[idx].key, key) == 0)
            return 1;
        idx = (idx + 1) & (m->capacity - 1);
    }
    return 0;
}

/* Delete with backward-shift (Robin Hood compatible) to avoid
 * tombstones that degrade probe chains. */
static void hashmap_del(HashMap *m, const char *key) {
    unsigned long idx = hash_str(key) & (m->capacity - 1);
    while (m->entries[idx].occupied) {
        if (strcmp(m->entries[idx].key, key) == 0) {
            free(m->entries[idx].key);
            m->entries[idx].key = NULL;
            m->entries[idx].occupied = 0;
            m->size--;

            /* Backward shift: close the gap to fix probe chains */
            unsigned long hole = idx;
            unsigned long next = (hole + 1) & (m->capacity - 1);
            while (m->entries[next].occupied) {
                unsigned long nat = hash_str(m->entries[next].key)
                                    & (m->capacity - 1);
                /* Check if 'next' is displaced past 'hole' */
                int displaced;
                if (hole <= next)
                    displaced = (nat <= hole || nat > next);
                else
                    displaced = (nat <= hole && nat > next);
                if (displaced) {
                    m->entries[hole] = m->entries[next];
                    m->entries[next].key = NULL;
                    m->entries[next].occupied = 0;
                    hole = next;
                }
                next = (next + 1) & (m->capacity - 1);
            }
            return;
        }
        idx = (idx + 1) & (m->capacity - 1);
    }
}

static void hashmap_free(HashMap *m) {
    for (int i = 0; i < m->capacity; i++) {
        if (m->entries[i].occupied)
            free(m->entries[i].key);
    }
    free(m->entries);
    free(m);
}

int main(void) {
    char buf[32];
    HashMap *m = hashmap_new();

    /* Phase 1: Insert */
    for (int i = 0; i < NUM_KEYS; i++) {
        snprintf(buf, sizeof(buf), "%d", i);
        hashmap_set(m, buf, (long)i * 7);
    }

    /* Phase 2: Lookup */
    long total = 0;
    for (int round = 0; round < LOOKUP_ROUNDS; round++) {
        for (int i = 0; i < NUM_KEYS; i++) {
            snprintf(buf, sizeof(buf), "%d", i);
            total += hashmap_get(m, buf);
        }
    }

    /* Phase 3: Delete half */
    for (int i = 0; i < NUM_KEYS; i += 2) {
        snprintf(buf, sizeof(buf), "%d", i);
        hashmap_del(m, buf);
    }

    /* Phase 4: Verify remaining */
    int remaining = 0;
    for (int i = 1; i < NUM_KEYS; i += 2) {
        snprintf(buf, sizeof(buf), "%d", i);
        if (hashmap_has(m, buf))
            remaining++;
    }

    hashmap_free(m);

    printf("Inserted: %d\n", NUM_KEYS);
    printf("Lookup total: %ld\n", total);
    printf("Remaining after delete: %d\n", remaining);
    return 0;
}
