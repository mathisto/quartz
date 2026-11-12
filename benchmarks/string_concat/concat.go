package main

import (
	"fmt"
	"strings"
)

func main() {
	var sb strings.Builder
	for i := 0; i < 100000; i++ {
		sb.WriteString("x")
	}
	s := sb.String()
	fmt.Println(len(s))
}
