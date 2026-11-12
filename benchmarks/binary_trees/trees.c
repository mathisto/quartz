#include <stdio.h>
#include <stdlib.h>

typedef struct Node {
    struct Node *left;
    struct Node *right;
} Node;

Node *tree_build(int depth) {
    Node *n = malloc(sizeof(Node));
    if (depth == 0) {
        n->left = NULL;
        n->right = NULL;
    } else {
        n->left = tree_build(depth - 1);
        n->right = tree_build(depth - 1);
    }
    return n;
}

long tree_check(Node *n) {
    if (n == NULL) return 0;
    if (n->left == NULL) return 1;
    return 1 + tree_check(n->left) + tree_check(n->right);
}

void tree_free(Node *n) {
    if (n == NULL) return;
    tree_free(n->left);
    tree_free(n->right);
    free(n);
}

int main(void) {
    int max_depth = 15;
    long total = 0;
    for (int d = 0; d < max_depth; d++) {
        Node *tree = tree_build(d);
        total += tree_check(tree);
        tree_free(tree);
    }
    printf("%ld\n", total);
    return 0;
}
