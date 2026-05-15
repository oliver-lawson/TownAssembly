; bloodmap.inc.asm - per-tile blood-splatter overlay
;----------------------------------------------------------------
; when an entity takes damage we drop a blood mark on its tile.
; each tile has a count byte (0..BLOOD_MAX_PER_TILE) tracking how
; many marks have been placed there.  rendering walks all visible
; tiles and stacks `count` blood sprites with a per-tile-hashed
; starting index, cycling through the 16 sprite variants
;
; a tile that's seen 1 hit shows 1 splatter, subsequent drops
; layer on top, until count is saturated.  randomly offset a bit,
; and with 16 variants, looks great
;----------------------------------------------------------------
; storage:
;	blood_count	1 byte per tile (0..BLOOD_MAX_PER_TILE)
%ifndef BLOODMAP_INC
%define BLOODMAP_INC

; cap at the number of variants so we never overshoot the row.  we
; also use & (BLOOD_VARIANT_COUNT-1) as the cycle mask in
; blood_draw_all - so i'm keeping BLOOD_VARIANT_COUNT a power of two
%define BLOOD_VARIANT_COUNT	16
%define BLOOD_MAX_PER_TILE	16

%define ATLAS_BLOOD_BASE	(4 * ATLAS_COLS + 0)

section .bss
	alignb 1
	blood_count		resb MAP_WIDTH * MAP_HEIGHT

section .text

;================================================================
; blood_clear: wipe the bloodmap (called @ world regen)
;================================================================
blood_clear:
	push rdi
	push rcx
	push rax
	lea rdi, [blood_count]
	mov ecx, MAP_WIDTH * MAP_HEIGHT
	xor eax, eax
	rep stosb
	pop rax
	pop rcx
	pop rdi
	ret

;================================================================
; blood_splat_at_tile: bump the count at (tx, ty), capped
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
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

	mov eax, esi
	imul eax, MAP_WIDTH
	add eax, edi
	lea rdx, [blood_count]
	movzx ecx, byte [rdx + rax]
	cmp ecx, BLOOD_MAX_PER_TILE
	jge  .out
	inc ecx
	mov [rdx + rax], cl
.out:
	ret

;================================================================
; blood_splat_at_pixel: tile-resolve a pixel coord then bump 
;----------------------------------------------------------------
; in:	edi = px, esi = py.  uses floor-divide so negatives go to
;		the right tile (matches tile_at_pixel)
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
; blood_tile_hash: cheap 0..255 hash of (tx, ty). used to pick a
; per-tile starting sprite so neighbouring tiles look different
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = hash byte (0..255)
;================================================================
blood_tile_hash:
	mov eax, edi
	imul eax, 73
	mov ecx, esi
	imul ecx, 137
	add eax, ecx
	and eax, 0xFF
	ret
 

;================================================================
; blood_draw_all: render stacked blood splatters across the
; visible tile range
;----------------------------------------------------------------
; called from main between draw_objects and draw_entities for z
;
; for each tile with count > 0:
;	hash = blood_tile_hash(tx, ty)
;	for (i in 0..count-1):
;		slot = ATLAS_BLOOD_BASE + ((hash + i) & 7) 
;		blit slot at the tile position with magenta key
;----------------------------------------------------------------
; in:	rdi = ptr to atlas texture
;----------------------------------------------------------------
; locals (rbp-relative, mirrors draw_objects):
;	[rbp-4]		ty walker
;	[rbp-8]		tx walker
;	[rbp-16]	atlas tex ptr
;	[rbp-20]	ty_min
;	[rbp-24]	ty_max
;	[rbp-28]	tx_min
;	[rbp-32]	tx_max
;	[rbp-36]	per-tile hash (set inside the tile loop)
;================================================================
blood_draw_all:
	push rbp
	mov rbp, rsp
	sub rsp, 48
	push rbx
	push r12
	push r13
	push r14
	push r15
	; 5 callee saves (40) + sub 48 + ret (8) + rbp (8) = 104, 16-aligned 

	mov [rbp-16], rdi

	; --- visible tile range ---
	mov eax, [camera_x]
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	test edx, edx
	jns .tx_min_ok
	dec eax
.tx_min_ok:
	test eax, eax
	jns .tx_min_clamped
	xor eax, eax
.tx_min_clamped:
	mov [rbp-28], eax

	mov eax, [camera_x]
	add eax, WINDOW_W
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	add eax, 1
	cmp eax, MAP_WIDTH
	jle .tx_max_ok
	mov eax, MAP_WIDTH
.tx_max_ok:
	mov [rbp-32], eax

	mov eax, [camera_y]
	cdq
	idiv ecx
	test edx, edx
	jns .ty_min_ok
	dec eax
.ty_min_ok:
	test eax, eax
	jns .ty_min_clamped
	xor eax, eax
.ty_min_clamped:
	mov [rbp-20], eax

	mov eax, [camera_y]
	add eax, WINDOW_H
	cdq
	idiv ecx
	add eax, 1
	cmp eax, MAP_HEIGHT
	jle .ty_max_ok
	mov eax, MAP_HEIGHT
.ty_max_ok:
	mov [rbp-24], eax

	mov eax, [rbp-20]
	mov [rbp-4], eax
.row:
	mov eax, [rbp-4]
	cmp eax, [rbp-24]
	jge .done

	mov eax, [rbp-28]
	mov [rbp-8], eax
.col:
	mov eax, [rbp-8]
	cmp eax, [rbp-32]
	jge .next_row

	; --- count for this tile ---
	mov eax, [rbp-4]
	imul eax, MAP_WIDTH
	add eax, [rbp-8]
	lea rbx, [blood_count] 
	movzx r12d, byte [rbx + rax] ; r12 = count
	test r12d, r12d
	jz .next_col

	; --- per-tile starting hash ---
	mov edi, [rbp-8]
	mov esi, [rbp-4]
	call blood_tile_hash
	mov [rbp-36], eax

	; --- draw {count} stacked splats ---
	; r13d = i in 0..count-1.  for each, atlas slot =
	; ATLAS_BLOOD_BASE + ((hash + i) & 7), then blit it at the tile.
	xor r13d, r13d
.splat:
	cmp r13d, r12d
	jge .next_col

	; slot index in the row.  ATLAS_BLOOD_BASE points at row 4 col 0,
	; the 16 variants span cols 0..15.  derive (hash + i) &
	; (BLOOD_VARIANT_COUNT-1) to step within that 16-wide window
	mov eax, [rbp-36]
	add eax, r13d
	and eax, BLOOD_VARIANT_COUNT - 1
	; final atlas slot: ATLAS_BLOOD_BASE + variant
	add eax, ATLAS_BLOOD_BASE
	mov r14d, eax

	; slot -> src_x, src_y
	mov eax, r14d
	xor edx, edx
	mov ecx, ATLAS_COLS
	div ecx						; eax = row, edx = col
	imul edx, TILE_SIZE
	imul eax, TILE_SIZE
	; rdi (tex) - rsi (src_x) - edx (src_y) - ecx (src_w) - r8d (src_h)
	; - r9d (dst_x) - stack: dst_y, flip, key
	mov rdi, [rbp-16]
	mov esi, edx
	mov edx, eax
	mov ecx, TILE_SIZE
	mov r8d, TILE_SIZE
	mov r9d, [rbp-8]
	imul r9d, TILE_SIZE
	sub r9d, [camera_x]

	; dst_y
	mov eax, [rbp-4]
	imul eax, TILE_SIZE
	sub eax, [camera_y]

	; --- per-splat jitter (-4..+3 each axis), deterministic ---
	; mix tx, ty, i into one byte then take two 3-bit fields
	; deterministic in (tx, ty, i) so the offsets don't twitch each
	; frame;
	; no offsets stored per tile, they still belong to the tile &
	; this is visual effect only
	mov r11d, [rbp-8]
	imul r11d, 53
	mov r10d, [rbp-4]
	imul r10d, 191
	add r11d, r10d
	mov r10d, r13d
	imul r10d, 97
	add r11d, r10d
	; r11d = mix.  extract jitter x (low 3 bits, -4..+3)
	mov r10d, r11d
	and r10d, 7
	sub r10d, 4
	add r9d, r10d			; dst_x+=jx
	; jitter y (next 3 bits)
	mov r10d, r11d
	shr r10d, 4
	and r10d, 7
	sub r10d, 4
	add eax, r10d			; dst_y+=jy

	mov r10, 0xFFFF00FF		; magenta key
	push r10
	push 0					; flip
	push rax				; dst_y
	call blit_texture_rect_keyed ; draw
	add rsp, 24

	inc r13d
	jmp .splat				; srecurse

.next_col:
	inc dword [rbp-8]
	jmp .col
.next_row:
	inc dword [rbp-4]
	jmp .row
.done:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	leave
	ret

%endif