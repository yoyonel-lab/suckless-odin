package main

import "core:fmt"
import "core:time"

import glasbey "../../src/core/glasbey"

print_palette :: proc(label: string, r: ^glasbey.Result) {
	fmt.printf("\n  [%s] %d colors, min dE=%.4f, pair=(%d,%d)\n",
		label, len(r.palette), r.min_delta_e, r.closest_pair[0], r.closest_pair[1])
	for c, i in r.palette {
		lab := glasbey.rgb_to_lab(c)
		ch := glasbey.chroma(lab)
		fmt.printf("    %2d: R=%3d G=%3d B=%3d  L*=%5.1f a*=%6.1f b*=%6.1f C*=%5.1f\n",
			i, int(c.r), int(c.g), int(c.b), lab.L, lab.a, lab.b, ch)
	}
	// Print the closest pair's actual distance for verification
	c1 := r.palette[r.closest_pair[0]]
	c2 := r.palette[r.closest_pair[1]]
	lab1 := glasbey.rgb_to_lab(c1)
	lab2 := glasbey.rgb_to_lab(c2)
	actual_de := glasbey.delta_e(lab1, lab2)
	fmt.printf("  Verify closest pair: dE(%d,%d) = %.4f\n",
		r.closest_pair[0], r.closest_pair[1], actual_de)
}

main :: proc() {
	fmt.println("=== Glasbey Quality Benchmark (16 colors) ===")

	// 1. step=1 full (THE reference — slow but ground truth)
	{
		t := time.now()
		r := glasbey.generate({size = 16, step = 1})
		defer glasbey.destroy_result(&r)
		elapsed := time.diff(t, time.now())
		fmt.printf("\nstep=1  (full scan): min dE = %.4f  time=%v", r.min_delta_e, elapsed)
		print_palette("step=1", &r)
	}

	// 2. step=4
	{
		t := time.now()
		r := glasbey.generate({size = 16, step = 4})
		defer glasbey.destroy_result(&r)
		elapsed := time.diff(t, time.now())
		fmt.printf("\nstep=4  (coarse):    min dE = %.4f  time=%v", r.min_delta_e, elapsed)
		print_palette("step=4", &r)
	}

	// 3. Coarse only step=16
	{
		t := time.now()
		r := glasbey.generate({size = 16, step = 16})
		defer glasbey.destroy_result(&r)
		elapsed := time.diff(t, time.now())
		fmt.printf("\nstep=16 (coarse):    min dE = %.4f  time=%v", r.min_delta_e, elapsed)
		print_palette("step=16", &r)
	}

	// 4. Adaptive step=16
	{
		t := time.now()
		r := glasbey.generate({size = 16, step = 16, adaptive = true})
		defer glasbey.destroy_result(&r)
		elapsed := time.diff(t, time.now())
		fmt.printf("\nstep=16 (adaptive):  min dE = %.4f  time=%v", r.min_delta_e, elapsed)
		print_palette("step=16 adaptive", &r)
	}

	// 5. Adaptive step=32
	{
		t := time.now()
		r := glasbey.generate({size = 16, step = 32, adaptive = true})
		defer glasbey.destroy_result(&r)
		elapsed := time.diff(t, time.now())
		fmt.printf("\nstep=32 (adaptive):  min dE = %.4f  time=%v", r.min_delta_e, elapsed)
		print_palette("step=32 adaptive", &r)
	}

	// 6. With L*/C* bounds
	{
		t := time.now()
		r := glasbey.generate({size = 16, step = 16, adaptive = true,
			lightness_bounds = {20, 90}, chroma_bounds = {20, 100}})
		defer glasbey.destroy_result(&r)
		elapsed := time.diff(t, time.now())
		fmt.printf("\nstep=16 (adaptive+bounds L*[20,90] C*[20,100]): min dE = %.4f  time=%v",
			r.min_delta_e, elapsed)
		print_palette("adaptive+bounds", &r)
	}

	fmt.println("\n\n=== Done ===")
}
