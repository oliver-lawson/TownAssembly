; texture.inc.asm - texture state, sampling, and cleanup
;
; textures are per-struct. each texture struct is 24 bytes:
;	+0:  qword - ptr to ARGB pixel buffer (malloc'd)
;	+8:  dword - width
;	+12: dword - height
;	+16: 8 bytes pad (keeps struct 16-aligned)
;
; the blitter and sample_texture both take a tex ptr in rdi now, so we
; can have multiple textures resident (atlas, sprites, etc).

%ifndef TEXTURE_INC
%define TEXTURE_INC

extern free

; field offsets within a texture struct
%define TEX_PIXELS_OFF  0
%define TEX_WIDTH_OFF   8
%define TEX_HEIGHT_OFF  12
%define TEX_STRUCT_SIZE 24

section .bss
	alignb 8
	; the tile atlas. multiple textures (eg sprites) can be added
	; alongside as additional 24-byte reservations.
	atlas_tex		resb TEX_STRUCT_SIZE

section .text
;================================================================
; sample_texture: nearest-neighbour pixel sample
; in:	rdi = ptr to texture struct
;		esi = u (16.16 fixed point, where 0x10000=1.0=full width)
; 		edx = v " "
; out:	eax = ARGB colour
;
; 		using 16.16 fixed point as using ints only for now
;		coords wraped with % into [0,dim) so no OOR hopefully
;
; UNUSED
; was used before for manual drawing but currently all drawing is
; tile-based and so using the faster blit_texture_rect
; kept for future direct drawing, maybe some cool effects
;================================================================
sample_texture:
	; load width/height/pixels from struct once
	mov r8d, [rdi + TEX_WIDTH_OFF]
	mov r9d, [rdi + TEX_HEIGHT_OFF]
	mov r10, [rdi + TEX_PIXELS_OFF]

	; texel_x = (u * width) >> 16, % width
	; using AND-mod would only work for ^2 textures so using
	; idiv here for a proper modulo.. perf tradeoff for fewer
	; footguns/extensibility going forward

	; ----------- compute texel_x -----------
	mov eax, esi		; eax = u (16.16fixed point)
	imul eax, r8d		; eax = u * width
	sar eax, 16		; scale down from 16.16, sar drops fractional part

	; eax can be negative or >= width, so wrapping into [0, width)
	; idiv puts signed rmainder to edx, but cdq is needed first
	; to sign-extend eax into edx:eax so the idiv works for negatives
	push rdx			; preserve v - we clobber edx with cdq/idiv
	cdq 				; edx:eax = sign-extended texel coord
	idiv r8d			; eax = quotient (unused), edx = remainder

	; idiv's remainder keeps the dividend's sign; u is neg?: add:
	test edx, edx		; negative, 0, or positive?
	jns .x_ok			; sign flag 0 (positive)?
	add edx, r8d		; add to wrap it
.x_ok:
	mov ecx, edx		; ecx = texel_x, now in [0, width)
	pop rdx				; restore v

	; ----------- compute texel_y -----------
	; " " for v
	mov eax, edx
	imul eax, r9d
	sar eax, 16
	cdq
	idiv r9d
	test edx, edx
	jns .y_ok
	add edx, r9d
.y_ok:
	; edx = texel_y, ecx = texel_x
	; pixel buffer is row-major, so linear offset is (y * width + x)
	; scale this by 4 for ARGB colours
	mov eax, edx			; eax = texel_y
	imul eax, r8d			; y *= width
	add eax, ecx			; y += x
	mov eax, [r10 + rax*4]	; fetch ARGB dword at offset
	ret

;================================================================
; free_texture: releases the pixel buffer of a texture struct
; in: rdi = ptr to texture struct
;================================================================
free_texture:
	push rbp
	mov rbp, rsp
	push rbx
	sub rsp, 8                   ; align
	mov rbx, rdi                 ; save struct ptr
	mov rdi, [rbx + TEX_PIXELS_OFF]
	test rdi, rdi
	jz .ft_done
	call free
	mov qword [rbx + TEX_PIXELS_OFF], 0
.ft_done:
	add rsp, 8
	pop rbx
	pop rbp
	ret

; pull in ppm loader, it fills in a texture struct
%include "io_ppm.inc.asm"
; + other io file formats later for textures..

%endif