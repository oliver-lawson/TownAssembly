; fogofwar.inc.asm
;----------------------------------------------------------------
; per-tile visibility state, ws, 1 byte per tile seen status:
;	FOW_UNSEEN / FOW_EXPLORED / FOW_VISIBLE
;
; lifecycle each frame:
;	1. fow_tick: demote every VISIBLE -> EXPLORED tile in 1 sweep
;	2. for each "viewer" entity (player + alive heroes), stamp a
;	   circle of VISIBLE around its tile.  stamping also raises
;	   UNSEEN tiles to VISIBLE / EXPLORED when viewer moves away
;
; hooks:
;	- fow_tile_visible(tx, ty)	-> bool, used by spawn to skip
;								   tiles in current line of sight
;	- fow_tile_seen(tx, ty)		-> bool, true if EXPLORED or VISIBLE
;
; draw pass:
;	world-space tinted overlay, like safezone_draw_debug
;	for each pixel we sample the tile state at four hash-jittered
;	points and avg the opacities, then dither and layer some bands
;	like the daynight penumbra stuff.  the points double up on
;	convex corners which looks a bit rounded, my best attempt for
;	now anyway
;----------------------------------------------------------------

%ifndef FOGOFWAR_INC
%define FOGOFWAR_INC

%define FOW_UNSEEN		0
%define FOW_EXPLORED	1
%define FOW_VISIBLE		2

; heroes' bigger fov.  we want the player to not be exploring, so
; keeping this small, but mostly it's just to lessen annoying changes
; between VISIBLE/EXPLORED around base constantly changing
%define FOW_PLAYER_R		7
%define FOW_PLAYER_R_SQ		(FOW_PLAYER_R * FOW_PLAYER_R)
%define FOW_HERO_R			9
%define FOW_HERO_R_SQ		(FOW_HERO_R * FOW_HERO_R)

%define FOW_COL_OPAQUE		0xFF000000
%define FOW_COL_ALPHA		0xFF000000; leftover of coloured fog test

section .data
	log_msg_fow_off		db "fow: revealed all", 0
	log_msg_fow_on		db "fow: normal", 0
	log_msg_fow_dbg		db "fow debug overlay toggled", 0

	align 4
	fow_opacity_lut		db 255, 128, 0, 0

section .bss
	fow_mask		resb MAP_WIDTH * MAP_HEIGHT
	fow_reveal_all	resb 1

section .text

;================================================================
; fow_init: mark everything unseen. called @ start/F5
;----------------------------------------------------------------
; also force a visible region around player before fow_tick runs
; for paused start screen
;================================================================
fow_init:
	push rdi
	push rcx
	lea rdi, [fow_mask]
	mov ecx, MAP_WIDTH * MAP_HEIGHT
	xor eax, eax
	rep stosb
	mov byte [fow_reveal_all], 0
	pop rcx
	pop rdi

	; call starter circle stamp
	; player tile, player radius. uses same div pattern as fow_tick
	mov eax, [player_x]
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	mov edi, eax
	mov eax, [player_y]
	cdq
	idiv ecx
	mov esi, eax
	mov edx, FOW_PLAYER_R_SQ
	call fow_stamp
	ret

;================================================================
; fow_toggle_reveal_all: console "fow"
;================================================================
fow_toggle_reveal_all:
	xor byte [fow_reveal_all], 1
	cmp byte [fow_reveal_all], 0
	je .off
	lea rdi, [log_msg_fow_off]
	jmp .log
.off:
	lea rdi, [log_msg_fow_on]
.log:
	call debug_log
	ret

;================================================================
; fow_tile_at: read mask byte for (tx, ty)
;----------------------------------------------------------------
; in:  edi = tx, esi = ty
;out:  eax = FOW_* value, 0 if oob
;================================================================
fow_tile_at:
	test edi, edi
	js .oob
	test esi, esi
	js .oob
	cmp edi, MAP_WIDTH
	jge .oob
	cmp esi, MAP_HEIGHT
	jge .oob
	mov eax, esi
	imul eax, MAP_WIDTH
	add eax, edi
	lea rcx, [fow_mask]
	movzx eax, byte [rcx + rax]
	ret
.oob:
	xor eax, eax
	ret

;================================================================
; fow_tile_visible: easy predicate for spawn/AI gating
;----------------------------------------------------------------
; in:  edi = tx, esi = ty
;out:  eax = 1 if FOW_VISIBLE (or reveal_all on), else 0
;================================================================
fow_tile_visible:
	cmp byte [fow_reveal_all], 0
	je .normal
	mov eax, 1
	ret
.normal:
	call fow_tile_at
	cmp eax, FOW_VISIBLE
	jne .no
	mov eax, 1
	ret
.no:
	xor eax, eax
	ret

;================================================================
; fow_tile_seen: true for either EXPLORED or VISIBLE
;----------------------------------------------------------------
; in:  edi = tx, esi = ty
;out:  eax = 1 if seen at any point, else 0
;================================================================
fow_tile_seen:
	cmp byte [fow_reveal_all], 0
	je .normal
	mov eax, 1
	ret
.normal:
	call fow_tile_at
	test eax, eax
	jz .no
	mov eax, 1
	ret
.no:
	xor eax, eax
	ret

;================================================================
; fow_demote_visible: pass 1 of fow_tick.  any tile currently
; FOW_VISIBLE becomes FOW_EXPLORED.  unseen tiles stay unseen
;================================================================
fow_demote_visible:
	push rcx
	push rdi
	lea rdi, [fow_mask]
	mov ecx, MAP_WIDTH * MAP_HEIGHT
.loop:
	movzx eax, byte [rdi]
	cmp eax, FOW_VISIBLE
	jne .skip
	mov byte [rdi], FOW_EXPLORED
.skip:
	inc rdi
	dec ecx
	jnz .loop
	pop rdi
	pop rcx
	ret

;================================================================
; fow_stamp: mark a filled disc of tiles around (cx, cy) as
; FOW_VISIBLE.  no line-of-sight test atm - radius-only TODO: try
;----------------------------------------------------------------
; in: edi = cx tile, esi = cy tile, edx = radius_sq
;================================================================
fow_stamp:
	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 8

	mov r12d, edi		; cx
	mov r13d, esi		; cy
	mov r14d, edx		; r_sq
	mov ecx, 1
.find_r:
	mov eax, ecx
	imul eax, ecx
	cmp eax, r14d
	jge .have_r
	inc ecx
	cmp ecx, 32
	jl .find_r
.have_r:
	mov r15d, ecx		; r

	; box bounds clamped to map
	mov ebx, r12d
	sub ebx, r15d
	test ebx, ebx
	jns .x0_ok
	xor ebx, ebx
.x0_ok:
	mov [rsp], ebx		; x0

	mov ebx, r12d
	add ebx, r15d
	cmp ebx, MAP_WIDTH - 1
	jle .x1_ok
	mov ebx, MAP_WIDTH - 1
.x1_ok:
	mov [rsp+4], ebx	; x1

	mov ebx, r13d
	sub ebx, r15d
	test ebx, ebx
	jns .y0_ok
	xor ebx, ebx
.y0_ok:
	; y0 in ebx
	mov edi, ebx		; reuse edi as y walker

	mov ebx, r13d
	add ebx, r15d
	cmp ebx, MAP_HEIGHT - 1
	jle .y1_ok
	mov ebx, MAP_HEIGHT - 1
.y1_ok:
	; y1 in ebx, y walker in edi
.row:
	cmp edi, ebx
	jg .done

	; dy = edi - r13d (signed)
	mov eax, edi
	sub eax, r13d
	imul eax, eax		; dy_sq
	mov r8d, eax		; r8 = dy_sq

	mov esi, [rsp]		; x walker
.col:
	cmp esi, [rsp+4]
	jg .row_done

	mov eax, esi
	sub eax, r12d
	imul eax, eax		; dx_sq
	add eax, r8d		; dist_sq
	cmp eax, r14d
	jg .col_next

	; set tile to VISIBLE
	mov eax, edi
	imul eax, MAP_WIDTH
	add eax, esi
	lea rcx, [fow_mask]
	mov byte [rcx + rax], FOW_VISIBLE

.col_next:
	inc esi
	jmp .col
.row_done:
	inc edi
	jmp .row

.done:
	add rsp, 8
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; fow_tick: called once per frame from main loop
;----------------------------------------------------------------
; demote, then stamp visibility around player + every alive hero
;================================================================
fow_tick:
	push rbx
	push r12

	; cheats - skip processing entirely
	cmp byte [fow_reveal_all], 0
	jne .out

	call fow_demote_visible

	; --- player stamp ---
	; player tile = player_x / TILE_SIZE
	mov eax, [player_x]
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	mov edi, eax
	mov eax, [player_y]
	cdq
	idiv ecx
	mov esi, eax
	mov edx, FOW_PLAYER_R_SQ
	call fow_stamp

	; --- alive heroes ---
	mov r12d, 1 ; skip entity 0 (player, already stamped)
.next:
	mov ebx, [entity_count]	; re-read each iter; we clobber ebx below
	cmp r12d, ebx
	jge .out
 
	mov edi, r12d
	call entity_ptr
	; check alive
	movzx ecx, byte [rax + ENT_FLAGS_OFFSET]
	test ecx, ENT_FLAG_ALIVE
	jz .skip 
	; check type is hero
	movzx ecx, byte [rax + ENT_TYPE_OFFSET]
	cmp ecx, ENT_TYPE_HERO
	jne .skip 

	; tile coords - nb the first cdq we'd do for x trashes
	; edx, which is where the y read would have gone.  stash y in
	; a callee-saved reg before any cdq runs
	mov edi, [rax + ENT_X_OFFSET] ; edi = x (will become eax->tile)
	mov ebx, [rax + ENT_Y_OFFSET] ; ebx = y, parked across the divs
	mov eax, edi
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	mov edi, eax					; edi = tx
	mov eax, ebx
	cdq
	idiv ecx
	mov esi, eax					; esi = ty
	mov edx, FOW_HERO_R_SQ
	call fow_stamp

.skip:
	inc r12d
	jmp .next

.out:
	pop r12
	pop rbx
	ret

;================================================================
; fow_hash32: deterministic int hash of (x, y) -> u32 in eax
; source: https://stackoverflow.com/posts/37221804/revisions
;----------------------------------------------------------------
; in:	edi = x, esi = y (can be negative - we treat as unsigned)
; out:	eax = prng 32-bit value
; clb:	eax, edx
;================================================================
fow_hash32:
	mov eax, edi
	imul eax, 374761393
	mov edx, esi
	imul edx, 668265263
	xor eax, edx
	mov edx, eax
	shr edx, 13
	xor eax, edx
	imul eax, 1274126177
	mov edx, eax
	shr edx, 16
	xor eax, edx
	ret

;================================================================
; fow_draw_overlay:
;----------------------------------------------------------------
; world-aligned bayer (uses world coords mod 4) so dither
; doesn't move as the camera scrolls - same trick as in daynight
;
; three darkness bands:
;	full   - fully black, for unseen interiors
;	heavy  - fb * 1/2, mid step between unseen and explored
;	light  - fb * 3/4, for explored interiors (slight dim)
;	clear  - no overlay, for visible tiles
;================================================================

; how far the sample offsets wobble
%define FOW_BAND_R			16

; clamp a 32-bit register to [-FOW_BAND_R, +FOW_BAND_R]
; trying a nasm macro as reused 4 times below
%macro CLAMP_BAND 1
	cmp %1, FOW_BAND_R
	jle %%hi_ok
	mov %1, FOW_BAND_R
%%hi_ok:
	cmp %1, -FOW_BAND_R
	jge %%lo_ok
	mov %1, -FOW_BAND_R
%%lo_ok:
%endmacro

; reads the tile at (wx OP [rsp+dx_slot], wy OP [rsp+dy_slot]) >> 4,
; where OP is add or sub.  state -> opacity via the LUT
; accumulates opacity into ebp, tracks max opacity in r12d
;
; in:	r14d = wx, r13d = wy already set; r12d/ebp = accumulators
; clb:	edi, esi, eax, ecx
%macro FOW_SAMPLE 3
	mov edi, r14d
	%1 edi, [rsp+%2]
	sar edi, 4
	mov esi, r13d
	%1 esi, [rsp+%3]
	sar esi, 4
	call fow_lookup_state
	movzx eax, byte [fow_opacity_lut + rax]
	add ebp, eax
	cmp eax, r12d
	cmovg r12d, eax
%endmacro

fow_draw_overlay:
	cmp byte [fow_reveal_all], 0
	jne .out

	push rbx
	push rbp
	push r12
	push r13
	push r14
	push r15
	sub rsp, 40 ; 6 pushes (48) + ret (8) = 56; +40 = 96
	; aligned, scratch slots:
	;   [rsp+ 0] py (0..WINDOW_H)
	;   [rsp+ 4] wy = py + camera_y
	;   [rsp+ 8] fb row byte offset
	;   [rsp+12] (bayer row * 4) base index
	;   [rsp+16] camera_x cached
	;   [rsp+20] camera_y cached
	;   [rsp+24] dx1 (clamped pair-1 offset)
	;   [rsp+28] dy1
	;   [rsp+32] dx2 (clamped pair-2 offset)
	;   [rsp+36] dy2

	mov eax, [camera_x]
	mov [rsp+16], eax
	mov eax, [camera_y]
	mov [rsp+20], eax

	xor eax, eax
	mov [rsp+0], eax				; py = 0

.row:
	mov eax, [rsp+0]
	cmp eax, WINDOW_H
	jge .done

	; wy = py + camera_y
	add eax, [rsp+20]
	mov [rsp+4], eax				; wy

	; fb row base = py * FB_PITCH
	mov eax, [rsp+0]
	imul eax, FB_PITCH
	mov [rsp+8], eax

	; bayer row index = (wy & 3) * 4 (world aligned not camera)
	mov eax, [rsp+4]
	and eax, 3
	shl eax, 2
	mov [rsp+12], eax

	xor r15d, r15d					; px = 0
.col:
	cmp r15d, WINDOW_W
	jge .row_done

	; wx = px + camera_x
	mov r14d, r15d
	add r14d, [rsp+16]				; r14 = wx
	mov r13d, [rsp+4]				; r13 = wy

	; 4 samples: two corner pairs at +/-(dx1,dy1) and +/-(dx2,dy2)
	mov edi, r14d
	sar edi, 1						; cx (coarse so adjacent
	mov esi, r13d					; pixels share noise)
	sar esi, 1						; cy
	call fow_hash32
	mov ebx, eax					; ebx = coarse hash

	; pair 1 (dx1, dy1) from low bits.  rsp+24..36 holds the four
	; offsets across the lookup calls
	mov ecx, ebx 
	and ecx, 15
	sub ecx, 8
	CLAMP_BAND ecx
	mov [rsp+24], ecx				; dx1

	mov ecx, ebx 
	shr ecx, 4
	and ecx, 15
	sub ecx, 8
	CLAMP_BAND ecx
	mov [rsp+28], ecx				; dy1

	; pair 2 (dx2, dy2) from higher bits - independent of pair 1
	mov ecx, ebx 
	shr ecx, 8
	and ecx, 15
	sub ecx, 8
	CLAMP_BAND ecx
	mov [rsp+32], ecx				; dx2

	mov ecx, ebx 
	shr ecx, 12
	and ecx, 15
	sub ecx, 8
	CLAMP_BAND ecx
	mov [rsp+36], ecx				; dy2

	; accumulators across the four lookups:
	;	ebp = sum of opacities (0..1020)
	;	r12d = max opacity seen (used to gate the heavy band:
	;		   only allow heavy/opaque when an unseen sample
	;		   was present(r12d reached 255)
	xor ebp, ebp
	xor r12d, r12d

	; four samples: two opposite cornerpairs.  FOW_SAMPLE macro
	; reads (wx +/- dx, wy +/- dy), looks up the tile state, maps to
	; opacity via the LUT and accumulates
	FOW_SAMPLE add, 24, 28			; +dx1, +dy1
	FOW_SAMPLE sub, 24, 28			; -dx1, -dy1
	FOW_SAMPLE add, 32, 36			; +dx2, +dy2
	FOW_SAMPLE sub, 32, 36			; -dx2, -dy2

	; ebp = sum 0..1020.  three exact values mean "all 4 samples
	; agree" - fast path skipping the bayer work:
	;	0    -> all visible
	;	512  -> all explored (4 * 128)
	;	1020 -> all unseen   (4 * 255)
	test ebp, ebp
	jz .col_next
	cmp ebp, 512
	je .paint_light
	cmp ebp, 1020
	je .paint_opaque

	; --- boundary: dither against bayer using avg opacity ---
	mov eax, ebp
	shr eax, 2						; avg = sum / 4, range 0..255

	; bayer threshold at this pixel - world x for the world align
	mov ecx, r14d
	and ecx, 3
	add ecx, [rsp+12]				; row_off + col_off in 0..15
	lea r8, [bayer4x4edged]
	movzx ecx, byte [r8 + rcx]		; ecx = bayer 0..192

	; 4 band bayer wobbles, for some ramping between dithers
	shr ecx, 2						; ecx = bayer / 4, range 0..48

	cmp r12d, 255
	jne .try_light					; vis<->explored: light only

	mov esi, ecx
	add esi, 160
	cmp eax, esi
	jge .paint_opaque

	mov esi, ecx
	add esi, 96
	cmp eax, esi
	jge .paint_heavy

.try_light:
	mov esi, ecx
	add esi, 32
	cmp eax, esi
	jge .paint_light
	jmp .col_next

.paint_opaque:
	lea rcx, [framebuffer]
	mov eax, [rsp+8]
	add rcx, rax
	mov dword [rcx + r15*4], FOW_COL_OPAQUE
	jmp .col_next

.paint_heavy:
	; fb * 1/2.  half the brightness of original pixel
	; - softer step band between full black and the explored tint
	lea rcx, [framebuffer]
	mov eax, [rsp+8]
	add rcx, rax
	mov edx, [rcx + r15*4]
	shr edx, 1
	and edx, 0x7F7F7F7F				; fb/2
	or  edx, FOW_COL_ALPHA
	mov [rcx + r15*4], edx
	jmp .col_next

.paint_light:
	; fb * 3/4.  slight darken for explored tiles
	lea rcx, [framebuffer]
	mov eax, [rsp+8]
	add rcx, rax
	mov edx, [rcx + r15*4]	; fb

	mov eax, edx
	shr eax, 2
	and eax, 0x3F3F3F3F		; fb/4

	mov ebx, edx
	shr ebx, 1
	and ebx, 0x7F7F7F7F		; fb/2

	add eax, ebx			; fb*3/4
	or  eax, FOW_COL_ALPHA
	mov [rcx + r15*4], eax

.col_next:
	inc r15d
	jmp .col

.row_done:
	inc dword [rsp+0]
	jmp .row

.done:
	add rsp, 40
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbp
	pop rbx
.out:
	ret

;================================================================
; fow_lookup_state: read fow_mask at tile (tx, ty), oob -> UNSEEN
;----------------------------------------------------------------
; in:	edi = tx, esi = ty (can be negative)
; out:	eax = FOW_UNSEEN / FOW_EXPLORED / FOW_VISIBLE
; clb:	eax, ecx
;----------------------------------------------------------------
; small helper so the overlay loop body stays readable.  the inner
; loop calls this twice per pixel
;================================================================
fow_lookup_state:
	test edi, edi
	js .oob
	cmp edi, MAP_WIDTH
	jge .oob
	test esi, esi
	js .oob
	cmp esi, MAP_HEIGHT
	jge .oob
	mov eax, esi
	imul eax, MAP_WIDTH
	add eax, edi
	lea rcx, [fow_mask]
	movzx eax, byte [rcx + rax]
	ret
.oob:
	mov eax, FOW_UNSEEN
	ret

%endif
