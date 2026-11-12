/* Binary trees benchmark — C equivalent
 * Recursive tree construction + checksum.
 * Matches the Quartz binary_trees/trees.qz benchmark.
 */
#include <stdio.h>
#include <stdlib.h>

#define MAX_DEPTH 15

typedef struct Node {
  struct Node *left;
  struct Node *right;
  int value;
} Node;

static Node *tree_new(int val) {
  Node *n = malloc(sizeof(Node));
  n->left = NULL;
  n->right = NULL;
  n->value = val;
  return n;
}

static Node *tree_build(int depth) {
  if (depth == 0)
    return tree_new(0);
  Node *n = tree_new(0);
  n->left = tree_build(depth - 1);
  n->right = tree_build(depth - 1);
  return n;
}

static int tree_check(Node *n) {
  if (!n)
    return 0;
  if (!n->left)
    return 1;
  return 1 + tree_check(n->left) + tree_check(n->right);
}

static void tree_free(Node *n) {
  if (!n)
    return;
  tree_free(n->left);
  tree_free(n->right);
  free(n);
}

int main(void) {
  long total = 0;
  for (int d = 0; d < MAX_DEPTH; d++) {
    Node *tree = tree_build(d);
    total += tree_check(tree);
    tree_free(tree);
  }
  printf("%ld\n", total);
  return 0;
}
