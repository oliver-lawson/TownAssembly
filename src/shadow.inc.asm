; shadow.inc.asm - drop shadows under entities
;
; draws a filled ellipse into the framebuffer with alpha blending
; for each scanline row in [-ry, +ry], compute the x-span from the
; ellipse equation and darken those pixels

%ifndef SHADOW_INC
%define SHADOW_INC

; shadow ellipse dimensions (pixels), tuned for 16x16 sprites
%define SHADOW_RX		6
%define SHADOW_RY		3
%define SHADOW_ALPHA	0x4D ; feels good
%define SHADOW_INV_A	(255 - SHADOW_ALPHA)
; move underneath!
%define SHADOW_Y_OFF	7

section .text
;================================================================
; draw_shadow_ellipse: filled ellipse shadow at screen position
;----------------------------------------------------------------
; in:  edi = cx (screen x), esi = cy (screen y)
;================================================================
draw_shadow_ellipse:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 8			; 16-align

	mov r12d, edi		; cx
	mov r13d, esi		; cy

	; loop dy from -SHADOW_RY to +SHADOW_RY
	mov r14d, -SHADOW_RY
.row:
	cmp r14d, SHADOW_RY
	jg .done

	; screen_y = cy + dy
	mov eax, r13d
	add eax, r14d
	test eax, eax
	js .next_row
	cmp eax, WINDOW_H
	jge .next_row
	mov r15d, eax		; r15d = screen_y

	; half_w = rx * sqrt(1 - (dy/ry)^2)
	; = rx * sqrt((ry^2 - dy^2) / ry^2)
	mov eax, SHADOW_RY
	imul eax, eax		; ry^2
	mov ecx, eax		; ecx = ry^2

	mov eax, r14d
	imul eax, eax		; dy^2
	sub ecx, eax		; ecx = ry^2 - dy^2

	; half_w = rx * sqrt(ecx) / ry
	cvtsi2ss xmm0, ecx	; xmm0 = ry^2 - dy^2
	sqrtss xmm0, xmm0	; xmm0 = sqrt(ry^2 - dy^2)
	mov eax, SHADOW_RX
	cvtsi2ss xmm1, eax
	mulss xmm0, xmm1	; * rx
	mov eax, SHADOW_RY
	cvtsi2ss xmm1, eax
	divss xmm0, xmm1	; / ry
	cvtss2si ebx, xmm0	; ebx = half_w (rounded)

	test ebx, ebx
	jz .next_row

	; fill from (cx - half_w) to (cx + half_w)
	mov edi, r12d
	sub edi, ebx		; x_left
	mov esi, r12d
	add esi, ebx		; x_right (inclusive)

	; clip x
	test edi, edi
	jns .x_left_ok
	xor edi, edi
.x_left_ok:
	cmp esi, WINDOW_W
	jl .x_right_ok
	mov esi, WINDOW_W - 1
.x_right_ok:
	cmp edi, esi
	jg .next_row

	; fb row pointer
	mov eax, r15d
	imul eax, WINDOW_W
	add eax, edi
	shl rax, 2
	lea rcx, [framebuffer]
	add rcx, rax		; rcx = ptr to first pixel

	mov eax, esi
	sub eax, edi
	inc eax				; pixel count
	mov edx, eax

	; darken each pixel: channel = channel * inv_a >> 8
.blend_px:
	mov eax, [rcx]		; bg pixel (argb)

	; red (bits 16-23)
	mov r8d, eax
	shr r8d, 16
	and r8d, 0xFF
	imul r8d, SHADOW_INV_A
	shr r8d, 8

	; green (bits 8-15)
	mov r9d, eax
	shr r9d, 8
	and r9d, 0xFF
	imul r9d, SHADOW_INV_A
	shr r9d, 8

	; blue (bits 0-7)
	mov r10d, eax
	and r10d, 0xFF
	imul r10d, SHADOW_INV_A
	shr r10d, 8

	; reassemble
	shl r8d, 16
	shl r9d, 8
	or r8d, r9d
	or r8d, r10d
	or r8d, 0xFF000000
	mov [rcx], r8d

	add rcx, 4
	dec edx
	jnz .blend_px

.next_row:
	inc r14d
	jmp .row

.done:
	add rsp, 8
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret

%endif
