/* Linked list benchmark — C equivalent
 * Singly-linked list with insert/traverse/delete operations.
 * Matches the Quartz linked_list.qz benchmark.
 */
#include <stdio.h>
#include <stdlib.h>

#define NUM_NODES 100000
#define TRAVERSE_ROUNDS 5

typedef struct Node {
  struct Node *next;
  long value;
} Node;

static Node *node_new(long val, Node *next) {
  Node *n = malloc(sizeof(Node));
  n->next = next;
  n->value = val;
  return n;
}

int main(void) {
  /* Phase 1: Build linked list by prepending */
  Node *head = NULL;
  for (int i = 0; i < NUM_NODES; i++) {
    head = node_new(i, head);
  }

  /* Phase 2: Traverse and sum TRAVERSE_ROUNDS times */
  long total = 0;
  for (int round = 0; round < TRAVERSE_ROUNDS; round++) {
    Node *curr = head;
    while (curr) {
      total += curr->value;
      curr = curr->next;
    }
  }

  /* Phase 3: Count nodes */
  int count = 0;
  for (Node *curr = head; curr; curr = curr->next)
    count++;

  /* Phase 4: Delete every other node */
  int deleted = 0;
  Node *prev = head;
  Node *curr = head ? head->next : NULL;
  while (curr) {
    Node *next = curr->next;
    prev->next = next;
    free(curr);
    deleted++;
    if (next) {
      prev = next;
      curr = next->next;
    } else {
      curr = NULL;
    }
  }

  /* Phase 5: Count remaining */
  int remaining = 0;
  for (Node *c = head; c; c = c->next)
    remaining++;

  printf("Nodes: %d\n", count);
  printf("Sum (x%d): %ld\n", TRAVERSE_ROUNDS, total);
  printf("Deleted: %d\n", deleted);
  printf("Remaining: %d\n", remaining);

  /* Cleanup remaining nodes */
  while (head) {
    Node *next = head->next;
    free(head);
    head = next;
  }

  return 0;
}
