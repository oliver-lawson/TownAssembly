; bloom.inc.asm - simple s/w additive bloom post process fx
;
; algorithm:
;  1. copy bright pixels from fb into bloom_a, zero the rest
;  2. horizontal 1-4-6-4-1 / 16 blur:  bloom_a -> bloom_b
;  3. vertical	 1-4-6-4-1 / 16 blur:  bloom_b -> bloom_a
;  4. composite: fb[i] = saturate(fb[i] + bloom_a[i])
;
; everything is per-channel u8 in ARGB - we ignore the alpha
; channel in scratch buffers and preserve fb's alpha on composite

%ifndef BLOOM_INC
%define BLOOM_INC

; scratch buffers - same size+layout as the framebuffer so the
; same (y*WINDOW_W + x) * 4 indexing works
%define BLOOM_FB_BYTES	(WINDOW_W * WINDOW_H * 4)

section .data
	; on by default
	bloom_enabled		db 1
	align 2
	bloom_threshold		dw 140 ; (0..255)
	bloom_intensity		dw 200 ; (0..256)

	; log msgs
	bloom_log_on		db "bloom on", 0
	bloom_log_off		db "bloom off", 0

section .bss
	; scratch buffers - ping-pong h then v blur between them
	alignb 16
	bloom_a				resb BLOOM_FB_BYTES
	alignb 16
	bloom_b				resb BLOOM_FB_BYTES
	; 5 dword sample slots used by the blur passes
	alignb 4
	bloom_sample			resd 5

section .text

;================================================================
; bloom_apply: run the full bloom pipeline on framebuffer
;----------------------------------------------------------------
; no-op if disabled.  modifies framebuffer in place.  uses
; bloom_a and bloom_b as scratch
; clobbers: rax, rcx, rdx, rsi, rdi, r8-r11
;================================================================
bloom_apply:
	cmp byte [bloom_enabled], 0
	je .out
	push rbp
	mov rbp, rsp

	call bloom_bright_pass	; fb		-> bloom_a
	call bloom_blur_h		; bloom_a 	-> bloom_b
	call bloom_blur_v		; bloom_b 	-> bloom_a
	call bloom_composite	; fb 		+= bloom_a (saturating)

	pop rbp
.out:
	ret

;================================================================
; bloom_bright_pass: extract bright pixels from fb into bloom_a
;----------------------------------------------------------------
; per pixel:
;	luma = (r*77 + g*151 + b*28) >> 8  ; rec.601-ish, sums to 256
;	if luma <= threshold: out = 0
;	else:
;		k = (luma - threshold) * intensity / 256
;		out_c = (c * k) >> 8  per channel
;================================================================
bloom_bright_pass:
	push rbx
	push r12
	push r13
	push r14
	push r15

	lea r12, [framebuffer]		; src
	lea r13, [bloom_a]			; dst
	mov r14, WINDOW_W * WINDOW_H ; pixel count
	movzx r15d, word [bloom_threshold]
	movzx r11d, word [bloom_intensity]

.loop:
	mov eax, [r12]				; ARGB
	; --- unpack ---
	mov ecx, eax
	shr ecx, 16
	and ecx, 0xFF				; ecx = r
	mov edx, eax
	shr edx, 8
	and edx, 0xFF				; edx = g
	mov ebx, eax
	and ebx, 0xFF				; ebx = b

	; --- luma = (r*77 + g*151 + b*28) >> 8 ---
	mov eax, ecx
	imul eax, 77
	mov esi, edx
	imul esi, 151
	add eax, esi
	mov esi, ebx
	imul esi, 28
	add eax, esi
	shr eax, 8					; eax = luma 0..255

	; --- below threshold? write 0 and move on ---
	cmp eax, r15d
	jg .keep
	mov dword [r13], 0
	jmp .next 

.keep:
	; k = (luma - threshold) * intensity / 256
	sub eax, r15d
	imul eax, r11d
	shr eax, 8
	; cap k at 255 so (c*k)>>8 stays in u8
	cmp eax, 255
	jle .k_ok
	mov eax, 255
.k_ok:
	mov esi, eax				; esi = k (0..255)

	; out_r = (r * k) >> 8
	imul ecx, esi
	shr ecx, 8
	; out_g = (g * k) >> 8
	imul edx, esi
	shr edx, 8
	; out_b = (b * k) >> 8
	imul ebx, esi
	shr ebx, 8
	; repack ARGB (alpha = 0)
	shl ecx, 16
	shl edx, 8
	or ecx, edx
	or ecx, ebx
	mov [r13], ecx

.next:
	add r12, 4
	add r13, 4
	dec r14
	jnz .loop

	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; bloom_blend5: combine 5 samples in bloom_sample with 1-4-6-4-1/16
; into a packed ARGB pixel.  helper for blur passes
;----------------------------------------------------------------
; in:  bloom_sample[0..4] = 5 ARGB dwords
;out:  eax = packed result (alpha = 0)
;clb:  rax, rcx, rdx, rsi
;================================================================
bloom_blend5:
	; --- R channel into esi ---
	mov eax, [bloom_sample + 0*4]
	shr eax, 16
	and eax, 0xFF
	mov ecx, [bloom_sample + 1*4]
	shr ecx, 16
	and ecx, 0xFF
	shl ecx, 2					; *4
	add eax, ecx
	mov ecx, [bloom_sample + 2*4]
	shr ecx, 16
	and ecx, 0xFF
	imul ecx, 6
	add eax, ecx
	mov ecx, [bloom_sample + 3*4]
	shr ecx, 16
	and ecx, 0xFF
	shl ecx, 2
	add eax, ecx
	mov ecx, [bloom_sample + 4*4]
	shr ecx, 16
	and ecx, 0xFF
	add eax, ecx
	shr eax, 4
	mov esi, eax				; esi = out_r

	; --- G channel into edx ---
	mov eax, [bloom_sample + 0*4]
	shr eax, 8
	and eax, 0xFF
	mov ecx, [bloom_sample + 1*4]
	shr ecx, 8
	and ecx, 0xFF
	shl ecx, 2
	add eax, ecx
	mov ecx, [bloom_sample + 2*4]
	shr ecx, 8
	and ecx, 0xFF
	imul ecx, 6
	add eax, ecx
	mov ecx, [bloom_sample + 3*4]
	shr ecx, 8
	and ecx, 0xFF
	shl ecx, 2
	add eax, ecx
	mov ecx, [bloom_sample + 4*4]
	shr ecx, 8
	and ecx, 0xFF
	add eax, ecx
	shr eax, 4
	mov edx, eax				; edx = out_g

	; --- B channel into eax ---
	mov eax, [bloom_sample + 0*4]
	and eax, 0xFF
	mov ecx, [bloom_sample + 1*4]
	and ecx, 0xFF
	shl ecx, 2
	add eax, ecx
	mov ecx, [bloom_sample + 2*4]
	and ecx, 0xFF
	imul ecx, 6
	add eax, ecx
	mov ecx, [bloom_sample + 3*4]
	and ecx, 0xFF
	shl ecx, 2
	add eax, ecx
	mov ecx, [bloom_sample + 4*4]
	and ecx, 0xFF
	add eax, ecx
	shr eax, 4					; eax = out_b

	; pack: alpha=0, r=esi, g=edx, b=eax
	shl esi, 16
	shl edx, 8
	or eax, esi
	or eax, edx
	ret

;================================================================
; bloom_blur_h: horizontal 1-4-6-4-1 / 16 blur, bloom_a -> bloom_b
;----------------------------------------------------------------
; for each row y, for each x:
;	sample_i = bloom_a[ y, clamp(x+i-2, 0, W-1) ]
;	out[y,x] = sum(weighted samples) >> 4 
;================================================================
bloom_blur_h:
	push rbx
	push r12
	push r13
	push r14
	push r15

	xor r14, r14				; y = 0
.row:
	; row base offset (bytes) = y * WINDOW_W * 4
	mov r15, r14
	imul r15, WINDOW_W * 4
	xor r13, r13				; x = 0
.col:
	; --- gather 5 samples with horizontal edge clamp ---
	; rdi = &bloom_a[y, 0] - base + row offset folded together
	; so samples reduce to base[reg*4]
	lea rdi, [bloom_a]
	add rdi, r15
	; sample0: x-2 clamped to 0
	mov rax, r13
	sub rax, 2
	jns .t0_ok
	xor rax, rax
.t0_ok:
	mov ecx, [rdi + rax*4]
	mov [bloom_sample + 0*4], ecx
	; sample1: x-1
	mov rax, r13
	sub rax, 1
	jns .t1_ok
	xor rax, rax
.t1_ok:
	mov ecx, [rdi + rax*4]
	mov [bloom_sample + 1*4], ecx
	; sample2: x (centre, always in range)
	mov ecx, [rdi + r13*4]
	mov [bloom_sample + 2*4], ecx
	; sample3: x+1
	mov rax, r13
	inc rax
	cmp rax, WINDOW_W - 1
	jle .t3_ok
	mov rax, WINDOW_W - 1
.t3_ok:
	mov ecx, [rdi + rax*4]
	mov [bloom_sample + 3*4], ecx
	; sample4: x+2
	mov rax, r13
	add rax, 2
	cmp rax, WINDOW_W - 1
	jle .t4_ok
	mov rax, WINDOW_W - 1
.t4_ok:
	mov ecx, [rdi + rax*4]
	mov [bloom_sample + 4*4], ecx

	call bloom_blend5			 ; eax = blurred pixel 

	; store -> bloom_b[y, x].  same trick as above for the dest
	lea rdi, [bloom_b]
	add rdi, r15
	mov [rdi + r13*4], eax

	inc r13
	cmp r13, WINDOW_W
	jl .col

	inc r14
	cmp r14, WINDOW_H
	jl .row

	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; bloom_blur_v: vertical 1-4-6-4-1 / 16 blur, bloom_b -> bloom_a
;----------------------------------------------------------------
; same kernel as h, but samples step by WINDOW_W rows instead of by
; one pixel
;
;for each row we pre-compute 5 row byte offsets (with vertical clamp)
; and reuse them across all x
;================================================================
bloom_blur_v:
	push rbx
	push r12
	push r13
	push r14
	push r15

	xor r14, r14 ; y = 0
.row:
	; --- pre-compute 5 absolute row pointers into bloom_b with
	; vertical clamp
	; r8=row0 ptr, r9=row1, r10=row2 (centre), r11=row3, rbx=row4
	mov rax, r14
	sub rax, 2
	jns .ry0_ok
	xor rax, rax
.ry0_ok:
	imul rax, WINDOW_W * 4
	lea r8, [bloom_b]
	add r8, rax

	mov rax, r14
	sub rax, 1
	jns .ry1_ok
	xor rax, rax
.ry1_ok:
	imul rax, WINDOW_W * 4
	lea r9, [bloom_b]
	add r9, rax

	mov rax, r14
	imul rax, WINDOW_W * 4
	lea r10, [bloom_b]
	add r10, rax

	mov rax, r14
	inc rax
	cmp rax, WINDOW_H - 1
	jle .ry3_ok
	mov rax, WINDOW_H - 1
.ry3_ok:
	imul rax, WINDOW_W * 4
	lea r11, [bloom_b]
	add r11, rax

	mov rax, r14
	add rax, 2
	cmp rax, WINDOW_H - 1
	jle .ry4_ok
	mov rax, WINDOW_H - 1
.ry4_ok:
	imul rax, WINDOW_W * 4
	lea rbx, [bloom_b]
	add rbx, rax

	; --- also pre-compute the dest row pointer in bloom_a
	; into r12 - same y as r10 but pointing at bloom_a instead.
	mov rax, r14
	imul rax, WINDOW_W * 4
	lea r12, [bloom_a]
	add r12, rax

	xor r13, r13 ; x = 0
.col:
	; fetch the 5 samples from bloom_b at column x of each sample row
	mov ecx, [r8 + r13*4]
	mov [bloom_sample + 0*4], ecx
	mov ecx, [r9 + r13*4]
	mov [bloom_sample + 1*4], ecx
	mov ecx, [r10 + r13*4]
	mov [bloom_sample + 2*4], ecx
	mov ecx, [r11 + r13*4]
	mov [bloom_sample + 3*4], ecx
	mov ecx, [rbx + r13*4]
	mov [bloom_sample + 4*4], ecx

	call bloom_blend5 ; eax = blurred pixel

	; store -> bloom_a[y, x]
	mov [r12 + r13*4], eax

	inc r13
	cmp r13, WINDOW_W
	jl .col

	inc r14
	cmp r14, WINDOW_H
	jl .row

	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; bloom_composite: saturating per-channel add bloom_a -> framebuffer
;----------------------------------------------------------------
; fb[i].r = min(fb[i].r + bloom_a[i].r, 255), same for g/b
; fb's alpha lefft as-is.
;================================================================
bloom_composite:
	push rbx
	push r12
	push r13
	push r14

	lea r12, [framebuffer]
	lea r13, [bloom_a]
	mov r14, WINDOW_W * WINDOW_H

.loop:
	mov eax, [r12]		; fb pixel
	mov edx, [r13]		; bloom pixel

	; --- R ---
	mov ecx, eax
	shr ecx, 16
	and ecx, 0xFF		; fb_r
	mov ebx, edx
	shr ebx, 16
	and ebx, 0xFF		; bl_r
	add ecx, ebx
	cmp ecx, 255
	jle .r_ok
	mov ecx, 255
.r_ok:
	; --- G ---
	mov esi, eax
	shr esi, 8
	and esi, 0xFF
	mov ebx, edx
	shr ebx, 8
	and ebx, 0xFF
	add esi, ebx
	cmp esi, 255
	jle .g_ok
	mov esi, 255
.g_ok:
	; --- B ---
	mov edi, eax
	and edi, 0xFF
	mov ebx, edx
	and ebx, 0xFF
	add edi, ebx
	cmp edi, 255
	jle .b_ok
	mov edi, 255
.b_ok:
	; keep fb's alpha in eax
	and eax, 0xFF000000
	shl ecx, 16
	shl esi, 8
	or eax, ecx
	or eax, esi
	or eax, edi
	mov [r12], eax

	add r12, 4
	add r13, 4
	dec r14
	jnz .loop

	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; bloom_toggle: flip enabled flag & log
;================================================================
bloom_toggle:
	push rbp
	mov rbp, rsp
	xor byte [bloom_enabled], 1
	cmp byte [bloom_enabled], 0
	je .off
	lea rdi, [bloom_log_on]
	call debug_log
	pop rbp
	ret
.off:
	lea rdi, [bloom_log_off]
	call debug_log
	pop rbp
	ret

%endif
