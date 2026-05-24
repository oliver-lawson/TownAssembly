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

; chance (out of 100) the night becomes a siege
; siege nights spike the monster homing bias (see entity_inc.asm)
; so they push toward the hub for an attack wave
%define SIEGE_NIGHT_CHANCE			30

; --- lit-entity overlay ---
; after the tint pass, entities standing in torch light are redrawn
; on top so they pop against the warm-glowed ground.  threshold is
; the min lightmap value at the entity's centre for redraw
%define LIT_OVERLAY_THRESHOLD		88

section .bss
	alignb 4
	day_clock		resd 1
	; 1 = siege night, monsters will push toward hub.
	; rolled at dusk-start, cleared at dawn. read by wander_tick
	; in entity_inc.asm
	siege_active	resb 1
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
	; siege state floattext.  rolled at the day->dusk crossing,
	; cleared at the dawn->day wraparound
	log_msg_siege_on	db "the horde approaches!", 0
	log_msg_siege_off	db "the horde goes home for tea", 0

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
; daynight_tick: increment the day clock + manage the siege flag
;----------------------------------------------------------------
; the clock wraps at DAY_CYCLE_LEN
;	day_clock == DAY_END		(day->dusk transition)
;		roll the siege dice; on success monsters will attack hub
;	day_clock wrapped to 0		(dawn->day transition)
;		clear the siege flag and announce the calm
;
; both edges fire exactly once per cycle because we test right
; after the inc, before any further state can change
;================================================================
daynight_tick:
	mov eax, [day_clock]
	inc eax
	cmp eax, DAY_CYCLE_LEN
	jl .no_wrap
	xor eax, eax
.no_wrap:
	mov [day_clock], eax

	; --- dusk edge: clock just hit DAY_END ---
	cmp eax, DAY_END
	jne .check_dawn
	push rax					; preserve eax/clock across call
	mov edi, 100
	call rng_range
	cmp eax, SIEGE_NIGHT_CHANCE
	jge .siege_skip
	mov byte [siege_active], 1
	lea rdi, [log_msg_siege_on]
	call debug_log
	jmp .pop_eax
.siege_skip:
	; nothing to log, quiet..
	mov byte [siege_active], 0
.pop_eax:
	pop rax

.check_dawn:
	; --- dawn edge: clock just wrapped to 0 ---
	; if the night was a siege, announce the calm
	test eax, eax
	jnz .out
	cmp byte [siege_active], 0
	je .out
	mov byte [siege_active], 0
	sub rsp, 8 ; align (entry rsp%16=8 -> 0)
	lea rdi, [log_msg_siege_off]
	call debug_log
	add rsp, 8
.out:
	ret

daynight_reset:
	mov dword [day_clock], 0
	mov byte [siege_active], 0
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
	; treat anything you can walk through as transparent to light.
	; speed_table[tile_id] == 100 -> open doors, chairs, etc.  this
	; reuses the movement table so we don't keep two truths in sync
	lea rdx, [tile_speed_table]
	movzx edx, byte [rdx + rax]
	cmp edx, 100
	je .b_next_col

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
	call daynight_get_darkness
	test eax, eax
	jz .t_done

	; build the lightmap, then apply the final tint
	call lightmap_build
	call daynight_apply_tint
.t_done:
	ret

;================================================================
; lightmap_build: clear the lightmap then stamp every visible
; torch into it, with shadows.  no tint - just the lit-pixel mask
;----------------------------------------------------------------
; broken out from daynight_draw_all_torches so the safezone debug
; overlay can populate the lightmap regardless of time-of-day
; (the tint pass still gates on darkness)
;================================================================
lightmap_build:
	push rbp
	push rbx
	push r12
	push r13
	push r14
	push r15
	mov rbp, rsp	; rbp AFTER pushes so locals don't overlap saved regs
	sub rsp, 48		; named locals for the inner loop:
					; [rbp-8]  = tile_x of current torch
					; [rbp-16] = tile_y
					; [rbp-24] = torch screen cx
					; [rbp-32] = torch screen cy
					; [rbp-40] = flicker
					; 48 keeps stack 16-aligned

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

;================================================================
; lo_lightmap_rect_max: max lightmap value in screen rect
;----------------------------------------------------------------
; clips the rect to the lightmap's bounds, returns 0 if the rect
; ends up empty (fully offscreen).  used by the lit-overlay
; functions to decide if a thing sits in a lit-enough patch to
; warrant being redrawn on top of the night tint
;----------------------------------------------------------------
; in:  edi = screen x, esi = screen y, edx = w, ecx = h
; out: eax = max lightmap value in clipped rect (0 if empty)
; clobbers: rdi, rsi, rdx, rcx, r8, r9, r10
;================================================================
lo_lightmap_rect_max:
	; clip x: x_lo = max(0, x), x_hi = min(LM_W, x + w)
	mov r8d, edi				; r8d = x_lo
	test r8d, r8d
	jns .lr_xlo_ok
	xor r8d, r8d
.lr_xlo_ok:
	mov r9d, edi
	add r9d, edx				; r9d = x_hi
	cmp r9d, LM_W
	jle .lr_xhi_ok
	mov r9d, LM_W
.lr_xhi_ok:
	cmp r8d, r9d
	jge .lr_empty

	; clip y: y_lo = max(0, y), y_hi = min(LM_H, y + h)
	mov edi, esi				; recycle edi = y_lo
	test edi, edi
	jns .lr_ylo_ok
	xor edi, edi
.lr_ylo_ok:
	mov edx, esi
	add edx, ecx				; edx = y_hi 
	cmp edx, LM_H
	jle .lr_yhi_ok
	mov edx, LM_H
.lr_yhi_ok:
	cmp edi, edx
	jge .lr_empty

	; scan rows.  cur_y in edi, y_end in edx; cur_x scan uses r10
	xor eax, eax				; max so far
.lr_row:
	cmp edi, edx
	jge .lr_done
	mov r10d, r8d				; cur_x = x_lo
	; row start ptr: lightmap + y*LM_W + x_lo
	mov ecx, edi
	imul ecx, LM_W
	add ecx, r10d
	lea rsi, [lightmap]
	add rsi, rcx				; rsi = &lightmap[y*W + x_lo]
.lr_col:
	cmp r10d, r9d
	jge .lr_row_done
	movzx ecx, byte [rsi]
	cmp ecx, eax
	jle .lr_no_new_max
	mov eax, ecx
	cmp eax, 255
	je .lr_done					; can't get any brighter, bail
.lr_no_new_max:
	inc rsi
	inc r10d
	jmp .lr_col
.lr_row_done:
	inc edi
	jmp .lr_row

.lr_empty:
	xor eax, eax
.lr_done:
	ret

;================================================================
; draw_lit_flat_objects_overlay: redraw lit flat objects on top
; of the night tint
;----------------------------------------------------------------
; flat objects (beds, doors, chairs, torches atm) are drawn in
; draw_objects BEFORE the entity pass.  by the time the tint
; runs, they've been darkened along with the ground.  this pass
; scans the visible tile region and re-blits any flat object
; whose tile is sufficiently lit on top
;
; mirrors draw_objects' dispatch (autotile / torch / static) and
; loop bounds.  tall objects (trees, walls) are handled by
; draw_lit_overlay_pass since they y-sort with entities
;
; bails early in daylight
;================================================================
draw_lit_flat_objects_overlay: 
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 48

	; locals (mirroring draw_objects):
	;	[rbp-4]  ty
	;	[rbp-8]  tx
	;	[rbp-20] ty_min
	;	[rbp-24] ty_max
	;	[rbp-28] tx_min
	;	[rbp-32] tx_max

	; daytime?  early out 
	call daynight_get_darkness
	test eax, eax
	jz .lf_done

	; tx_min = max(0, camera_x / TILE_SIZE - 1)
	mov eax, [camera_x]
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	test edx, edx
	jns .lf_txm_ok
	dec eax
.lf_txm_ok:
	dec eax
	test eax, eax
	jns .lf_txm_clamped
	xor eax, eax
.lf_txm_clamped:
	mov [rbp-28], eax

	; tx_max = min(MAP_WIDTH, (camera_x + WINDOW_W) / TILE_SIZE + 2)
	mov eax, [camera_x]
	add eax, WINDOW_W
	cdq
	idiv ecx
	add eax, 2
	cmp eax, MAP_WIDTH
	jle .lf_txx_ok
	mov eax, MAP_WIDTH
.lf_txx_ok:
	mov [rbp-32], eax

	; ty_min / ty_max
	mov eax, [camera_y]
	cdq
	idiv ecx
	test edx, edx
	jns .lf_tym_ok
	dec eax
.lf_tym_ok:
	dec eax
	test eax, eax
	jns .lf_tym_clamped
	xor eax, eax
.lf_tym_clamped:
	mov [rbp-20], eax

	mov eax, [camera_y]
	add eax, WINDOW_H
	cdq
	idiv ecx
	add eax, 2
	cmp eax, MAP_HEIGHT
	jle .lf_tyx_ok
	mov eax, MAP_HEIGHT
.lf_tyx_ok:
	mov [rbp-24], eax

	; outer loop on ty
	mov eax, [rbp-20]
	mov [rbp-4], eax
.lf_row:
	mov eax, [rbp-4]
	cmp eax, [rbp-24]
	jge .lf_done

	mov eax, [rbp-28]
	mov [rbp-8], eax
.lf_col:
	mov eax, [rbp-8]
	cmp eax, [rbp-32]
	jge .lf_next_row

	; obj id from objectmap.  skip empty
	mov eax, [rbp-4]
	imul eax, MAP_WIDTH
	add eax, [rbp-8]
	lea rbx, [objectmap]
	movzx r12d, byte [rbx + rax]
	test r12d, r12d
	jz .lf_next_col

	; skip tall objects - those go through draw_lit_overlay_pass
	mov edi, [rbp-8]
	mov esi, [rbp-4]
	mov edx, r12d
	call is_tall_object
	test eax, eax
	jnz .lf_next_col

	; --- lit check on this tile ---
	; screen top-left
	mov eax, [rbp-8]
	imul eax, TILE_SIZE
	sub eax, [camera_x]
	mov r13d, eax					; r13d = sx (preserved for blit)

	mov eax, [rbp-4]
	imul eax, TILE_SIZE
	sub eax, [camera_y]
	mov r14d, eax					; r14d = sy (preserved for blit)

	mov edi, r13d
	mov esi, r14d
	mov edx, TILE_SIZE
	mov ecx, TILE_SIZE
	call lo_lightmap_rect_max
	cmp eax, LIT_OVERLAY_THRESHOLD
	jl .lf_next_col					; tile dark - leave tinted

	; --- redraw: dispatch + blit (mirrors draw_objects) ---
	; animated - kjust torch atm
	cmp r12d, OBJ_TORCH
	je .lf_torch

	; otherwise static (bed, chair, door atm)
	mov edi, [rbp-8]
	mov esi, [rbp-4]
	mov edx, r12d
	call nonauto_pick_slot_object
	jmp .lf_have_slot

.lf_torch:
	mov edi, [rbp-8]
	mov esi, [rbp-4]
	call torch_atlas_slot

.lf_have_slot:
	mov r15d, eax					; atlas slot

	; slot -> src_x, src_y
	mov eax, r15d
	xor edx, edx
	mov ecx, ATLAS_COLS
	div ecx
	imul edx, TILE_SIZE
	imul eax, TILE_SIZE
	mov esi, edx					; src_x
	mov edx, eax					; src_y
	mov ecx, TILE_SIZE
	mov r8d, TILE_SIZE

	; dst_x, dst_y from cached screen pos
	mov r9d, r13d					; dst_x
	mov eax, r14d					; dst_y in eax for the stack push

	lea rdi, [atlas_tex]
	mov r10, 0xFFFF00FF
	push r10
	push 0							; flip
	push rax						; dst_y
	call blit_texture_rect_keyed
	add rsp, 24

.lf_next_col:
	inc dword [rbp-8]
	jmp .lf_col
.lf_next_row:
	inc dword [rbp-4]
	jmp .lf_row

.lf_done:
	add rsp, 48
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret

;================================================================
; lo_maybe_redraw_tall_tile: redraw a tall tile if its area is lit
;----------------------------------------------------------------
; takes a tall_tile_list index, samples the lightmap over the
; tile's TILE_SIZE x TILE_SIZE screen rect.  if max light >=
; threshold, calls draw_tall_tile_one_idx to re-blit on top of
; the tint
;----------------------------------------------------------------
; in:  edi = tall_tile_list index
;================================================================
lo_maybe_redraw_tall_tile:
	push rbp
	push rbx
	push r12
	sub rsp, 8				; 3 pushes + 8 + ret = 32, aligned
	mov ebx, edi		; ebx = list index (preserved for blit call)

	; unpack: tall_tile_list[idx] = (sort_y << 16) | cell
	lea rax, [tall_tile_list]
	mov eax, [rax + rbx*4]
	movzx eax, ax				; cell = low 16 bits
	; tx = cell % MAP_WIDTH, ty = cell / MAP_WIDTH
	xor edx, edx
	mov ecx, MAP_WIDTH
	div ecx						; eax = ty, edx = tx

	; screen top-left = tile world - camera
	mov r12d, edx
	imul r12d, TILE_SIZE
	sub r12d, [camera_x]		; r12d = screen sx
	imul eax, TILE_SIZE
	sub eax, [camera_y]			; eax  = screen sy

	; sample max lightmap in (sx, sy, TILE_SIZE, TILE_SIZE)
	mov edi, r12d
	mov esi, eax
	mov edx, TILE_SIZE
	mov ecx, TILE_SIZE
	call lo_lightmap_rect_max
	cmp eax, LIT_OVERLAY_THRESHOLD
	jl .mt_done					; not lit - leave tinted

	; lit - redraw via the shared tall-tile blit
	mov edi, ebx
	lea rsi, [atlas_tex]
	call draw_tall_tile_one_idx

.mt_done:
	add rsp, 8
	pop r12
	pop rbx
	pop rbp
	ret

;================================================================
; draw_lit_overlay_pass: redraw lit entities + tall tiles on top
; of the night tint, preserving y-sort
;----------------------------------------------------------------
; called after daynight_apply_tint.  walks entity_draw_order and
; tall_tile_list in the same interleaved order that draw_entities
; used a few frames ago this same frame - reusing those arrays so
; we don't need to re-sort
;
; for each entity: rect-sample the lightmap around it.  if lit
; enough, re-blit the sprite at full colour so it pops against
; the warm-glowed ground
;
; for each tall tile (trees, walls atm): rect-sample the lightmap
; over the tile.  if lit, re-blit via draw_tall_tile_one_idx.
;
; bails early in full daylight, ignores stuff in darkness
;----------------------------------------------------------------
; the pose-pick + sprite-blit block mirrors draw_entities in
; entity_player.inc.asm.  kept duplicated rather than factored to
; a helper since the original juggles r13/r12/rsp state that's
; too awkward for me to juggle and thread through a call boundary
;================================================================
draw_lit_overlay_pass:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 24			; [rsp]=pose scratch, [rsp+8]=tall_idx

	; daytime?  early out
	call daynight_get_darkness
	test eax, eax
	jz .lo_done

	; --- reuse entity_draw_order + tall_tile_list from this frame's
	; first draw_entities call.  both are still valid (nothing in
	; between mutates entities or rebuilds the tall list)
	mov qword [rsp+8], 0		; tall_idx = 0
	mov r14d, [entity_count]
	test r14d, r14d
	jz .lo_drain_tall			; no entities, still need to flush trees
	xor r15d, r15d				; loop idx

.lo_next:
	cmp r15d, r14d
	jge .lo_drain_tall

	lea rax, [entity_draw_order]
	movzx ebx, byte [rax + r15]	; ebx = entity idx

	mov edi, ebx
	call entity_ptr
	mov r13, rax				; r13 = entity ptr

	; skip dead
	movzx eax, byte [r13 + ENT_FLAGS_OFFSET]
	test eax, ENT_FLAG_ALIVE
	jz .lo_skip

	; --- flush tall tiles whose sort_y <= this entity's y ---
	; mirrors the interleave in draw_entities so trees / walls
	; redraw at the right place in z-order. tiles get get a lit
	; check before draw
.lo_flush_tall:
	mov ecx, [rsp+8]			; tall_idx
	cmp ecx, [tall_tile_count]
	jge .lo_flush_done
	mov eax, [r13 + ENT_Y_OFFSET]
	lea rdx, [tall_tile_list]
	mov edx, [rdx + rcx*4]		; packed entry
	shr edx, 16					; sort_y
	cmp edx, eax
	jg .lo_flush_done			; this tile sorts after the entity
	mov edi, ecx
	call lo_maybe_redraw_tall_tile
	inc dword [rsp+8]
	jmp .lo_flush_tall
.lo_flush_done:

	; --- sample lightmap around entity to find how lit it is ---
	; we scan a rectangle around the entity centre and take max.
	;
	; can't just read the centre pixel.. entities are added as
	; occluders by torch_build_occluder_list, so they cast shadows
	; on the lightmap.  the centre falls inside the entity's own
	; occluder bbox - shadow rasteriser may mark it shadowed.  on
	; top of that, nearby tile occluders (walls, trees) can shadow
	; parts of the entity's bbox at certain torch angles, so a few
	; samples can all happen to land in shadow even when the entity
	; sits in a clearly-lit patch
	;aka taking MAX of these means any found lit pixel will work,cool
	;
	; cx/cy in callee-saved r12/rbx since they survive the call
	;
	; this was hard but worth it, it looks awesome now though it took
	; a lot of approaches/attempts
	mov eax, [r13 + ENT_X_OFFSET]
	sub eax, [camera_x]
	mov r12d, eax				; r12d = screen cx

	mov eax, [r13 + ENT_Y_OFFSET]
	sub eax, [camera_y]
	mov ebx, eax				; ebx = screen cy

	; whole-entity offscreen reject - if even cx+SPRITE_SIZE is off
	; the left edge (or cx-SPRITE_SIZE off the right), the sprite is
	; fully invisible.  same for y
	cmp r12d, -SPRITE_SIZE
	jl .lo_skip
	cmp r12d, LM_W + SPRITE_SIZE
	jge .lo_skip
	cmp ebx, -SPRITE_SIZE
	jl .lo_skip
	cmp ebx, LM_H + SPRITE_SIZE
	jge .lo_skip

	; scan lightmap in (cx +- half, cy +- half), take max.
	; half = SPRITE_SIZE/2 covers the sprite footprint
	mov edi, r12d
	sub edi, SPRITE_SIZE / 2
	mov esi, ebx
	sub esi, SPRITE_SIZE / 2
	mov edx, SPRITE_SIZE
	mov ecx, SPRITE_SIZE
	call lo_lightmap_rect_max

	cmp eax, LIT_OVERLAY_THRESHOLD
	jl .lo_skip					; not lit enough - leave as-is

	; --- pose pick (mirrors draw_entities) ---
	; [rsp+16] / [rsp+20] hold the lunge offset px (dx, dy), 0 if
	; this entity isn't mid-swing - applied at the blit site below
	mov dword [rsp+16], 0
	mov dword [rsp+20], 0

	movzx eax, byte [r13 + ENT_HIT_TIMER_OFFSET]
	test eax, eax
	jnz .lo_pose_hit

	; gate the attack-row pose: fighting npc, or any player swing
	movzx eax, byte [r13 + ENT_AI_MODE_OFFSET]
	cmp eax, AI_MODE_FIGHTING
	je .lo_pose_check_window
	movzx eax, byte [r13 + ENT_TYPE_OFFSET]
	cmp eax, ENT_TYPE_PLAYER
	jne .lo_pose_walk
.lo_pose_check_window:
	movzx eax, byte [r13 + ENT_ATTACK_TICKS_OFFSET]
	cmp eax, ATTACK_PERIOD - ATTACK_POSE_FRAMES
	jle .lo_pose_walk

	;inside the swing window - pick row,then lunge(see draw_entities)
	mov ecx, eax				; save attack_ticks for lunge calc
	cmp eax, ATTACK_PERIOD - (ATTACK_POSE_FRAMES / 2)
	jle .lo_pose_atk_b
	mov dword [rsp], 1			; row 1 = attack A
	jmp .lo_pose_have_lunge
.lo_pose_atk_b:
	mov dword [rsp], 2			; row 2 = attack B
.lo_pose_have_lunge:
	; ecx still holds attack_ticks
	sub ecx, ATTACK_PERIOD - ATTACK_POSE_FRAMES		; ecx = t
	mov eax, ecx
	sub eax, ATTACK_POSE_FRAMES / 2
	; abs(eax)
	cdq
	xor eax, edx
	sub eax, edx
	mov edx, ATTACK_POSE_FRAMES / 2
	sub edx, eax				; edx = lunge in 0..APF/2
	; offset_px = edx * LUNGE_PEAK_PX / (ATTACK_POSE_FRAMES/2)
	imul edx, LUNGE_PEAK_PX
	mov ecx, ATTACK_POSE_FRAMES / 2
	mov eax, edx
	cdq
	idiv ecx					; eax = offset_px (>=0)

	; direction by facing - route into [rsp+16] (x) or [rsp+20] (y)
	movzx ecx, byte [r13 + ENT_FACING_OFFSET]
	cmp ecx, FACE_UP
	je .lo_lunge_up
	cmp ecx, FACE_DOWN
	je .lo_lunge_down
	cmp ecx, FACE_LEFT
	je .lo_lunge_left
	; right
	mov [rsp+16], eax
	jmp .lo_pose_have_row
.lo_lunge_left:
	neg eax
	mov [rsp+16], eax
	jmp .lo_pose_have_row
.lo_lunge_up:
	neg eax
	mov [rsp+20], eax
	jmp .lo_pose_have_row
.lo_lunge_down:
	mov [rsp+20], eax
	jmp .lo_pose_have_row
.lo_pose_hit:
	mov dword [rsp], 3			; row 3 = hit
	jmp .lo_pose_have_row
.lo_pose_walk:
	mov dword [rsp], 0			; row 0 = walk
.lo_pose_have_row:

	; --- pick col + flip ---
	movzx r12d, byte [r13 + ENT_SLOT_OFFSET]
	movzx eax, byte [r13 + ENT_FACING_OFFSET]

	cmp dword [rsp], 0
	jne .lo_non_walk

	cmp eax, FACE_DOWN
	je .lo_pp_down
	cmp eax, FACE_UP
	je .lo_pp_up
	cmp eax, FACE_LEFT
	je .lo_pp_left
	; right
	add r12d, 2
	movzx edx, byte [r13 + ENT_PHASE_OFFSET]
	add r12d, edx
	mov ecx, 1
	jmp .lo_pose_done
.lo_pp_left:
	add r12d, 2
	movzx edx, byte [r13 + ENT_PHASE_OFFSET]
	add r12d, edx
	xor ecx, ecx
	jmp .lo_pose_done
.lo_pp_down:
	movzx ecx, byte [r13 + ENT_PHASE_OFFSET]
	jmp .lo_pose_done
.lo_pp_up:
	add r12d, 1
	movzx ecx, byte [r13 + ENT_PHASE_OFFSET]
	jmp .lo_pose_done

.lo_non_walk:
	cmp eax, FACE_DOWN
	je .lo_nw_down
	cmp eax, FACE_UP
	je .lo_nw_up
	cmp eax, FACE_LEFT
	je .lo_nw_left
	add r12d, 2
	mov ecx, 1
	jmp .lo_pose_done
.lo_nw_left:
	add r12d, 2
	xor ecx, ecx
	jmp .lo_pose_done
.lo_nw_down:
	xor ecx, ecx
	jmp .lo_pose_done
.lo_nw_up:
	add r12d, 1
	xor ecx, ecx
.lo_pose_done:

	; pose row -> src_y
	mov r11d, [rsp]
	imul r11d, SPRITE_SIZE

	; build the blit call.  same signature as draw_entities:
	; rdi=tex, esi=src_x, edx=src_y, ecx=src_w, r8d=src_h,
	; r9d=dst_x, [rbp+16]=dst_y, [rbp+24]=flip, [rbp+32]=key
	push rcx					; stash flip
	mov eax, [r13 + ENT_X_OFFSET]
	sub eax, [camera_x]
	sub eax, SPRITE_SIZE / 2
	add eax, [rsp+24]			; +lunge dx (was [rsp+16] before push)
	mov ebx, eax				; dst_x

	mov eax, [r13 + ENT_Y_OFFSET]
	sub eax, [camera_y]
	sub eax, SPRITE_SIZE / 2
	add eax, [rsp+28]			; +lunge dy (was [rsp+20] before push)
	; dst_y goes onto the stack below

	pop rdi
	movzx edi, dil

	; 3 pushes (24 bytes) -> +8 pad for 16-byte align at call
	sub rsp, 8
	mov rcx, SPRITE_COLOR_KEY
	push rcx					; key
	push rdi					; flip
	cdqe
	push rax					; dst_y

	lea rdi, [sprites_tex]
	mov esi, r12d
	imul esi, SPRITE_SIZE		; src_x
	mov edx, r11d				; src_y
	mov ecx, SPRITE_SIZE		; src_w
	mov r8d, SPRITE_SIZE		; src_h
	mov r9d, ebx				; dst_x

	call blit_texture_rect_keyed
	add rsp, 32					; 24 args + 8 pad

.lo_skip:
	inc r15d
	jmp .lo_next

	; drain any tall tiles that sort south of the southernmost entity
.lo_drain_tall:
	mov ecx, [rsp+8]
	cmp ecx, [tall_tile_count]
	jge .lo_done
	mov edi, ecx
	call lo_maybe_redraw_tall_tile
	inc dword [rsp+8]
	jmp .lo_drain_tall

.lo_done:
	add rsp, 24
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret

%endif
