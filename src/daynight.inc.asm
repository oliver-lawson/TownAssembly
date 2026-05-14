; daynight.inc.asm - day/night with lightmap-based torches
;
; two-pass system:
;	pass 1: build a per-pixel lightmap (0-255) from all visible
;			torches.  each torch stamps a radial falloff into the
;			map, taking max with existing values so overlapping
;			torches don't make ugly additive light
;	pass 2: walk the framebuffer.  for each pixel:
;			- if light==0?: apply full blue-shifted darkness
;			- if light==255?: apply warm glow tint (torch-lit area)
;			- in between: dithered transition using bayer matrix
; so torchlit areas aren't darkened then brightened, but just masked
; from being darkened, then tinted slightly.
;
; the lightmap is screenres bytes, sits in bss,should be small enough

%ifndef DAYNIGHT_INC
%define DAYNIGHT_INC

; --- clock --- 		    demo;fast;normal
%define DAY_CYCLE_LEN		2200;1600;14400
%define DAY_END				800;300;8640
%define DUSK_END			1500;900;10080
%define NIGHT_END			1700;1000;12960

; --- darkness: per-channel subtraction at full night ---
%define NIGHT_SUB_R 		80
%define NIGHT_SUB_G 		60
%define NIGHT_SUB_B 		20
; dithered fringe adds this extra
%define NIGHT_DITHER_EXTRA 	32

; --- warm glow tint applied in torch-lit areas ---
%define GLOW_ADD_R			24
%define GLOW_ADD_G			8
%define GLOW_ADD_B			0
%define GLOW_SUB_B			8

; --- warm band: amber fringe between full dark and full glow ---
; narrow band of warmth, softens the transition to night black a bit
%define WARM_BAND_ADD_R		22
%define WARM_BAND_ADD_G		3
%define WARM_BAND_SUB_B		6

; --- torch ---
%define TORCH_CORE_RADIUS	45
%define TORCH_OUTER_RADIUS	95
%define TORCH_FLICKER_RANGE 55
; animation
%define TORCH_ANIM_FRAMES	8
%define TORCH_ANIM_SPEED	12
%define ATLAS_TORCH_ROW		3

; lightmap dimensions = framebuffer dimensions
%define LM_W	WINDOW_W
%define LM_H	WINDOW_H
%define LM_SIZE (LM_W * LM_H )

; --- shadow casting ---
; for each torch, collect a small list of nearby opaque tiles
; ("occluders")
; then for each occluder, rasterise its shadow polygon
; (trapezoid from torch's POV) into a per-torch shadow
; mask.  the stamp inner loop just checks the mask - O(1) per
; pixel - so cost is occluders * polygon_area, not pixels*occluders
; (tried this per-pixel, finally something that could bring this
; assembly game to slow FPS..)
%define MAX_TORCH_OCCLUDERS	64
; how far past the occluder we extend the shadow, in pixels.
; needs to comfortably cover the torch's outer radius.. mb profile
; if we up the max num and have larger maps, but i'd like to ideally
; do some better offscreening for larger areas before that anyway
%define SHADOW_PROJECT_DIST	(TORCH_OUTER_RADIUS * 2)

section .bss
	alignb 4
	day_clock		resd 1
	; per-frame darkness amounts (set once, used by tint pass)
	night_sub_r		resd 1
	night_sub_g 	resd 1
	night_sub_b 	resd 1
	night_dither_ex resd 1
	night_darkness	resd 1; 0-255 cached for the frame

	; per-torch occluder list, rebuilt before each torch stamp.
	; each entry is 4 int32s:x_left, y_top, x_right, y_bot(screen px)
	alignb 16
	torch_occluders	resd MAX_TORCH_OCCLUDERS * 4
	torch_occ_count	resd 1

	; per-torch shadow mask: 1 byte per screen pixel, 1 = shadowed
	; from this torch's POV.full screen res for simplicity; we only clear/touch the torch's bbox each time
	alignb 16
	torch_shadow_mask resb LM_SIZE

	; the lightmap: one byte per screen pixel, 0=unlit, 255=fully lit
	alignb 16
	lightmap 		resb LM_SIZE

	; toggle to test.  NOT IN USE
	alignb 4
	shadow_disable_entities resb 1

	; --- debug counters, last frame.  read via accessors below ---
	alignb 4
	debug_torches_visible resd 1 ; no of torches stamped this frame
	debug_last_occ_count resd 1 ;occluder count for most recent torch
	debug_max_occ_count	resd 1 ; max torch occluders this frame

section .data
	align 16
	bayer4x4edged:
	;orig
		; db   8, 136,  40, 168
		; db 200,  72, 232, 104
		; db  56, 184,  24, 152
		; db 248, 120, 216,  88
	;clamped:
		; db  32, 128,  64, 160
		; db 192,  96, 192, 128
		; db  64, 160,  32, 128
		; db 192, 128, 192,  96
	;edged & clamped:
		db	 0, 180,  24, 192
		db 192,  48, 192,  72
		db  36, 192,  12, 168
		db 192,  96, 192,  60

	; smooth flicker "wavetable", 64 entries, one full sine-ish cycle
	; values 0-255 representing intensity dip amount
	align 16
	flicker_wave:
		db  0,  1,  3,  6, 10, 16, 22, 29
		db 37, 46, 55, 65, 75, 86, 97,108
		db 119,129,139,149,158,166,174,181
		db 187,193,198,202,206,209,211,213
		db 214,213,211,209,206,202,198,193
		db 187,181,174,166,158,149,139,129
		db 119,108, 97, 86, 75, 65, 55, 46
		db  37, 29, 22, 16, 10,  6,  3,  1

section .text

;================================================================
daynight_tick:
	mov eax, [day_clock]
	inc eax
	cmp eax, DAY_CYCLE_LEN
	jl .no_wrap
	xor eax, eax
.no_wrap:
	mov [day_clock], eax
	ret

daynight_reset:
	mov dword [day_clock], 0
	ret

;================================================================
; daynight_get_darkness: 0 (day) .. 255 (full night)
;================================================================
daynight_get_darkness:
	mov eax, [day_clock]
	cmp eax, DAY_END
	jl .day
	cmp eax, DUSK_END
	jl .dusk
	cmp eax, NIGHT_END
	jl .night
	jmp .dawn
.day:
	xor eax, eax
	ret
.dusk:
	sub eax, DAY_END
	imul eax, 255
	mov ecx, DUSK_END - DAY_END
	xor edx, edx
	div ecx
	ret
.night:
	mov eax, 255
	ret
.dawn:
	mov ecx, DAY_CYCLE_LEN
	sub ecx, eax
	mov eax, ecx
	imul eax, 255
	mov ecx, DAY_CYCLE_LEN - NIGHT_END
	xor edx, edx
	div ecx
	ret

;================================================================
; lightmap_clear: zero out the lightmap (call once per frame
; before stamping torches)
;================================================================
lightmap_clear:
	push rdi
	push rcx
	push rax
	lea rdi, [lightmap]
	mov ecx, LM_SIZE / 4; dwords
	xor eax, eax
	rep stosd
	pop rax
	pop rcx
	pop rdi
	ret

;================================================================
; daynight_toggle_entity_shadows: flip the entity-shadow toggle
;----------------------------------------------------------------
; NOT IN USE atm, leftover from debugging
;================================================================
daynight_toggle_entity_shadows:
	xor byte [shadow_disable_entities], 1
	ret

;================================================================
; torch_build_occluder_list: collect opaque tiles near a torch
;----------------------------------------------------------------
; walks the objectmap inside the torch's outer radius and stuffs
; each non-empty, non-torch tile's screen-space aabb into the
; torch_occluders list.  also skips the torch's own tile so it
; doesn't shadow itself!
;----------------------------------------------------------------
; in:  edi = torch screen_cx (unused, kept for symmetry)
;	   esi = torch screen_cy (unused)
;	   ecx = torch tile_x, edx = torch tile_y
;================================================================
torch_build_occluder_list:
	push rbp
	push rbx
	push r12
	push r13
	push r14
	push r15
	mov rbp, rsp
	sub rsp, 32		; 24 needed + alignment

	; [rbp-4]=torch_tx [rbp-8]=torch_ty
	; [rbp-12]=cam_x [rbp-16]=cam_y
	mov [rbp-4], ecx
	mov [rbp-8], edx

	mov eax, [camera_x]
	mov [rbp-12], eax
	mov eax, [camera_y]
	mov [rbp-16], eax

	; reset count
	mov dword [torch_occ_count], 0

	; --- entity walk FIRST so they get priority in occluders
	jmp .b_ent_start
.b_tile_walk_start:

	; tile-space bbox around the torch (outer radius in tiles, +1)
	mov eax, TORCH_OUTER_RADIUS
	add eax, TILE_SIZE - 1
	xor edx, edx
	mov ecx, TILE_SIZE
	div ecx
	mov r15d, eax		; r15d = radius in tiles (rounded up)

	mov ebx, [rbp-8]
	sub ebx, r15d 
	test ebx, ebx
	jns .by_top_ok
	xor ebx, ebx
.by_top_ok:				; ebx = ty_min

	mov r12d, [rbp-8]
	add r12d, r15d 
	cmp r12d, MAP_HEIGHT
	jl .by_bot_ok
	mov r12d, MAP_HEIGHT - 1
.by_bot_ok:				; r12d = ty_max

	mov r13d, [rbp-4]
	sub r13d, r15d 
	test r13d, r13d
	jns .bx_left_ok
	xor r13d, r13d
.bx_left_ok:			; r13d = tx_min

	mov r14d, [rbp-4]
	add r14d, r15d 
	cmp r14d, MAP_WIDTH
	jl .bx_right_ok
	mov r14d, MAP_WIDTH - 1
.bx_right_ok:			; r14d = tx_max


.b_row:
	cmp ebx, r12d
	jg .b_tiles_done
	mov ecx, r13d
.b_col:
	cmp ecx, r14d
	jg .b_next_row

	; skip the torch's own tile
	cmp ecx, [rbp-4]
	jne .b_check
	cmp ebx, [rbp-8]
	je .b_next_col
.b_check:
	; objectmap[ty*W + tx]
	mov eax, ebx
	imul eax, MAP_WIDTH
	add eax, ecx
	lea rdx, [objectmap]
	movzx eax, byte [rdx + rax]
	test eax, eax
	jz .b_next_col		; empty
	cmp eax, TILE_TORCH
	je .b_next_col		; other torches don't occlude

	; capacity check
	mov edx, [torch_occ_count]
	cmp edx, MAX_TORCH_OCCLUDERS
	jge .b_done			; silently drop the rest

	; tile -> screen aabb
	mov eax, ecx
	imul eax, TILE_SIZE
	sub eax, [rbp-12]
	mov r8d, eax		; sx_left

	mov eax, ebx
	imul eax, TILE_SIZE
	sub eax, [rbp-16]
	mov r9d, eax		; sy_top

	mov r10d, r8d
	add r10d, TILE_SIZE	; sx_right
	mov r11d, r9d
	add r11d, TILE_SIZE	; sy_bot

	; write entry (16 bytes)
	lea rdi, [torch_occluders]
	mov eax, edx
	shl eax, 4
	add rdi, rax
	mov [rdi + 0], r8d
	mov [rdi + 4], r9d
	mov [rdi + 8], r10d
	mov [rdi + 12], r11d

	inc edx
	mov [torch_occ_count], edx

.b_next_col:
	inc ecx
	jmp .b_col
.b_next_row:
	inc ebx
	jmp .b_row
.b_tiles_done:
	; tile walk finished!
	jmp .b_done

.b_ent_start:
	; --- entities first (skip if disabled) ---
	cmp byte [shadow_disable_entities], 0
	jne .b_tile_walk_start

	; bail if list is already full (shouldn't happen since we just
	; reset, but defensive)
	mov eax, [torch_occ_count]
	cmp eax, MAX_TORCH_OCCLUDERS
	jge .b_tile_walk_start

	; torch world centre (world px = tile * TILE_SIZE + half)
	; using this for the in-radius check
	mov r8d, [rbp-4]
	imul r8d, TILE_SIZE
	add r8d, TILE_SIZE / 2		; torch world x

	mov r9d, [rbp-8]
	imul r9d, TILE_SIZE
	add r9d, TILE_SIZE / 2		; torch world y

	mov r10d, [entity_count]
	test r10d, r10d
	jz .b_tile_walk_start

	xor r11d, r11d				; entity index
.b_ent_loop:
	cmp r11d, r10d
	jge .b_tile_walk_start

	; entity_ptr = entity_table + index * ENT_STRIDE
	lea r13, [entity_table]
	mov eax, r11d
	imul eax, ENT_STRIDE
	add r13, rax

	; alive?
	movzx eax, byte [r13 + ENT_FLAGS_OFFSET]
	test eax, ENT_FLAG_ALIVE
	jz .b_ent_next

	; in torch range? chebyshev test on world coords
	;
	; we add SPRITE_SIZE so an entity right at the edge of the
	; torch's reach still casts a partial shadow.not conservative -
	; the rasteriser will clip the shadow region tightly anyway,
	; so over-inclusion should cost almost nothing
	; dx = entity_x - torch_world_x
	mov eax, [r13 + ENT_X_OFFSET]
	sub eax, r8d
	mov edx, eax
	sar edx, 31
	xor eax, edx
	sub eax, edx
	cmp eax, TORCH_OUTER_RADIUS + SPRITE_SIZE
	jg .b_ent_next

	mov eax, [r13 + ENT_Y_OFFSET]
	sub eax, r9d
	mov edx, eax
	sar edx, 31
	xor eax, edx
	sub eax, edx
	cmp eax, TORCH_OUTER_RADIUS + SPRITE_SIZE
	jg .b_ent_next

	; capacity check
	mov edx, [torch_occ_count]
	cmp edx, MAX_TORCH_OCCLUDERS
	jge .b_tile_walk_start

	; convert entity world -> screen bbox.
	; entities are SPRITE_SIZE x SPRITE_SIZE, centred on (x, y)
	;
	; use a slightly smaller bbox (3/4 size) so shadows don't fan
	; super wide for thin sprites, needs a bit of tweaking
	mov eax, [r13 + ENT_X_OFFSET]
	sub eax, [rbp-12]			; cam_x
	; sx_left = sx_centre - half_w
	mov ecx, eax
	sub ecx, SPRITE_SIZE / 3	; ~5 px half-width?
	; sx_right
	add eax, SPRITE_SIZE / 3

	mov esi, [r13 + ENT_Y_OFFSET]
	sub esi, [rbp-16]			; cam_y
	; sy_top
	mov edi, esi
	sub edi, SPRITE_SIZE / 3
	; sy_bot
	add esi, SPRITE_SIZE / 3

	; write entry into torch_occluders[count]
	lea r12, [torch_occluders]
	mov r14d, edx
	shl r14d, 4
	movsxd r14, r14d
	add r12, r14

	mov [r12 + 0],  ecx	; sx_left
	mov [r12 + 4],  edi	; sy_top
	mov [r12 + 8],  eax	; sx_right
	mov [r12 + 12], esi	; sy_bot

	inc edx
	mov [torch_occ_count], edx

.b_ent_next:
	inc r11d
	jmp .b_ent_loop

.b_done:
	add rsp, 32
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret

;================================================================
; helper: ray-vs-single-occluder slab test
;----------------------------------------------------------------
; same idea as before but as a private helper.  fixed-point t
; with FP_ONE = 1024.  no list iteration cos one occluder
;----------------------------------------------------------------
; in:	edi = torch cx, esi = torch cy
;		edx = pixel x, ecx = pixel y
;		r8d = occ x_left, r9d = occ y_top
;		r10d = occ x_right, r11d = occ y_bot
; out:	eax = 1 if blocked, 0 otherwise
; clobbers: eax, plus internally edx/ecx tracking t_enter/t_exit
;================================================================
%define FP_ONE		1024
%define SHADOW_BIAS	32

ray_hits_aabb:
	push rbx
	push r12
	push r13

	; dx, dy
	mov r12d, edx
	sub r12d, edi
	mov r13d, ecx
	sub r13d, esi

	mov eax, r12d
	or eax, r13d
	jz .rh_no

	; don't need pixel coords after computing dx/dy. so reusing:
	; ebx = t_enter
	; edx = t_exit (was pixel x, no longer needed)
	mov ebx, 0
	mov edx, FP_ONE

	; --- x slab ---
	test r12d, r12d
	jnz .rh_x_dir
	cmp edi, r8d
	jl .rh_no
	cmp edi, r10d
	jge .rh_no
	jmp .rh_y
.rh_x_dir:
	push rbx
	push rdx
	push rdi
	push rsi
	mov eax, r8d
	sub eax, edi
	imul eax, FP_ONE
	cdq
	idiv r12d
	mov ecx, eax	; ecx = t1

	mov eax, r10d
	sub eax, edi
	imul eax, FP_ONE
	cdq
	idiv r12d		; eax = t2
	pop rsi
	pop rdi
	pop rdx
	pop rbx

	cmp ecx, eax
	jle .rh_x_sorted
	xchg ecx, eax
.rh_x_sorted:
	; t_enter = max(ebx, ecx); t_exit = min(edx, eax)
	cmp ecx, ebx
	jle .rh_x_e
	mov ebx, ecx
.rh_x_e:
	cmp eax, edx
	jge .rh_x_x
	mov edx, eax
.rh_x_x:
	cmp ebx, edx
	jg .rh_no

.rh_y:
	test r13d, r13d
	jnz .rh_y_dir
	cmp esi, r9d
	jl .rh_no
	cmp esi, r11d
	jge .rh_no
	jmp .rh_test
.rh_y_dir:
	push rbx
	push rdx
	push rdi
	push rsi
	mov eax, r9d
	sub eax, esi
	imul eax, FP_ONE
	cdq
	idiv r13d
	mov ecx, eax

	mov eax, r11d
	sub eax, esi
	imul eax, FP_ONE
	cdq
	idiv r13d
	pop rsi
	pop rdi
	pop rdx
	pop rbx

	cmp ecx, eax
	jle .rh_y_sorted
	xchg ecx, eax
.rh_y_sorted:
	cmp ecx, ebx
	jle .rh_y_e
	mov ebx, ecx
.rh_y_e:
	cmp eax, edx
	jge .rh_y_x
	mov edx, eax
.rh_y_x:
	cmp ebx, edx
	jg .rh_no

.rh_test:
	cmp ebx, SHADOW_BIAS
	jle .rh_no
	cmp ebx, FP_ONE
	jge .rh_no
	mov eax, 1
	pop r13
	pop r12
	pop rbx
	ret
.rh_no:
	xor eax, eax
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; torch_rasterise_shadow_mask: precompute per-torch shadow bitmap
;----------------------------------------------------------------
; clears the torch's bbox in torch_shadow_mask, then for each
; occluder fills its shadow region with 1
;
; the shadow bbox for an occluder is computed by projecting all
; 4 of the occluder's corners through the torch by a fixed scale
; that pushes them well past the torch's outer radius.  taking
; the bbox of those 4 projected points (clipped to torch bbox
; and screen) gives a tight enough region to scan
;----------------------------------------------------------------
; in: edi = torch screen cx, esi = torch screen cy
;================================================================
torch_rasterise_shadow_mask:
	push rbp
	push rbx
	push r12
	push r13
	push r14
	push r15
	mov rbp, rsp
	sub rsp, 64 ; 56 needed + alignment

	; [rbp-4]  = torch cx
	; [rbp-8]  = torch cy
	; [rbp-12] = torch bbox x_min  (clipped to screen)
	; [rbp-16] = torch bbox y_min
	; [rbp-20] = torch bbox x_max
	; [rbp-24] = torch bbox y_max
	; [rbp-28] = occ idx(loop)
	; [rbp-40..-56] = scratch for per-occluder shadow bbox
	mov [rbp-4], edi
	mov [rbp-8], esi

	;torch bbox in screen pixels, clipped to [0, LM_W/LM_H]
	mov eax, edi
	sub eax, TORCH_OUTER_RADIUS
	test eax, eax
	jns .tx_min_clip_ok
	xor eax, eax
.tx_min_clip_ok:
	cmp eax, LM_W
	jl .tx_min_in
	mov eax, LM_W
.tx_min_in:
	mov [rbp-12], eax

	mov eax, esi
	sub eax, TORCH_OUTER_RADIUS
	test eax, eax
	jns .ty_min_clip_ok
	xor eax, eax
.ty_min_clip_ok:
	cmp eax, LM_H
	jl .ty_min_in
	mov eax, LM_H
.ty_min_in:
	mov [rbp-16], eax

	mov eax, edi
	add eax, TORCH_OUTER_RADIUS
	cmp eax, LM_W
	jl .tx_max_clip_ok
	mov eax, LM_W
.tx_max_clip_ok:
	test eax, eax ; clamp to >= 0 (handles torch fully off-left)
	jns .tx_max_pos
	xor eax, eax
.tx_max_pos:
	mov [rbp-20], eax

	mov eax, esi
	add eax, TORCH_OUTER_RADIUS
	cmp eax, LM_H
	jl .ty_max_clip_ok
	mov eax, LM_H
.ty_max_clip_ok:
	test eax, eax
	jns .ty_max_pos
	xor eax, eax
.ty_max_pos:
	mov [rbp-24], eax

	; --- clear the torch bbox in the shadow mask ---
	; bail if bbox is empty (torch fully off-screen)
	mov eax, [rbp-12]
	cmp eax, [rbp-20]
	jge .rsm_done
	mov eax, [rbp-16]
	cmp eax, [rbp-24]
	jge .rsm_done

	mov r12d, [rbp-16]	; y
.rsm_clr_y:
	cmp r12d, [rbp-24]
	jge .rsm_clr_done
	mov eax, r12d
	imul eax, LM_W
	add eax, [rbp-12]
	lea rdi, [torch_shadow_mask]
	add rdi, rax
	mov ecx, [rbp-20]
	sub ecx, [rbp-12]
	xor eax, eax
	cld
	rep stosb
	inc r12d
	jmp .rsm_clr_y
.rsm_clr_done:

	; --- iterate occluders ---
	mov dword [rbp-28], 0
.rsm_occ:
	mov eax, [rbp-28]
	cmp eax, [torch_occ_count]
	jge .rsm_done

	; load this occluder's bbox
	mov eax, [rbp-28]
	shl eax, 4
	lea rbx, [torch_occluders]
	add rbx, rax
	; r8 = ox1, r9 = oy1, r10 = ox2, r11 = oy2
	mov r8d,  [rbx + 0]
	mov r9d,  [rbx + 4]
	mov r10d, [rbx + 8]
	mov r11d, [rbx + 12]

	; compute the projected shadow bbox.  for each of 4 corners,
	; project P = C + (C - T) * SHADOW_SCALE.  using a power-of-2
	; scale (8) lets us shift instead of multiply.
	; shadow bbox is then the min/max of{4 box corners,4 projections}
	;
	; rather than store 8 points, just track running min/max as
	; we go.  start with box bbox..
	mov [rbp-40], r8d		; sb_x_min
	mov [rbp-44], r9d		; sb_y_min
	mov [rbp-48], r10d		; sb_x_max
	mov [rbp-52], r11d		; sb_y_max

	; project each corner: 4 corners of box are (r8,r9), (r10,r9),
	; (r10,r11), (r8,r11)
	; for each: px = cx + (cx-tx)*8, py = cy + (cy-ty)*8
	; iterate manually unrolled

	; corner 1: (r8, r9)
	mov eax, r8d
	sub eax, [rbp-4]
	shl eax, 3
	add eax, r8d		; eax = px1
	cmp eax, [rbp-40]
	jge .c1_no_xmin
	mov [rbp-40], eax
.c1_no_xmin:
	cmp eax, [rbp-48]
	jle .c1_no_xmax
	mov [rbp-48], eax
.c1_no_xmax:
	mov eax, r9d
	sub eax, [rbp-8]
	shl eax, 3
	add eax, r9d		; eax = py1
	cmp eax, [rbp-44]
	jge .c1_no_ymin
	mov [rbp-44], eax
.c1_no_ymin:
	cmp eax, [rbp-52]
	jle .c1_no_ymax
	mov [rbp-52], eax
.c1_no_ymax:

	; corner 2: (r10, r9)
	mov eax, r10d
	sub eax, [rbp-4]
	shl eax, 3
	add eax, r10d
	cmp eax, [rbp-40]
	jge .c2_no_xmin
	mov [rbp-40], eax
.c2_no_xmin:
	cmp eax, [rbp-48]
	jle .c2_no_xmax
	mov [rbp-48], eax
.c2_no_xmax:
	mov eax, r9d
	sub eax, [rbp-8]
	shl eax, 3
	add eax, r9d
	cmp eax, [rbp-44]
	jge .c2_no_ymin
	mov [rbp-44], eax
.c2_no_ymin:
	cmp eax, [rbp-52]
	jle .c2_no_ymax
	mov [rbp-52], eax
.c2_no_ymax:

	; corner 3: (r10, r11)
	mov eax, r10d
	sub eax, [rbp-4]
	shl eax, 3
	add eax, r10d
	cmp eax, [rbp-40]
	jge .c3_no_xmin
	mov [rbp-40], eax
.c3_no_xmin:
	cmp eax, [rbp-48]
	jle .c3_no_xmax
	mov [rbp-48], eax
.c3_no_xmax:
	mov eax, r11d
	sub eax, [rbp-8]
	shl eax, 3
	add eax, r11d
	cmp eax, [rbp-44]
	jge .c3_no_ymin
	mov [rbp-44], eax
.c3_no_ymin:
	cmp eax, [rbp-52]
	jle .c3_no_ymax
	mov [rbp-52], eax
.c3_no_ymax:

	; corner 4: (r8, r11)
	mov eax, r8d
	sub eax, [rbp-4]
	shl eax, 3
	add eax, r8d
	cmp eax, [rbp-40]
	jge .c4_no_xmin
	mov [rbp-40], eax
.c4_no_xmin:
	cmp eax, [rbp-48]
	jle .c4_no_xmax
	mov [rbp-48], eax
.c4_no_xmax:
	mov eax, r11d
	sub eax, [rbp-8]
	shl eax, 3
	add eax, r11d
	cmp eax, [rbp-44]
	jge .c4_no_ymin
	mov [rbp-44], eax
.c4_no_ymin:
	cmp eax, [rbp-52]
	jle .c4_no_ymax
	mov [rbp-52], eax
.c4_no_ymax:

	; intersect shadow bbox with torch bbox (already screen-clipped)
	mov eax, [rbp-40]
	cmp eax, [rbp-12]
	jge .sb_xl_ok
	mov eax, [rbp-12]
.sb_xl_ok:
	mov [rbp-40], eax

	mov eax, [rbp-44]
	cmp eax, [rbp-16]
	jge .sb_yl_ok
	mov eax, [rbp-16]
.sb_yl_ok:
	mov [rbp-44], eax

	mov eax, [rbp-48]
	cmp eax, [rbp-20]
	jle .sb_xr_ok
	mov eax, [rbp-20]
.sb_xr_ok:
	mov [rbp-48], eax

	mov eax, [rbp-52]
	cmp eax, [rbp-24]
	jle .sb_yr_ok
	mov eax, [rbp-24]
.sb_yr_ok:
	mov [rbp-52], eax

	; if empty, skip
	mov eax, [rbp-40]
	cmp eax, [rbp-48]
	jge .rsm_occ_next
	mov eax, [rbp-44]
	cmp eax, [rbp-52]
	jge .rsm_occ_next

	;---scan pixels in [sb_x_min, sb_x_max) x [sb_y_min, sb_y_max)---
	mov r14d, [rbp-44]		; y
.rsm_py:
	cmp r14d, [rbp-52]
	jge .rsm_occ_next
	mov r15d, [rbp-40]		; x
.rsm_px:
	cmp r15d, [rbp-48]
	jge .rsm_py_next

	; already shadowed?: skip ray test
	mov eax, r14d
	imul eax, LM_W
	add eax, r15d
	lea rdi, [torch_shadow_mask]
	add rdi, rax
	cmp byte [rdi], 0
	jne .rsm_px_next

	; test ray torch -> pixel against this occluder
	mov edi, [rbp-4]		; torch cx
	mov esi, [rbp-8]		; torch cy
	mov edx, r15d			; pixel x
	mov ecx, r14d			; pixel y
	; r8-r11 still hold occluder bbox - reload defensively
	mov eax, [rbp-28]
	shl eax, 4
	lea rbx, [torch_occluders]
	add rbx, rax
	mov r8d,  [rbx + 0]
	mov r9d,  [rbx + 4]
	mov r10d, [rbx + 8]
	mov r11d, [rbx + 12]
	call ray_hits_aabb
	test eax, eax
	jz .rsm_px_next

	; mark shadowed
	mov eax, r14d
	imul eax, LM_W
	add eax, r15d
	lea rdi, [torch_shadow_mask]
	add rdi, rax
	mov byte [rdi], 1

.rsm_px_next:
	inc r15d
	jmp .rsm_px
.rsm_py_next:
	inc r14d
	jmp .rsm_py

.rsm_occ_next:
	inc dword [rbp-28]
	jmp .rsm_occ

.rsm_done:
	add rsp, 64
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret

;================================================================
; lightmap_stamp_torch: stamp a radial light into the lightmap
;----------------------------------------------------------------
; for each pixel in the torch's radius, compute light intensity
; and take max with the existing lightmap value
; so overlaps don't accum
;
; core (dist <= core_r): light = 255 (fully lit)
; penumbra (core_r < dist <= outer_r): linear falloff 255->0
;
; if the pixel is occluded by a nearby opaque tile (as built by
; torch_build_occluder_list), the stamp is skipped - leaving the
; pixel at whatever value it had from previous torches, or zero
;----------------------------------------------------------------
; in: edi = screen_cx, esi = screen_cy, edx = flicker 0-255
;================================================================
lightmap_stamp_torch:
	push rbp
	push rbx
	push r12
	push r13
	push r14
	push r15
	mov rbp, rsp	; rbp AFTER pushes so locals don't overlap saved regs
	sub rsp, 32		; 24 needed + 8 for alignment

	; [rbp-4]=cx [rbp-8]=cy [rbp-12]=flicker
	mov [rbp-4], edi
	mov [rbp-8], esi
	mov [rbp-12], edx

	mov r12d, edi	; cx
	mov r13d, esi	; cy

	; y bounds
	mov r14d, r13d
	sub r14d, TORCH_OUTER_RADIUS
	test r14d, r14d
	jns .yt_ok
	xor r14d, r14d
.yt_ok:
	mov r15d, r13d
	add r15d, TORCH_OUTER_RADIUS
	cmp r15d, LM_H
	jl .yb_ok
	mov r15d, LM_H - 1
.yb_ok:

.srow:
	cmp r14d, r15d
	jg .sdone

	mov eax, r14d
	sub eax, r13d
	imul eax, eax
	mov ebx, eax	; dy^2

	; x bounds
	mov ecx, r12d
	sub ecx, TORCH_OUTER_RADIUS
	test ecx, ecx
	jns .xl_ok
	xor ecx, ecx
.xl_ok:
	mov edx, r12d
	add edx, TORCH_OUTER_RADIUS
	cmp edx, LM_W
	jl .xr_ok
	mov edx, LM_W - 1
.xr_ok:

	; lightmap row ptr
	mov eax, r14d
	imul eax, LM_W
	add eax, ecx
	lea r8, [lightmap]
	add r8, rax	; r8 = &lightmap[y*W + x_left]
	; parallel shadow mask row ptr in r10
	lea r10, [torch_shadow_mask]
	add r10, rax	; r10 = &mask[y*W + x_left]

	; ecx = cur_x, edx = x_right
.scol:
	cmp ecx, edx
	jg .snext_row

	; dist^2
	mov eax, ecx
	sub eax, r12d
	imul eax, eax
	add eax, ebx	; dist^2

	; outside outer?
	cmp eax, TORCH_OUTER_RADIUS * TORCH_OUTER_RADIUS
	jge .sskip

	mov r9d, eax	; r9d = dist^2

	; core?
	cmp r9d, TORCH_CORE_RADIUS * TORCH_CORE_RADIUS
	jg .spen

	; core: light = flicker (which is 175-255)
	mov eax, [rbp-12]
	jmp .swrite

.spen:
	;penumbra: intensity= flicker * (outer^2-dist^2)/(outer^2-core^2)
	mov eax, TORCH_OUTER_RADIUS * TORCH_OUTER_RADIUS
	sub eax, r9d
	imul eax, [rbp-12]
	push rcx
	push rdx
	mov ecx, (TORCH_OUTER_RADIUS*TORCH_OUTER_RADIUS) \
			- (TORCH_CORE_RADIUS*TORCH_CORE_RADIUS)
	xor edx, edx
	div ecx
	pop rdx
	pop rcx
	; eax = light value 0..flicker

.swrite:
	; shadow precomputed - just read the mask byte
	cmp byte [r10], 0
	jne .sskip

	; max with existing lightmap value
	movzx r9d, byte [r8]
	cmp eax, r9d
	jle .sskip
	mov [r8], al

.sskip:
	inc r8
	inc r10
	inc ecx
	jmp .scol

.snext_row:
	inc r14d
	jmp .srow

.sdone:
	add rsp, 32
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret

;================================================================
; daynight_apply_tint: lightmap-aware night tint + warm glow
;----------------------------------------------------------------
; for each pixel, reads lightmap[x,y]:
;	light == 0?: full darkness (blue-shifted)
;	light >= bayer threshold?: apply warm glow
;	light < bayer threshold?: apply full night darkness
;================================================================
daynight_apply_tint:
	push rbx
	push r12
	push r13
	push r14
	push r15
	push rbp
	mov rbp, rsp
	sub rsp, 40

	call daynight_get_darkness
	test eax, eax
	jz .tint_done
	mov [night_darkness], eax
	mov [rbp-4], eax

	; precompute per-channel darkness amounts
	imul eax, NIGHT_SUB_R
	xor edx, edx
	mov ecx, 255
	div ecx
	mov [night_sub_r], eax
	mov [rbp-8], eax

	mov eax, [rbp-4]
	imul eax, NIGHT_SUB_G
	xor edx, edx
	mov ecx, 255
	div ecx
	mov [night_sub_g], eax
	mov [rbp-12], eax

	mov eax, [rbp-4]
	imul eax, NIGHT_SUB_B
	xor edx, edx
	mov ecx, 255
	div ecx
	mov [night_sub_b], eax
	mov [rbp-16], eax

	mov eax, [rbp-4]
	imul eax, NIGHT_DITHER_EXTRA
	xor edx, edx
	mov ecx, 255
	div ecx
	mov [night_dither_ex], eax
	mov [rbp-20], eax

	lea rbx, [framebuffer]
	lea r15, [lightmap]
	xor r12d, r12d	; y
.ty:
	cmp r12d, WINDOW_H
	jge .tint_done

	; bayer row offset - offset so it kinda sticks to the world,
	; rather than change awkwardly as we move the char/camera around
	; pretty happy with this, looks good
	mov eax, r12d
	add eax, [camera_y]
	and eax, 3
	shl eax, 2
	mov r14d, eax

	xor r13d, r13d ; x
.tx:
	cmp r13d, WINDOW_W
	jge .tny

	; read light level for this pixel
	movzx eax, byte [r15]

	; if light > 0, check bayer to decide lit vs dark
	test eax, eax
	jz .do_dark

	; bayer threshold at this pixel - world x for same reason
	mov ecx, r13d
	add ecx, [camera_x]
	and ecx, 3
	add ecx, r14d
	lea r8, [bayer4x4edged]
	movzx ecx, byte [r8 + rcx]

	; if light >= threshold?:
	cmp eax, ecx
	jge .do_warm

	; warm band
	shr ecx, 1 ; half the bayer threshold
	cmp eax, ecx
	jge .do_warm_band
	; else: still dark

.do_dark:
	; full darkness with blue shift + dithered extra
	mov eax, [rbx]

	; red
	mov ecx, eax
	shr ecx, 16
	and ecx, 0xFF
	sub ecx, [rbp-8]
	jns .dr_ok
	xor ecx, ecx
.dr_ok:
	; green
	mov edx, eax
	shr edx, 8
	and edx, 0xFF
	sub edx, [rbp-12]
	jns .dg_ok
	xor edx, edx
.dg_ok:
	; blue
	mov r8d, eax
	and r8d, 0xFF
	sub r8d, [rbp-16]
	jns .db_ok
	xor r8d, r8d
.db_ok:

	; dithered extra layer (check bayer again for this).  same
	; world-alignment trick - use world x not screen x
	mov eax, r13d
	add eax, [camera_x]
	and eax, 3
	add eax, r14d
	lea r9, [bayer4x4edged]
	movzx eax, byte [r9 + rax]
	cmp [rbp-4], eax
	jle .dskip_dither
	mov r9d, [rbp-20]
	sub ecx, r9d
	jns .dxr_ok
	xor ecx, ecx
.dxr_ok:
	sub edx, r9d
	jns .dxg_ok
	xor edx, edx
.dxg_ok:
	sub r8d, r9d
	jns .dxb_ok
	xor r8d, r8d
.dxb_ok:
.dskip_dither:

	shl ecx, 16
	shl edx, 8
	or ecx, edx
	or ecx, r8d
	or ecx, 0xFF000000 ; inky blackness of night
	mov [rbx], ecx
	jmp .tnx

.do_warm_band:
	; amber fringe: half-strength darkness + warm colour push
	; sits between full dark and full glow for a softer edge
	; warm push is lerped by darkness like main glow
	mov eax, [rbx]

	; red: half darkness then warm push * darkness/255
	mov ecx, eax
	shr ecx, 16
	and ecx, 0xFF
	mov r9d, [rbp-8]
	shr r9d, 1; half the normal r sub
	sub ecx, r9d
	jns .wbr_sub_ok
	xor ecx, ecx
.wbr_sub_ok:
	push rax
	push rdx
	mov eax, WARM_BAND_ADD_R
	imul eax, [rbp-4]
	xor edx, edx
	mov r9d, 255
	div r9d
	mov r9d, eax
	pop rdx
	pop rax
	add ecx, r9d
	cmp ecx, 255
	jle .wbr_ok
	mov ecx, 255
.wbr_ok:
	; green: half darkness then warm push * darkness/255
	mov edx, eax
	shr edx, 8
	and edx, 0xFF
	mov r9d, [rbp-12]
	shr r9d, 1
	sub edx, r9d
	jns .wbg_sub_ok
	xor edx, edx
.wbg_sub_ok:
	push rax
	push rdx
	mov eax, WARM_BAND_ADD_G
	imul eax, [rbp-4]
	xor edx, edx
	mov r9d, 255
	div r9d
	mov r9d, eax
	pop rdx
	pop rax
	add edx, r9d
	cmp edx, 255
	jle .wbg_ok
	mov edx, 255
.wbg_ok:
	; blue: half darkness plus extra sub * darkness/255
	mov r8d, eax
	and r8d, 0xFF
	mov r9d, [rbp-16]
	shr r9d, 1
	sub r8d, r9d
	jns .wbb_sub_ok
	xor r8d, r8d
.wbb_sub_ok:
	push rax
	push rdx
	mov eax, WARM_BAND_SUB_B
	imul eax, [rbp-4]
	xor edx, edx
	mov r9d, 255
	div r9d
	mov r9d, eax
	pop rdx
	pop rax
	sub r8d, r9d
	jns .wbb_ok
	xor r8d, r8d
.wbb_ok:
	shl ecx, 16
	shl edx, 8
	or ecx, edx
	or ecx, r8d
	or ecx, 0xFF000000
	mov [rbx], ecx
	jmp .tnx

.do_warm:
	; warm glow scaled by darkness so it lerps in across dusk
	; at darkness=0 we never reach here (early out), at 255
	; we get the full glow constants
	mov eax, [rbx]

	; red + GLOW_ADD_R * darkness / 255
	mov ecx, eax
	shr ecx, 16
	and ecx, 0xFF
	push rax
	mov eax, GLOW_ADD_R
	imul eax, [rbp-4]; * darkness
	push rdx
	xor edx, edx
	mov r9d, 255
	div r9d
	pop rdx
	add ecx, eax
	pop rax
	cmp ecx, 255
	jle .wr_ok
	mov ecx, 255
.wr_ok:
	; green + GLOW_ADD_G * darkness / 255
	mov edx, eax
	shr edx, 8
	and edx, 0xFF
	push rax
	mov eax, GLOW_ADD_G
	imul eax, [rbp-4]
	push rdx
	xor edx, edx
	mov r9d, 255
	div r9d
	pop rdx
	mov r9d, eax
	pop rax
	add edx, r9d
	cmp edx, 255
	jle .wg_ok
	mov edx, 255
.wg_ok:
	; blue - GLOW_SUB_B * darkness / 255
	mov r8d, eax
	and r8d, 0xFF
	mov eax, GLOW_SUB_B
	imul eax, [rbp-4]
	push rdx
	xor edx, edx
	mov r9d, 255
	div r9d
	pop rdx
	sub r8d, eax
	jns .wb_ok
	xor r8d, r8d
.wb_ok:
	shl ecx, 16
	shl edx, 8
	or ecx, edx
	or ecx, r8d
	or ecx, 0xFF000000
	mov [rbx], ecx

.tnx:
	add rbx, 4
	inc r15	; advance lightmap ptr
	inc r13d
	jmp .tx
.tny:
	inc r12d
	jmp .ty

.tint_done:
	add rsp, 40
	pop rbp
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; torch_flicker_intensity
;----------------------------------------------------------------
; smooth pulsing via a "wave table"
;----------------------------------------------------------------
; in:  edi = tx, esi = ty
; out: eax = 0-255 (light intensity for lightmap_stamp_torch)
;================================================================
torch_flicker_intensity:
	; hash tile coords for a per-torch phase offset
	mov eax, edi
	imul eax, 73
	mov ecx, esi
	imul ecx, 137
	add eax, ecx	; phase = tx*73 + ty*137

	; speed: we want frame_count >> shift where shift
	; varies per torch between 2-4 (slow gentle pulses)
	; derive shift from a second hash of the coords
	mov ecx, edi
	xor ecx, esi
	imul ecx, 53
	and ecx, 3	; 0-3
	add ecx, 2	; shift = 2-5

	; time = frame_count >> shift
	mov r8d, [frame_count]
	shr r8d, cl

	; table index = (time + phase) & 63
	add eax, r8d
	and eax, 63

	; look up the wave value
	lea rcx, [flicker_wave]
	movzx eax, byte [rcx + rax]

	; scale the wave by TORCH_FLICKER_RANGE and map to
	; an intensity: 255 at no dip, (255-range) at max dip
	imul eax, TORCH_FLICKER_RANGE
	mov ecx, 214	; table peak value
	xor edx, edx
	div ecx			; eax = 0..FLICKER_RANGE
	mov ecx, 255
	sub ecx, eax
	mov eax, ecx	; eax = (255-range)..255
	ret

;================================================================
; daynight_draw_all_torches: build lightmap + apply tint
;----------------------------------------------------------------
; this is the single entry point called from main.asm each frame@:
; this clear the lightmap, stamps all visible torches into it,
; then applies the combined tint/glow pass over the framebuffer
;================================================================
daynight_draw_all_torches:
	push rbp
	push rbx
	push r12
	push r13
	push r14
	push r15
	mov rbp, rsp
	sub rsp, 48		; named locals for the inner loop:
					; [rbp-8]  = tile_x of current torch
					; [rbp-16] = tile_y
					; [rbp-24] = torch screen cx
					; [rbp-32] = torch screen cy
					; [rbp-40] = flicker
					; 48 keeps stack 16-aligned

	call daynight_get_darkness
	test eax, eax
	jz .t_done

	; clear and build the lightmap
	call lightmap_clear

	; reset per-frame debug counters
	mov dword [debug_torches_visible], 0
	mov dword [debug_last_occ_count], 0
	mov dword [debug_max_occ_count], 0

	; scan visible tiles for torches (with margin for glow overspill)
	mov eax, [camera_x]
	sub eax, TORCH_OUTER_RADIUS
	cdq 
	mov ecx, TILE_SIZE
	idiv ecx
	dec eax
	test eax, eax
	jns .tx_min_ok
	xor eax, eax
.tx_min_ok:
	mov r12d, eax

	mov eax, [camera_x]
	add eax, WINDOW_W
	add eax, TORCH_OUTER_RADIUS
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	add eax, 2
	cmp eax, MAP_WIDTH
	jle .tx_max_ok
	mov eax, MAP_WIDTH
.tx_max_ok:
	mov r13d, eax

	mov eax, [camera_y]
	sub eax, TORCH_OUTER_RADIUS
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	dec eax
	test eax, eax
	jns .ty_min_ok
	xor eax, eax
.ty_min_ok:
	mov r14d, eax

	mov eax, [camera_y]
	add eax, WINDOW_H
	add eax, TORCH_OUTER_RADIUS
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	add eax, 2
	cmp eax, MAP_HEIGHT
	jle .ty_max_ok
	mov eax, MAP_HEIGHT
.ty_max_ok:
	mov r15d, eax

	mov ebx, r14d
.t_row:
	cmp ebx, r15d
	jge .t_stamp_done
	mov ecx, r12d
.t_col:
	cmp ecx, r13d
	jge .t_next_row

	; objectmap check - any clobbers ok, we re-load ebx/ecx after
	mov eax, ebx
	imul eax, MAP_WIDTH
	add eax, ecx
	lea rdx, [objectmap]
	movzx eax, byte [rdx + rax]
	cmp eax, TILE_TORCH
	jne .t_next_col

	; --- torch found at tile (ecx, ebx) ---
	; stash tile coords to named locals so we can use registers freely
	mov [rbp-8], ecx		; tile_x
	mov [rbp-16], ebx		; tile_y

	; flicker intensity (takes tile coords in edi/esi)
	mov edi, ecx
	mov esi, ebx
	call torch_flicker_intensity
	mov [rbp-40], eax		; flicker

	; screen position
	mov ecx, [rbp-8]
	imul ecx, TILE_SIZE
	add ecx, TILE_SIZE / 2
	sub ecx, [camera_x]
	mov [rbp-24], ecx		; screen cx

	mov edx, [rbp-16]
	imul edx, TILE_SIZE
	add edx, TILE_SIZE / 2
	sub edx, [camera_y]
	mov [rbp-32], edx		; screen cy

	; build the occluder list (ecx=tile_x, edx=tile_y)
	mov ecx, [rbp-8]
	mov edx, [rbp-16]
	; build_occluder_list also expects edi/esi but those are unused
	call torch_build_occluder_list

	; rasterise shadow mask (edi=screen cx, esi=screen cy)
	mov edi, [rbp-24]
	mov esi, [rbp-32]
	call torch_rasterise_shadow_mask

	; stamp the torch (edi/esi=screen pos, edx=flicker)
	mov edi, [rbp-24]
	mov esi, [rbp-32]
	mov edx, [rbp-40]
	call lightmap_stamp_torch

	; debug counters
	inc dword [debug_torches_visible]
	mov eax, [torch_occ_count]
	mov [debug_last_occ_count], eax
	cmp eax, [debug_max_occ_count]
	jle .dbg_max_ok
	mov [debug_max_occ_count], eax
.dbg_max_ok:

	; restore outer loop's ecx (tile_x) and ebx (tile_y)
	mov ecx, [rbp-8]
	mov ebx, [rbp-16]

.t_next_col:
	inc ecx
	jmp .t_col
.t_next_row:
	inc ebx
	jmp .t_row
.t_stamp_done:

	; now apply final lightmap tint!
	call daynight_apply_tint

.t_done:
	add rsp, 48
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret

;================================================================
; torch_pick_anim_frame: per-torch animation with phase offset
;----------------------------------------------------------------
; hashes tile coords to give each torch a different start frame
; AND a different speed multiplier to avoid lockstep
;----------------------------------------------------------------
; in:  edi = tx, esi = ty
; out: eax = frame index (0..TORCH_ANIM_FRAMES-1)
;================================================================
torch_pick_anim_frame:
	; per-torch phase from coord hash - use the full byte range so
	; even hash collisions in low bits still differ in high bits
	mov eax, edi
	imul eax, 2654435761	; knuth multiplicative hash constant
	mov ecx, esi
	imul ecx, 40503
	xor eax, ecx
	mov r9d, eax			; r9d = full hash for reuse

	; phase: take some bits of the hash
	mov ecx, r9d
	and ecx, TORCH_ANIM_FRAMES - 1

	; per-torch speed: derive a 1-3 step variation
	; speed_mult = (hash >> 8) & 3, then we use it as a divisor tweak
	mov r8d, r9d
	shr r8d, 8
	and r8d, 3				; 0..3
	add r8d, TORCH_ANIM_SPEED ; speed = base..base+3 per torch

	; base frame = tile_anim_ticks / speed_for_this_torch
	mov eax, [tile_anim_ticks]
	xor edx, edx
	push rcx
	push r8
	mov ecx, r8d
	div ecx
	pop r8
	pop rcx

	; offset and wrap
	add eax, ecx
	and eax, TORCH_ANIM_FRAMES - 1
	ret

;================================================================
; torch_atlas_slot: atlas index for a given torch's current frame
;----------------------------------------------------------------
; in:  edi = tx, esi = ty
; out: eax = atlas slot
;================================================================
torch_atlas_slot:
	call torch_pick_anim_frame
	add eax, ATLAS_TORCH_ROW * ATLAS_COLS
	ret

%endif