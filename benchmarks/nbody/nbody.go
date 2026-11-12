package main

import "fmt"

const (
	NUM_BODIES = 5
	NUM_STEPS  = 500000
	SOLAR_MASS = 39478
	DT         = 1
)

var (
	bx, by, bz    [NUM_BODIES]int64
	bvx, bvy, bvz [NUM_BODIES]int64
	bmass         [NUM_BODIES]int64
)

func isqrtL(n int64) int64 {
	if n <= 0 {
		return 0
	}
	x, y := n, (n+1)/2
	for y < x {
		x = y
		y = (x + n/x) / 2
	}
	return x
}

func initBodies() {
	bx[0], by[0], bz[0] = 0, 0, 0
	bvx[0], bvy[0], bvz[0] = 0, 0, 0
	bmass[0] = SOLAR_MASS
	bx[1], by[1], bz[1] = 4841, -1160, -103
	bvx[1], bvy[1], bvz[1] = 606, 2811, -25
	bmass[1] = 37694
	bx[2], by[2], bz[2] = 8343, 4124, -403
	bvx[2], bvy[2], bvz[2] = -876, 1826, 8
	bmass[2] = 11286
	bx[3], by[3], bz[3] = 12894, -15111, -223
	bvx[3], bvy[3], bvz[3] = 1082, 868, -10
	bmass[3] = 1723
	bx[4], by[4], bz[4] = 15379, -25919, 179
	bvx[4], bvy[4], bvz[4] = 979, 594, -24
	bmass[4] = 2033
}

func advance(n int) {
	for step := 0; step < n; step++ {
		for i := 0; i < NUM_BODIES; i++ {
			ix, iy, iz, im := bx[i], by[i], bz[i], bmass[i]
			for j := i + 1; j < NUM_BODIES; j++ {
				dx := ix - bx[j]
				dy := iy - by[j]
				dz := iz - bz[j]
				distSq := dx*dx + dy*dy + dz*dz
				if distSq < 1 {
					distSq = 1
				}
				dist := isqrtL(distSq)
				if dist < 1 {
					dist = 1
				}
				distCubed := dist * dist * dist
				if distCubed < 1 {
					distCubed = 1
				}
				mag := int64(DT) * 1000 / distCubed
				jm := bmass[j]
				bvx[i] -= dx * jm * mag / 1000000
				bvy[i] -= dy * jm * mag / 1000000
				bvz[i] -= dz * jm * mag / 1000000
				bvx[j] += dx * im * mag / 1000000
				bvy[j] += dy * im * mag / 1000000
				bvz[j] += dz * im * mag / 1000000
			}
		}
		for i := 0; i < NUM_BODIES; i++ {
			bx[i] += bvx[i] * DT / 1000
			by[i] += bvy[i] * DT / 1000
			bz[i] += bvz[i] * DT / 1000
		}
	}
}

func energy() int64 {
	var e int64 = 0
	for i := 0; i < NUM_BODIES; i++ {
		vx, vy, vz := bvx[i], bvy[i], bvz[i]
		e += bmass[i] * (vx*vx + vy*vy + vz*vz) / (2 * 1000000)
		for j := i + 1; j < NUM_BODIES; j++ {
			dx := bx[i] - bx[j]
			dy := by[i] - by[j]
			dz := bz[i] - bz[j]
			dist := isqrtL(dx*dx + dy*dy + dz*dz)
			if dist < 1 {
				dist = 1
			}
			e -= bmass[i] * bmass[j] / (dist * 1000)
		}
	}
	return e
}

func main() {
	initBodies()
	e0 := energy()
	fmt.Printf("Energy before: %d\n", e0)
	advance(NUM_STEPS)
	e1 := energy()
	fmt.Printf("Energy after:  %d\n", e1)
}
