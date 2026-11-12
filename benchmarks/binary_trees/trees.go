package main

import "fmt"

// malloc-variant equivalent: one heap allocation per node, freed via GC.
type Node struct {
	left  *Node
	right *Node
}

func treeBuild(depth int) *Node {
	n := &Node{}
	if depth != 0 {
		n.left = treeBuild(depth - 1)
		n.right = treeBuild(depth - 1)
	}
	return n
}

func treeCheck(n *Node) int64 {
	if n == nil {
		return 0
	}
	if n.left == nil {
		return 1
	}
	return 1 + treeCheck(n.left) + treeCheck(n.right)
}

func main() {
	maxDepth := 15
	var total int64 = 0
	for d := 0; d < maxDepth; d++ {
		tree := treeBuild(d)
		total += treeCheck(tree)
	}
	fmt.Println(total)
}
