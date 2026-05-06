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
;---------------------------------------------------------------- 
; in:  edi=x, esi=y, edx=w, ecx=h, r8d=ARGB colour
;================================================================
fill_rect:
	push rbx
	push r12
	push r13
	push r14

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
	mov ebx, ecx			; h
.row:
	mov rdi, r14
	mov ecx, r12d			; per-row pixel count
	mov eax, r13d
	rep stosd
	add r14, FB_PITCH		; advance to next row
	dec ebx
	jnz .row
.out:
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

%endif
