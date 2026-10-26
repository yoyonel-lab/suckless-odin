package rendering

import "core:math"
import gl "vendor:OpenGL"

DUST_NOISE_3D_SIZE :: 64

// Predefined permutation table for periodic Perlin noise
@(private="file")
PERLIN_PERM := [512]u8{
	151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,140,36,103,30,69,142,
	8,99,37,240,21,10,23,190,6,148,247,120,234,75,0,26,197,62,94,252,219,203,117,
	35,11,32,57,177,33,88,237,149,56,87,174,20,125,136,171,168,68,175,74,165,71,
	134,139,48,27,166,77,146,158,231,83,111,229,122,60,211,133,230,220,105,92,41,
	55,46,245,40,244,102,143,54,65,25,63,161,1,216,80,73,209,76,132,187,208,89,
	18,169,200,196,135,130,116,188,159,86,164,100,109,198,173,186,3,64,52,217,226,
	250,124,123,5,202,38,147,118,126,255,82,85,212,207,206,59,227,47,16,58,17,182,
	189,28,42,223,183,170,213,119,248,152,2,44,154,163,70,221,153,101,155,167,43,
	172,9,129,22,39,253,19,98,108,110,79,113,224,232,178,185,112,104,218,246,97,
	228,251,34,242,193,238,210,144,12,191,179,162,241,81,51,145,235,249,14,239,
	107,49,192,214,31,181,199,106,157,184,84,204,176,115,121,50,45,127,4,150,254,
	138,236,205,93,222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180,
	// Duplicate for wrapping without branching
	151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,140,36,103,30,69,142,
	8,99,37,240,21,10,23,190,6,148,247,120,234,75,0,26,197,62,94,252,219,203,117,
	35,11,32,57,177,33,88,237,149,56,87,174,20,125,136,171,168,68,175,74,165,71,
	134,139,48,27,166,77,146,158,231,83,111,229,122,60,211,133,230,220,105,92,41,
	55,46,245,40,244,102,143,54,65,25,63,161,1,216,80,73,209,76,132,187,208,89,
	18,169,200,196,135,130,116,188,159,86,164,100,109,198,173,186,3,64,52,217,226,
	250,124,123,5,202,38,147,118,126,255,82,85,212,207,206,59,227,47,16,58,17,182,
	189,28,42,223,183,170,213,119,248,152,2,44,154,163,70,221,153,101,155,167,43,
	172,9,129,22,39,253,19,98,108,110,79,113,224,232,178,185,112,104,218,246,97,
	228,251,34,242,193,238,210,144,12,191,179,162,241,81,51,145,235,249,14,239,
	107,49,192,214,31,181,199,106,157,184,84,204,176,115,121,50,45,127,4,150,254,
	138,236,205,93,222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180,
}

@(private="file")
perlin_fade :: #force_inline proc(t: f32) -> f32 {
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
}

@(private="file")
perlin_grad :: #force_inline proc(h: u8, x, y, z: f32) -> f32 {
	h_mask := h & 15
	u := x if h_mask < 8 else y
	v := y if h_mask < 4 else (x if h_mask == 12 || h_mask == 14 else z)
	res_u := u if (h_mask & 1) == 0 else -u
	res_v := v if (h_mask & 2) == 0 else -v
	return res_u + res_v
}

@(private="file")
perlin3d_periodic :: proc(x, y, z: f32, period: i32) -> f32 {
	xi := i32(math.floor(x)) % period
	yi := i32(math.floor(y)) % period
	zi := i32(math.floor(z)) % period
	if xi < 0 do xi += period
	if yi < 0 do yi += period
	if zi < 0 do zi += period

	xf := x - math.floor(x)
	yf := y - math.floor(y)
	zf := z - math.floor(z)

	u := perlin_fade(xf)
	v := perlin_fade(yf)
	w := perlin_fade(zf)

	xi1 := (xi + 1) % period
	yi1 := (yi + 1) % period
	zi1 := (zi + 1) % period

	p := &PERLIN_PERM
	aaa := p[p[p[xi] + u8(yi)] + u8(zi)]
	aba := p[p[p[xi] + u8(yi1)] + u8(zi)]
	aab := p[p[p[xi] + u8(yi)] + u8(zi1)]
	abb := p[p[p[xi] + u8(yi1)] + u8(zi1)]
	baa := p[p[p[xi1] + u8(yi)] + u8(zi)]
	bba := p[p[p[xi1] + u8(yi1)] + u8(zi)]
	bab := p[p[p[xi1] + u8(yi)] + u8(zi1)]
	bbb := p[p[p[xi1] + u8(yi1)] + u8(zi1)]

	x1 := math.lerp(perlin_grad(aaa, xf, yf, zf), perlin_grad(baa, xf - 1.0, yf, zf), u)
	x2 := math.lerp(perlin_grad(aba, xf, yf - 1.0, zf), perlin_grad(bba, xf - 1.0, yf - 1.0, zf), u)
	y1 := math.lerp(x1, x2, v)

	x3 := math.lerp(perlin_grad(aab, xf, yf, zf - 1.0), perlin_grad(bab, xf - 1.0, yf, zf - 1.0), u)
	x4 := math.lerp(perlin_grad(abb, xf, yf - 1.0, zf - 1.0), perlin_grad(bbb, xf - 1.0, yf - 1.0, zf - 1.0), u)
	y2 := math.lerp(x3, x4, v)

	return math.lerp(y1, y2, w)
}

// Generates a 64x64x64 periodic 3D texture containing seamless 3-octave FBM dust noise
create_dust_noise_texture_3d :: proc() -> u32 {
	size :: DUST_NOISE_3D_SIZE
	voxels := make([]u8, size * size * size, context.temp_allocator)

	idx := 0
	for z in 0..<size {
		fz := f32(z) / f32(size)
		for y in 0..<size {
			fy := f32(y) / f32(size)
			for x in 0..<size {
				fx := f32(x) / f32(size)

				// 3 octaves with power-of-two periods that wrap seamlessly on [0, 1]
				oct0 := perlin3d_periodic(fx * 4.0,  fy * 4.0,  fz * 4.0,  4)  * 0.50
				oct1 := perlin3d_periodic(fx * 8.0,  fy * 8.0,  fz * 8.0,  8)  * 0.30
				oct2 := perlin3d_periodic(fx * 16.0, fy * 16.0, fz * 16.0, 16) * 0.20

				val := oct0 + oct1 + oct2 // roughly in [-1, +1]
				normalized := clamp((val + 0.6) * 0.8, 0.0, 1.0)
				voxels[idx] = u8(normalized * 255.0)
				idx += 1
			}
		}
	}

	tex_id: u32
	gl.GenTextures(1, &tex_id)
	gl.BindTexture(gl.TEXTURE_3D, tex_id)

	gl.TexImage3D(
		gl.TEXTURE_3D, 0, gl.R8,
		size, size, size, 0,
		gl.RED, gl.UNSIGNED_BYTE, raw_data(voxels),
	)

	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_WRAP_S, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_WRAP_T, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_WRAP_R, gl.REPEAT)

	gl.BindTexture(gl.TEXTURE_3D, 0)
	return tex_id
}
