/*
 * Branch/call-heavy kernel: recursive binary-search-tree build and walk.
 *
 * Inserts a pseudo-random key stream (a plain LCG) into a BST via recursive
 * insert, then sums the keys with a recursive in-order walk, repeated over
 * many rounds. The cost is dominated by function-call overhead, unpredictable
 * branches and pointer-chasing malloc'd nodes -- work that no register
 * allocator can hide -- so rubycc is expected to come closest to gcc here.
 *
 * Fixed workload, deterministic output.
 */
#include <stdio.h>
#include <stdlib.h>

#define NODES 200000
#define ROUNDS 12

typedef struct Node {
    unsigned long key;
    struct Node *left;
    struct Node *right;
} Node;

static Node *insert(Node *root, unsigned long key) {
    if (!root) {
        Node *n = malloc(sizeof(Node));
        n->key = key;
        n->left = NULL;
        n->right = NULL;
        return n;
    }
    if (key < root->key) {
        root->left = insert(root->left, key);
    } else {
        root->right = insert(root->right, key);
    }
    return root;
}

static unsigned long walk(Node *root) {
    if (!root) return 0;
    return root->key + walk(root->left) + walk(root->right);
}

static void destroy(Node *root) {
    if (!root) return;
    destroy(root->left);
    destroy(root->right);
    free(root);
}

int main(void) {
    unsigned long total = 0;
    unsigned long seed = 1;
    for (int r = 0; r < ROUNDS; r++) {
        Node *root = NULL;
        for (int i = 0; i < NODES; i++) {
            seed = seed * 6364136223846793005UL + 1442695040888963407UL;
            root = insert(root, seed >> 33);
        }
        total += walk(root);
        destroy(root);
    }
    printf("treesum total=%lu\n", total);
    return 0;
}
