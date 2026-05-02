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

%define WINDOW_W 400 ; should keep in multiples of 16, our tilesize
%define WINDOW_H 288

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

%endif
