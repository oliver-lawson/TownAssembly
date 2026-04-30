; texture.inc.asm - texture state, sampling, and cleanup
;
; the shared texture buffer lives here
; io.ppm.inc.asm/etc write into tex_pixels,tex_width,tex_height

%ifndef TEXTURE_INC
%define TEXTURE_INC

extern free

section .bss
	alignb 8
	; loaded texture state. one texture only atm
	tex_pixels		resq 1	; ptr to ARGB pixel buffer (malloc'd)
	tex_width		resd 1
	tex_height		resd 1
	tex_pad			resd 1	; align next thing to 8

section .text
;================================================================
; sample_texture: nearest-neighbour pixel sample
; in:	edi = u (16.16 fixed point, where 0x10000=1.0=full width)
; 		esi = v " "
; out:	eax = ARGB colour
;
; 		using 16.16 fixed point as using ints only for now
;		coords wraped with % into [0,dim) so no OOR hopefully
;================================================================
sample_texture:
	; texel_x = (u * width) >> 16, % width
	; using AND-mod would only work for ^2 textures so using
	; idiv here for a proper modulo.. perf tradeoff for fewer
	; footguns/extensibility going forward

	; ----------- compute texel_x -----------
	mov eax, edi			; eax = u (16.16fixed point)
	imul eax, [tex_width]	; eax = u * width
	sar eax, 16				; scale down from 16.16, sar drops fractional part

	; eax can be negative or >= width, so wrapping into [0, width)
	; idiv puts signed rmainder to edx, but cdq is needed first to sign-extend
	; eax into edx:eax so the idiv works for negatives
	cdq 					; edx:eax = sign-extended texel coord
	idiv dword [tex_width]	; eax = quotient (unused), edx = remainder

	; idiv's remainder keeps the dividend's sign, so if u is neg lets add:
	test edx, edx			; negative, 0, or positive?
	jns .x_ok				; sign flag 0 (positive)?
	add edx, [tex_width]	; add to wrap it
.x_ok:
	mov ecx, edx			; ecx = texel_x, now in [0, width)

	; ----------- compute texel_y -----------
	; " " for v
	mov eax, esi
	imul eax, [tex_height]
	sar eax, 16
	cdq
	idiv dword [tex_height]
	test edx, edx
	jns .y_ok
	add edx, [tex_height]
.y_ok:
	; edx = texel_y, ecx = texel_x
	; pixel buffer is row-major, so linear offset is (y * width + x)
	; scale this by 4 for ARGB colours
	mov eax, edx			; eax = texel_y
	imul eax, [tex_width]	; y *= width
	add eax, ecx			; y += x
	mov rdx, [tex_pixels]	; rdx = base of buffer
	mov eax, [rdx + rax*4]	; fetch ARGB dword at offset
	ret

;================================================================
; free_texture: releases the pixel buffer
;================================================================
free_texture:
	mov rdi, [tex_pixels]
	test rdi, rdi
	jz .ft_done
	call free
	mov qword [tex_pixels], 0
.ft_done:
	ret

; pull in ppm loader, it refs tex_* symbols
%include "io_ppm.inc.asm"
; + other io file formats later for textures..

%endif