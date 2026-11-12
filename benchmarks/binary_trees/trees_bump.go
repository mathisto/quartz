package main

import "fmt"

// bump-allocator variant: nodes carved from a pre-allocated slab, reset per depth.
// Mirrors the Quartz bump_new/bump_alloc/bump_reset design (index-into-slab).
type bump struct {
	buf []Node
	off int
}

type Node struct {
	left  int
	right int
	value int64
}

func newBump(n int) *bump      { return &bump{buf: make([]Node, n)} }
func (b *bump) reset()         { b.off = 0 }
func (b *bump) alloc() int     { i := b.off; b.off++; return i }

func treeBuild(b *bump, depth int) int {
	node := b.alloc()
	b.buf[node].value = 0
	if depth == 0 {
		b.buf[node].left = -1
		b.buf[node].right = -1
		return node
	}
	b.buf[node].left = treeBuild(b, depth-1)
	b.buf[node].right = treeBuild(b, depth-1)
	return node
}

func treeCheck(b *bump, node int) int64 {
	if node < 0 {
		return 0
	}
	left := b.buf[node].left
	right := b.buf[node].right
	if left < 0 {
		return 1
	}
	return 1 + treeCheck(b, left) + treeCheck(b, right)
}

func main() {
	maxDepth := 15
	var total int64 = 0
	b := newBump(65536)
	for d := 0; d < maxDepth; d++ {
		b.reset()
		tree := treeBuild(b, d)
		total += treeCheck(b, tree)
	}
	fmt.Println(total)
}
