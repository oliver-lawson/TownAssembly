; bloodmap.inc.asm - persistent blood splatters baked into a
;					 world-sized off-screen texture
;----------------------------------------------------------------
; v1 of this stored a per-tile `count` byte and redrew the
; stacked splats every frame, which got too costly..
;
; v2 (this file): one big map-sized texture (`blood_fb`).
; splats are blitted INTO it once at splat-time.  per frame, the
; visible camera window is blitted FROM blood_fb to the screen in a
; single keyed copy - so lots of blood works now
;
; wear-off:
;	`blood_age[tile]` is a u8 freshness, 0 = empty, 255 = fresh
;
;	a splat sets it to 255.  a slow tick decrements all tiles by 1
;	roughly every BLOOD_AGE_TICK_FRAMES.  when a tile hits 0 we
;	clear its 16x16 region in blood_fb back to magenta key
; 	the bumping @ new fights should make this feel "sticky" i think,
;	not just fading linearly one after another after fights
;
; storage:
;	blood_fb_pixels		MAP_WIDTH*MAP_HEIGHT*TILE_SIZE*TILE_SIZE*4
;	blood_fb			tex_struct pointing into blood_fb_pixels
;	blood_age			MAP_WIDTH * MAP_HEIGHT bytes 
;	blood_splat_seq		global u32, bumped per splat call
;						used for picking variants & jitter
;----------------------------------------------------------------
%ifndef BLOODMAP_INC
%define BLOODMAP_INC

%define BLOOD_VARIANT_COUNT		16
%define ATLAS_BLOOD_BASE		(4 * ATLAS_COLS + 0)

; how many frames between age-decrement passes.  255 * this / 60
; = lifetime of a single splat in seconds (without bumps):
; @ 300 a splat lasts ~21 minutes; @ 600 ~42 mins etc

%define BLOOD_AGE_TICK_FRAMES	300

%define BLOOD_FB_W				(MAP_WIDTH * TILE_SIZE)
%define BLOOD_FB_H				(MAP_HEIGHT * TILE_SIZE)
%define BLOOD_FB_PITCH_PX		BLOOD_FB_W
%define BLOOD_FB_BYTES			(BLOOD_FB_W * BLOOD_FB_H * 4)

%define BLOOD_KEY				0xFFFF00FF;magenta

section .bss
	alignb 1
	blood_age			resb MAP_WIDTH * MAP_HEIGHT

	alignb 4
	blood_splat_seq		resd 1
	blood_age_tick_acc	resd 1	; frames since last age tick

	alignb 8
	blood_fb			resb TEX_STRUCT_SIZE
	alignb 16
	blood_fb_pixels		resb BLOOD_FB_BYTES

section .text

;================================================================
; blood_init: one-time setup.  call ONCE at program start, after
; the atlas tex is loaded.  not on regen - regen uses blood_clear
;----------------------------------------------------------------
; points blood_fb tex_struct at blood_fb_pixels and fills w/ magenta
;================================================================
blood_init:
	push rdi
	push rcx
	push rax

	lea rdi, [blood_fb]
	lea rax, [blood_fb_pixels]
	mov [rdi + TEX_PIXELS_OFF], rax
	mov dword [rdi + TEX_WIDTH_OFF], BLOOD_FB_W
	mov dword [rdi + TEX_HEIGHT_OFF], BLOOD_FB_H

	lea rdi, [blood_fb_pixels]
	mov ecx, BLOOD_FB_W * BLOOD_FB_H
	mov eax, BLOOD_KEY
	rep stosd

	pop rax
	pop rcx
	pop rdi
	ret

;================================================================
; blood_clear: wipe both the age map and the baked texture. called
; on world regen.  same as blood_init's clear but keeps the
; tex_struct fields intact (already pointing at the pixel buffer)
;================================================================
blood_clear:
	push rdi
	push rcx
	push rax

	lea rdi, [blood_age]
	mov ecx, MAP_WIDTH * MAP_HEIGHT
	xor eax, eax
	rep stosb

	lea rdi, [blood_fb_pixels]
	mov ecx, BLOOD_FB_W * BLOOD_FB_H
	mov eax, BLOOD_KEY
	rep stosd

	mov dword [blood_splat_seq], 0
	mov dword [blood_age_tick_acc], 0

	pop rax
	pop rcx
	pop rdi
	ret

;================================================================
; blood_splat_at_tile: bake one splat into the blood_fb texture
; and set the tile's age to fresh
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
;----------------------------------------------------------------
; variant = (hash(tx,ty) + splat_seq) & 15.jitter from a separate mix
;----------------------------------------------------------------
; stack locals (ret 8 + 5 push 40 + sub 16 = 64, 16-aligned):
;	[rsp+0]  src_x in atlas
;	[rsp+4]  src_y in atlas
;	[rsp+8]  dst_x in blood_fb
;	[rsp+12] dst_y in blood_fb
;================================================================
blood_splat_at_tile:
	test edi, edi
	js .out
	cmp edi, MAP_WIDTH
	jge .out
	test esi, esi
	js .out
	cmp esi, MAP_HEIGHT
	jge .out

	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 24			; locals (24) + 5 push (40) + ret (8) = 72;
						; +3 stack args at call site (24) = 96
						; soo 24 aligns

	mov r12d, edi		; r12 = tx
	mov r13d, esi		; r13 = ty

	; bump splat sequence
	mov eax, [blood_splat_seq]
	inc eax
	mov [blood_splat_seq], eax
	mov r14d, eax		; r14 = seq

	; mark tile fresh
	mov eax, r13d
	imul eax, MAP_WIDTH
	add eax, r12d
	lea rcx, [blood_age]
	mov byte [rcx + rax], 255

	; --- variant = (hash + seq) & 15.  hash = tx*73 + ty*137 ---
	mov eax, r12d
	imul eax, 73
	mov ecx, r13d
	imul ecx, 137
	add eax, ecx
	add eax, r14d
	and eax, BLOOD_VARIANT_COUNT - 1
	mov r15d, eax				; r15 = variant 0..15

	; --- jitter mix: tx*53 + ty*191 + seq*97 ---
	mov eax, r12d
	imul eax, 53
	mov ecx, r13d
	imul ecx, 191
	add eax, ecx
	mov ecx, r14d
	imul ecx, 97
	add eax, ecx
	mov ebx, eax				; ebx = jitter bits

	; jx = (ebx & 7) - 4
	mov ecx, ebx
	and ecx, 7
	sub ecx, 4
	mov edi, ecx				; edi = jx (kept til dst maths)
	; jy = ((ebx >> 4)& 7) - 4
	mov ecx, ebx
	shr ecx, 4
	and ecx, 7
	sub ecx, 4
	mov esi, ecx				; esi = jy

	; --- src_x, src_y for the variant within the atlas ---
	; slot = ATLAS_BLOOD_BASE + variant 
	mov eax, r15d
	add eax, ATLAS_BLOOD_BASE
	xor edx, edx
	mov ecx, ATLAS_COLS
	div ecx						; eax = row, edx = col 
	imul edx, TILE_SIZE			; src_x
	imul eax, TILE_SIZE			; src_y
	mov [rsp + 0], edx			; src_x stashed
	mov [rsp + 4], eax			; src_y stashed

	; --- dst_x = tx*TILE_SIZE + jx, dst_y = ty*TILE_SIZE + jy ---
	mov ecx, r12d
	imul ecx, TILE_SIZE
	add ecx, edi				; +jx
	mov [rsp + 8], ecx

	mov ecx, r13d
	imul ecx, TILE_SIZE
	add ecx, esi				; +jy
	mov [rsp + 12], ecx

	; --- bake via blit_texture_rect_keyed_into ---
	; signature:
	;	rdi = src tex	rsi = dst tex
	;	edx = src_x		ecx = src_y
	;	r8d = src_w		r9d = src_h
	;	stack: dst_x, dst_y, colour_key
	lea rdi, [atlas_tex]
	lea rsi, [blood_fb]
	mov edx, [rsp + 0]
	mov ecx, [rsp + 4]
	mov r8d, TILE_SIZE
	mov r9d, TILE_SIZE

	mov eax, BLOOD_KEY
	push rax				; key
	mov eax, [rsp + 8 + 12]	; +8 for the just-pushed key
	push rax				; dst_y
	mov eax, [rsp + 16 + 8] ;+16 for two pushes,+8 to skip dst_y slot
	push rax				; dst_x
	call blit_texture_rect_keyed_into
	add rsp, 24
  
	add rsp, 24
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
.out:
	ret

;================================================================
; blood_splat_at_pixel: tile-resolve a pixel coord then bump 
;----------------------------------------------------------------
; in:	edi = px, esi = py.  floor-divide for negatives matches
;		tile_at_pixel
;================================================================
blood_splat_at_pixel:
	push rbp
	mov rbp, rsp
	mov eax, edi
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	test edx, edx
	jns .x_ok
	dec eax
.x_ok:
	mov edi, eax
	mov eax, esi
	cdq
	idiv ecx
	test edx, edx
	jns .y_ok
	dec eax
.y_ok:
	mov esi, eax
	call blood_splat_at_tile
	pop rbp
	ret

;================================================================
; blood_age_tick: called every frame from main.  bumps an internal
; counter; when it hits BLOOD_AGE_TICK_FRAMES, walks every tile
; decrementing age
; tiles that hit 0 get their 16x16 region in blood_fb cleared again
;================================================================
blood_age_tick:
	mov eax, [blood_age_tick_acc]
	inc eax
	cmp eax, BLOOD_AGE_TICK_FRAMES
	jl .save_acc
	xor eax, eax
	mov [blood_age_tick_acc], eax
	jmp .sweep
.save_acc:
	mov [blood_age_tick_acc], eax
	ret

.sweep:
	push rbx
	push r12
	push r13
	push r14
	sub rsp, 8				; ret 8 + 4 push 32 + sub 8 = 48, aligned

	xor r12d, r12d			; r12 = ty
.row:
	cmp r12d, MAP_HEIGHT
	jge .done
	xor r13d, r13d			; r13 = tx
.col:
	cmp r13d, MAP_WIDTH
	jge .next_row

	mov eax, r12d
	imul eax, MAP_WIDTH
	add eax, r13d
	lea rcx, [blood_age]
	movzx r14d, byte [rcx + rax]
	test r14d, r14d
	jz .next_col

	dec r14d
	mov byte [rcx + rax], r14b
	test r14d, r14d
	jnz .next_col

	; expired - clear this tile's region
	mov edi, r13d
	mov esi, r12d
	call blood_clear_tile_region

.next_col:
	inc r13d
	jmp .col
.next_row:
	inc r12d
	jmp .row
.done:
	add rsp, 8
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; blood_clear_tile_region
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
;================================================================
blood_clear_tile_region:
	test edi, edi
	js .out
	cmp edi, MAP_WIDTH
	jge .out
	test esi, esi
	js .out
	cmp esi, MAP_HEIGHT
	jge .out

	push rbx
	push r12

	; top-left pixel byte offset
	mov eax, esi				; ty
	imul eax, TILE_SIZE			; py
	imul eax, BLOOD_FB_PITCH_PX
	mov ecx, edi				; tx
	imul ecx, TILE_SIZE			; px
	add eax, ecx				; eax = pixel index (dwords)
	shl rax, 2					; -> byte offset
	lea rbx, [blood_fb_pixels]
	add rbx, rax

	mov r12, rbx
	mov edx, TILE_SIZE			; rows to fill
.row_loop:
	mov rdi, r12
	mov ecx, TILE_SIZE
	mov eax, BLOOD_KEY
	rep stosd
	add r12, BLOOD_FB_PITCH_PX * 4
	dec edx
	jnz .row_loop

	pop r12
	pop rbx
.out:
	ret

;================================================================
; blood_draw_all: blit the visible camera window of blood_fb to the
; screen framebuffer. ONE keyed blit per frame rather than per-blood
;----------------------------------------------------------------
; in:	rdi = ptr to atlas texture
;================================================================
blood_draw_all:
	; signature of blit_texture_rect_keyed:
	;	rdi = src tex	esi = src_x	edx = src_y
	;	ecx = src_w		r8d = src_h	r9d = dst_x
	;	stack: dst_y, flip_x, colour_key

	lea rdi, [blood_fb]
	mov esi, [camera_x]
	mov edx, [camera_y]
	mov ecx, WINDOW_W
	mov r8d, WINDOW_H
	mov r9d, 0					; dst_x = 0
	mov eax, BLOOD_KEY
	push rax					; key
	push 0						; flip_x
	push 0						; dst_y
	call blit_texture_rect_keyed
	add rsp, 24
	ret

%endif
