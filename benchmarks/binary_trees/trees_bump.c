/* Binary tree benchmark using bump allocator (fair comparison with Quartz)
 *
 * Same algorithm as trees.c but uses a pre-allocated bump region
 * instead of per-node malloc/free. This is the apples-to-apples
 * comparison for trees_bump.qz.
 *
 * Node layout: { left, right } — 16 bytes per node
 * Depth 15 needs 2^16 - 1 = 65535 nodes * 16 bytes = 1,048,560 bytes
 */

#include <stdio.h>
#include <stdlib.h>

typedef struct Node {
    struct Node *left;
    struct Node *right;
} Node;

/* Simple bump allocator — identical strategy to Quartz's bump_alloc */
typedef struct {
    char *base;
    char *ptr;
    size_t capacity;
} Bump;

Bump bump_new(size_t capacity) {
    char *mem = (char *)malloc(capacity);
    return (Bump){ .base = mem, .ptr = mem, .capacity = capacity };
}

void *bump_alloc(Bump *b, size_t size) {
    /* Align to 8 bytes */
    size = (size + 7) & ~7;
    void *p = b->ptr;
    b->ptr += size;
    return p;
}

void bump_reset(Bump *b) {
    b->ptr = b->base;
}

void bump_free(Bump *b) {
    free(b->base);
}

Node *tree_build(Bump *bump, int depth) {
    Node *n = (Node *)bump_alloc(bump, sizeof(Node));
    if (depth == 0) {
        n->left = NULL;
        n->right = NULL;
    } else {
        n->left = tree_build(bump, depth - 1);
        n->right = tree_build(bump, depth - 1);
    }
    return n;
}

long tree_check(Node *n) {
    if (n == NULL) return 0;
    if (n->left == NULL) return 1;
    return 1 + tree_check(n->left) + tree_check(n->right);
}

int main(void) {
    int max_depth = 15;
    long total = 0;
    Bump bump = bump_new(2097152); /* 2MB — same as Quartz */
    for (int d = 0; d < max_depth; d++) {
        bump_reset(&bump);
        Node *tree = tree_build(&bump, d);
        total += tree_check(tree);
    }
    bump_free(&bump);
    printf("%ld\n", total);
    return 0;
}
