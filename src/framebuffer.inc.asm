; framebuffer.inc.asm - cpu-side pixel buffer for our window
;
; flat array of 32-bit ARGB pixels laid out row-by-row
; in memory. pixel at x,y lives @ bytes offset:
;               (y * WINDOW_W + x) * 4
;
; we write to this from our rendering code each frame, then
; SDL_UpdateTexture uploads it to GPU

%ifndef FRAMEBUFFER_INC
%define FRAMEBUFFER_INC

%define WINDOW_W 320 ; should keep in multiples of 16, our tilesize
%define WINDOW_H 224 ;240-16

%define FB_BYTES	  (WINDOW_W * WINDOW_H * 4)
; 4 bytes per pixel: A,R,G<B in SDL_PIXELFORMAT_ARGB8888
%define FB_PITCH	  (WINDOW_W * 4) ; bytes per row

section .bss
	alignb 16
	framebuffer		resb FB_BYTES

section .text
;================================================================
; clear_framebuffer: fill the entire buffer with a single colour
; repeat-fills 0..w*h using rep stosd: x86's built-in block fill 
; this writes eax to address in rdi, then advances rdi by 4,
; repeating rcx times.  should be faster than manual loop
;---------------------------------------------------------------- 
; in: edi = ARGB colour
;clb: rax, rcx, rdi
;================================================================
clear_framebuffer:
	mov eax, edi			; stosd writes from eax
	lea rdi, [framebuffer]	; destination
	mov rcx, WINDOW_W * WINDOW_H ; num of dwords to write
	rep stosd				; fill!
	ret

;================================================================
; plot_pixel: write one pixel to the fb (no bounds check)
;
; C equiv: framebuffer[y * WINDOW_W + x] = (uint32t)colour;
;---------------------------------------------------------------- 
; in: edi = x, esi = y, edx = ARGB colour
;================================================================
plot_pixel:
	mov eax, esi			; eax = y
	imul eax, WINDOW_W		; eax*=w
	add eax, edi			; eax+=x
	lea rcx, [framebuffer]
	mov [rcx + rax*4], edx	; write pixel!
	ret

;================================================================
; fill_rect: paint a solid-colour rectangle into the framebuffer
; clips against the fb bounds so off-screen rects are safe
; now with alpha! if not 0xFF, don't use the fast rep stosd path,
; instead bleand existing fb conents using (fg*a+bg*(255-1))>>8
; (per channel) sadly we step away from our fake palletisation
; of art assets here, TODO: this needs more thought..
;---------------------------------------------------------------- 
; in:  edi=x, esi=y, edx=w, ecx=h, r8d=ARGB colour
;================================================================
fill_rect:
	push rbx
	push r12
	push r13
	push r14
	push r15

	; --- clip ---
	; if x < 0: w += x; x = 0
	test edi, edi
	jns .x_pos
	add edx, edi
	xor edi, edi
.x_pos:
	; if y < 0: h += y; y = 0
	test esi, esi
	jns .y_pos
	add ecx, esi
	xor esi, esi
.y_pos:
	; if x + w > WINDOW_W: w = WINDOW_W - x
	mov eax, edi
	add eax, edx
	cmp eax, WINDOW_W
	jle .x_clip_done
	mov edx, WINDOW_W
	sub edx, edi
.x_clip_done:
	; if y + h > WINDOW_H: h = WINDOW_H - y
	mov eax, esi
	add eax, ecx
	cmp eax, WINDOW_H
	jle .y_clip_done
	mov ecx, WINDOW_H
	sub ecx, esi
.y_clip_done:
	; degen rect after clipping?
	test edx, edx
	jle .out
	test ecx, ecx
	jle .out

	; --- fill: row by row, rep stosd per row ---
	mov r12d, edx			; w
	mov r13d, r8d			; colour
	; first-pixel offset = (y * width + x) * 4
	mov eax, esi
	imul eax, WINDOW_W
	add eax, edi
	lea r14, [framebuffer]
	lea r14, [r14 + rax*4]
	mov ebx, ecx			; rows remaining
	; alpha branch: 0xFF -> fast opaque path
	mov eax, r13d
	shr eax, 24
	cmp eax, 0xFF
	jne .blend_setup

.row_opaque:
	mov rdi, r14
	mov ecx, r12d			; per-row pixel count
	mov eax, r13d
	rep stosd
	add r14, FB_PITCH		; advance to next row
	dec ebx
	jnz .row_opaque
	jmp .out

	; --- blended path ---
	; pre-compute src_*_pma = src_channel * alpha (one-time per call)
	; and stash them + inv_a on the stack
	; stack layout (relative to rbp):
	;	[rbp-4]  src_r_pma
	;	[rbp-8]  src_g_pma
	;	[rbp-12] src_b_pma
	;	[rbp-16] inv_a
.blend_setup:
	push rbp
	mov rbp, rsp
	sub rsp, 32			; 16-aligned: 5 callee + 1 rbp + 32 = 80

	mov eax, r13d
	shr eax, 24			; alpha
	mov r15d, eax		; r15 = a
	mov r9d, 255
	sub r9d, r15d		; r9 = inv_a
	mov [rbp-16], r9d

	mov eax, r13d
	shr eax, 16
	and eax, 0xFF
	imul eax, r15d
	mov [rbp-4], eax

	mov eax, r13d
	shr eax, 8
	and eax, 0xFF
	imul eax, r15d
	mov [rbp-8], eax

	mov eax, r13d
	and eax, 0xFF
	imul eax, r15d
	mov [rbp-12], eax

.row_blend:
	mov rdi, r14
	mov ecx, r12d
.pix:
	mov edx, [rdi]		; edx = bg pixel argb
	; out_r
	mov eax, edx
	shr eax, 16
	and eax, 0xFF
	imul eax, [rbp-16]	; bg_r * inv_a
	add eax, [rbp-4]	; + src_r_pma
	shr eax, 8			; >> 8
	; place out_r in bits 16..23 of r10
	shl eax, 16
	mov r10d, eax
	; out_g
	mov eax, edx
	shr eax, 8
	and eax, 0xFF
	imul eax, [rbp-16]
	add eax, [rbp-8]
	shr eax, 8
	shl eax, 8
	or r10d, eax
	; out_b
	mov eax, edx
	and eax, 0xFF
	imul eax, [rbp-16]
	add eax, [rbp-12]
	shr eax, 8
	or r10d, eax
	; opaque alpha
	or r10d, 0xFF000000
	mov [rdi], r10d
	add rdi, 4
	dec ecx
	jnz .pix
	add r14, FB_PITCH
	dec ebx
	jnz .row_blend

	mov rsp, rbp
	pop rbp

.out:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

%endif

