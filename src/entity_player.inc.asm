; entity_player.inc.asm - player state, input, movement, action,
; floating text feedback, sync into the entity table, and the
; mixed player/npc draw routine
;----------------------------------------------------------------
; SPRITE SHEET LAYOUT (sprites.ppm)
; ---------------------------------
; each row is one "POSE"; each
; group of 4 consecutive columns is a CHARACTER.  draw_entities
; uses ENT_SLOT_OFFSET as the base column of the character's
; 4-col block and picks the row by render-time state
;
; cols (per character block):
;	+0	facing down
;	+1	facing up
;	+2	left frame A (also right, flipped)
;	+3	left frame B (also right, flipped) - walk row only
;
; rows:
;	0	WALK	- 2-frame leg cycle; col +3 = the alt leg pose
;	1	ATTACK A	- attack swing first frame; col +3 unused/blank
;	2	ATTACK B	- attack swing second frame; col +3 unused/blank
;	3	HIT			- damage-taken pose; col +3 unused/blank
;
; current character blocks (cols * 4):
;	0..3	player
;	4..7	hero
;	8..11	monster
;
; easy system, to add more chars we just need to append
; a new 4-col block and add its base col to hero_sprite_bases/
; monster_sprite_bases in spawn.inc.asm
%ifndef ENTITY_PLAYER_INC
%define ENTITY_PLAYER_INC

%define move_step		1		; player px/frame

; sprite sheet uses 16x16 tiles with magenta as the transparent key
; (consumed by draw_entities below)
%define SPRITE_SIZE			16
%define SPRITE_COLOR_KEY	0xFFFF00FF

; floating text params (feedback above player after gather/kill)
%define FT_LIFETIME		50
%define FT_LIFT_PERIOD	6
%define FT_MAX_TEXT		16

section .data
	floattext_wood		db "+1 wood", 0
	floattext_stone		db "+1 stone", 0
	floattext_gold		db "+1 gold", 0

section .bss
	; player state - source of truth (entity[0] is a mirror for
	; y-sort/collision)
	alignb 4
	player_x			resd 1	; pixel coords (centre of sprite)
	player_y			resd 1
	player_facing		resd 1	; FACE_DOWN/UP/etc
	player_anim_phase	resd 1	; 0 or 1 - walk frame
	player_anim_timer	resd 1	; counts up to ANIM_PERIOD
	player_moved		resb 1	; did we move this frame?

	; stats + inv counts used by the HUD bar.  reset on world setup
	alignb 2
	player_hp			resw 1
	player_hp_max		resw 1
	player_res_wood		resw 1
	player_res_stone	resw 1
	player_res_food		resw 1
	player_res_gold		resw 1

	; movement accumulator for fractional-speed tiles.  each attempt
	; adds the dst tile's speed%; on >=100 we apply the step and sub
	; 100.  eg water at 50% = a step every 2 frames
	alignb 4
	move_accum			resd 1

	; floating text slot - 1 only, new spawns replace old
	alignb 4
	floattext_active	resb 1
	floattext_ttl		resw 1
	floattext_x			resd 1
	floattext_y			resd 1
	floattext_buf		resb FT_MAX_TEXT

section .text

;================================================================
; update_player_input: poll arrow/wasd keys and move/animate
;----------------------------------------------------------------
; runs once per frame.  checks each dir independently for diags
; sets player_facing to the most-recent pressed dir for now
; updates player_anim_phase based on whether anything moved
;================================================================
update_player_input:
	push rbp
	mov rbp, rsp

	mov byte [player_moved], 0

	; early return if console/inventory open
	cmp byte [console_open], 0
	jne .skip_movement
	cmp byte [inv_open], 0
	jne .skip_movement

	; -- left? (left arrow or A) --
	mov rax, [sdl_keystate]
	movzx ecx, byte [rax + SCANCODE_LEFT]
	movzx edx, byte [rax + SCANCODE_A]
	or ecx, edx
	test ecx, ecx
	jz .not_left
	mov dword [player_facing], FACE_LEFT
	mov edi, -move_step
	xor esi, esi
	call try_move
.not_left:
	; -- right? (right arrow or D) --
	mov rax, [sdl_keystate]
	movzx ecx, byte [rax + SCANCODE_RIGHT]
	movzx edx, byte [rax + SCANCODE_D]
	or ecx, edx
	test ecx, ecx
	jz .not_right
	mov dword [player_facing], FACE_RIGHT
	mov edi, move_step
	xor esi, esi
	call try_move
.not_right:
	; -- up? (up arrow or W) --
	mov rax, [sdl_keystate]
	movzx ecx, byte [rax + SCANCODE_UP]
	movzx edx, byte [rax + SCANCODE_W]
	or ecx, edx
	test ecx, ecx
	jz .not_up
	mov dword [player_facing], FACE_UP
	xor edi, edi
	mov esi, -move_step
	call try_move
.not_up:
	; -- down? (down arrow or S) --
	mov rax, [sdl_keystate]
	movzx ecx, byte [rax + SCANCODE_DOWN]
	movzx edx, byte [rax + SCANCODE_S]
	or ecx, edx
	test ecx, ecx
	jz .not_down
	mov dword [player_facing], FACE_DOWN
	xor edi, edi
	mov esi, move_step
	call try_move
.not_down:
.skip_movement:

	; --- animation ---
	; moved this frame?: tick timer, toggle phase on overflow
	; idle?: reset to phase 0 so we rest in pose 0
	cmp byte [player_moved], 0
	je .anim_idle
	inc dword [player_anim_timer]
	cmp dword [player_anim_timer], ANIM_PERIOD
	jl .anim_done
	mov dword [player_anim_timer], 0
	xor dword [player_anim_phase], 1
	jmp .anim_done
.anim_idle:
	mov dword [player_anim_timer], 0
	mov dword [player_anim_phase], 0
.anim_done:
	pop rbp
	ret

;================================================================
; try_move: nudge the player by (dx, dy), checking collision
;----------------------------------------------------------------
; reads the dst tile's speed%:
; 0 blocks the move, 100 is full speed
; partials (eg water at 50) accumulate across calls and apply a
; step once the accum hits 100. nice slowdowns w/o fractional px
;
; if blocked, the accum is cleared so a held direction against a
; wall doesn't build speed for when the wall ends
;----------------------------------------------------------------
; in: edi = dx, esi = dy
;================================================================
try_move:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	sub rsp, 8					; align

	mov ebx, edi				; dx
	mov r12d, esi				; dy

	; dst pixel = (player_x + dx, player_y + dy)
	mov edi, [player_x]
	add edi, ebx
	mov esi, [player_y]
	add esi, r12d

	call tile_speed_at_pixel	; eax = speed at dst
	test eax, eax
	jz .blocked

	add [move_accum], eax
	cmp dword [move_accum], 100
	jl .not_yet

	; accumulated enough - apply a full step
	sub dword [move_accum], 100
	add [player_x], ebx
	add [player_y], r12d
	mov byte [player_moved], 1

.not_yet:
	add rsp, 8
	pop r12
	pop rbx
	pop rbp
	ret

.blocked:
	mov dword [move_accum], 0	; reset (see desc)
	add rsp, 8
	pop r12
	pop rbx
	pop rbp
	ret

;================================================================
; try_player_action (E key): act on the tile in front of player
;----------------------------------------------------------------
; alive npc ?: kill  and +1 gold
; tree/bush ?: remove and +1 wood
; stone wall?: remove and +1 stone
; door	    ?: toggle open/closed
; else silent miss
;
; + fading hover text
;================================================================
try_player_action:
	push rbx
	push r12
	push r13
	push r14
	push r15
	; 5 callee-saves + ret = 48 bytes -> 16-aligned

	; --- compute target tile (tx, ty) ---
	; player_x/y are pixel-centred on the player
	; div by TILE_SIZE -> current tile, offset by facing
	mov eax, [player_x]
	mov ecx, TILE_SIZE
	cdq
	idiv ecx
	mov ebx, eax			; ebx = player_tx
	mov eax, [player_y]
	cdq
	idiv ecx
	mov r12d, eax			; r12d = player_ty

	mov eax, [player_facing]
	cmp eax, FACE_UP
	je .face_up
	cmp eax, FACE_LEFT
	je .face_left
	cmp eax, FACE_RIGHT
	je .face_right
	; default down
	inc r12d
	jmp .have_target
.face_up:
	dec r12d
	jmp .have_target
.face_left:
	dec ebx
	jmp .have_target
.face_right:
	inc ebx
.have_target:
	; ebx = target_tx, r12d = target_ty

	; bounds check
	test ebx, ebx
	js .out
	cmp ebx, MAP_WIDTH
	jge .out
	test r12d, r12d
	js .out
	cmp r12d, MAP_HEIGHT
	jge .out

	; --- door toggle ---
	; if target is a door, toggle and stop.  doors win over
	; standing-on-grass-do-nothing
	mov edi, ebx
	mov esi, r12d
	call door_toggle_at
	test eax, eax
	jnz .out_changed

	; --- look for an npc entity in front of the player ---
	; build melee attack aabb:a 20x20 box centred on tile in front
	; of the player.  any alive non-player entity whose 16x16 sprite
	; aabb overlaps gets hit. bigger-than-tile attack reach means the
	; player doesn't have to be pixel-perfect lined up with an npc
	;
	; melee attack aabb:
	;	sx_lo = target_tx * TILE - SWING_EXTRA, sx_hi = +TILE+SWING_EXTRA
	;	sy_lo = target_ty * TILE - SWING_EXTRA, sy_hi = +TILE+SWING_EXTRA
	; entity aabb (16x16 sprite around centre):
	;	ex_lo = ex - SPRITE_SIZE/2, ex_hi = ex + SPRITE_SIZE/2
	;	ey_lo = ey - SPRITE_SIZE/2, ey_hi = ey + SPRITE_SIZE/2
	; overlap iff sx_lo < ex_hi && ex_lo < sx_hi (same for y)
	%define SWING_EXTRA		2

	mov r13d, ebx
	imul r13d, TILE_SIZE
	sub r13d, SWING_EXTRA		; r13d = swing sx_lo
	mov r14d, r12d
	imul r14d, TILE_SIZE
	sub r14d, SWING_EXTRA		; r14d = swing sy_lo
	; we'll compute sx_hi and sy_hi on the fly: sx_lo + TILE + 2*EXTRA

	xor r15d, r15d				; entity idx
.scan:
	cmp r15d, [entity_count]
	jge .no_entity_hit

	mov edi, r15d
	call entity_ptr 			; rax = entity ptr

	; alive?
	movzx ecx, byte [rax + ENT_FLAGS_OFFSET]
	test ecx, ENT_FLAG_ALIVE
	jz .next_scan
	; non-player?
	movzx ecx, byte [rax + ENT_TYPE_OFFSET]
	cmp ecx, ENT_TYPE_PLAYER
	je .next_scan

	; --- aabb overlap test ---
	; entity centre in (rcx, edx) - rcx = ex, edx = ey
	mov ecx, [rax + ENT_X_OFFSET]
	mov edx, [rax + ENT_Y_OFFSET]

	; x overlap?
	;	if (ex + SPRITE_SIZE/2 <= sx_lo) miss;(entity too far left)
	;	if (ex - SPRITE_SIZE/2 >= sx_hi) miss;(entity too far right)
	;
	; sx_hi - sx_lo = TILE_SIZE + 2*SWING_EXTRA  (constant)
	mov edi, ecx
	add edi, SPRITE_SIZE / 2
	cmp edi, r13d
	jle .next_scan				; ex_hi <= sx_lo -> no overlap
	mov edi, ecx
	sub edi, SPRITE_SIZE / 2
	mov esi, r13d
	add esi, TILE_SIZE + 2 * SWING_EXTRA	; sx_hi
	cmp edi, esi
	jge .next_scan				; ex_lo >= sx_hi

	; y overlap?
	mov edi, edx
	add edi, SPRITE_SIZE / 2
	cmp edi, r14d
	jle .next_scan
	mov edi, edx
	sub edi, SPRITE_SIZE / 2
	mov esi, r14d
	add esi, TILE_SIZE + 2 * SWING_EXTRA
	cmp edi, esi
	jge .next_scan

	; --- hit! deal damage ---
	; subtract HIT_DAMAGE from the entity's hp.  if it drops to 0
	; (or below), the entity dies and we award gold
	%define HIT_DAMAGE		3
	movzx edi, byte [rax + ENT_HP_OFFSET]
	sub edi, HIT_DAMAGE
	jg .alive_after_hit			; jg = strictly greater than 0
	; dead - cache the corpse pixel pos before entity_kill, then
	; drop a blood mark there
	mov byte [rax + ENT_HP_OFFSET], 0
	mov edi, [rax + ENT_X_OFFSET]
	mov esi, [rax + ENT_Y_OFFSET]
	; rsp at this point: 5 callee-saves (40) + ret (8) = 48 aligned,
	; with no extra subq.  call directly, no padding needed
	call blood_splat_at_pixel
	mov edi, r15d
	call entity_kill
	inc word [player_res_gold]
	lea rdi, [floattext_gold]
	call spawn_floattext
	jmp .out
.alive_after_hit:
	mov byte [rax + ENT_HP_OFFSET], dil
	; trigger the hit-flash pose and a blood mark for feedback
	mov byte [rax + ENT_HIT_TIMER_OFFSET], HIT_FLASH_FRAMES
	mov edi, [rax + ENT_X_OFFSET]
	mov esi, [rax + ENT_Y_OFFSET]
	call blood_splat_at_pixel
	jmp .out

.next_scan:
	inc r15d
	jmp .scan

.no_entity_hit:
	; --- no entity; check cell contents ---
	; objects take priority over ground - trees + stone walls both
	; live in the object overlay and are harvestable.  ground tile
	; is left alone either way
	mov edi, ebx
	mov esi, r12d
	call object_at
	cmp eax, OBJ_TREE
	je .got_tree
	cmp eax, OBJ_STONE_WALL
	je .got_stone

	; nothing harvestable
	jmp .out

.got_tree:
	; clear tree from objectmap, ground untouched
	mov eax, r12d
	imul eax, MAP_WIDTH
	add eax, ebx
	lea rcx, [objectmap]
	mov byte [rcx + rax], OBJ_NONE
	inc word [player_res_wood]
	lea rdi, [floattext_wood]
	call spawn_floattext
	jmp .out_changed

.got_stone:
	; chop stone wall: ground -> dirt, object cleared
	mov eax, r12d
	imul eax, MAP_WIDTH
	add eax, ebx
	lea rdx, [objectmap]
	mov byte [rdx + rax], OBJ_NONE
	lea rdx, [tilemap]
	mov byte [rdx + rax], TILE_DIRT
	inc word [player_res_stone]
	lea rdi, [floattext_stone]
	call spawn_floattext
	; fallthrough to .out_changed

.out_changed:
	; an occluder or light source moved/changed - rebuild the
	; gameplay safezone mask and the hub flow field
	call safezone_recompute
	call pathing_recompute
	; fallthrough to .out

.out:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; floating text: "+1 wood" etc above the player
;----------------------------------------------------------------
; 1 slot total, new spawns replace old.  lives FT_LIFETIME ticks
; lifts up by 1px every FT_LIFT_PERIOD ticks, linear "fade"
; TODO: experiment w/ colours, transparency
;================================================================

; spawn_floattext: copy a string into the slot, mark active, place
; above the player
; in: rdi = src null-term string ptr
spawn_floattext:
	; rdi = src.  no calls inside, so no save
	mov eax, [player_x]
	mov [floattext_x], eax
	mov eax, [player_y]
	sub eax, 16					; a tile above
	mov [floattext_y], eax
	mov word [floattext_ttl], FT_LIFETIME
	mov byte [floattext_active], 1
	; copy string (up to FT_MAX_TEXT-1 bytes + null)
	mov rsi, rdi
	lea rdi, [floattext_buf]
	mov ecx, FT_MAX_TEXT - 1
.cp:
	test ecx, ecx
	jz .cp_done
	movzx eax, byte [rsi]
	mov [rdi], al
	test al, al
	jz .cp_done
	inc rsi
	inc rdi
	dec ecx
	jmp .cp
.cp_done:
	mov byte [rdi], 0
	ret

; floattext_tick: per-frame ttl--, lift y, expire
floattext_tick:
	cmp byte [floattext_active], 0
	je .out
	movzx eax, word [floattext_ttl]
	test eax, eax
	jz .expire
	dec eax
	mov word [floattext_ttl], ax
	; lift 1px per FT_LIFT_PERIOD ticks
	xor edx, edx
	mov ecx, FT_LIFT_PERIOD
	div ecx
	test edx, edx
	jnz .out
	dec dword [floattext_y]
	ret
.expire:
	mov byte [floattext_active], 0
.out:
	ret

; floattext_draw: render the string at camera (x,y), fading to dark
floattext_draw:
	cmp byte [floattext_active], 0
	je .out

	; intensity = ttl * 255 / FT_LIFETIME, 0..255
	movzx eax, word [floattext_ttl]
	imul eax, 255
	mov ecx, FT_LIFETIME
	xor edx, edx
	div ecx
	; eax = 0..255, modulate r,g,b of white by this:
	; bit hacky, TEMP until i figure out alpha blits
	mov ecx, eax
	mov edx, eax
	shl edx, 8
	or ecx, edx
	mov edx, eax
	shl edx, 16
	or ecx, edx
	or ecx, 0xFF343434
	mov r9d, ecx	; r9d = colour

	; world -> screen
	mov edi, [floattext_x]
	sub edi, [camera_x]
	; nudge left a bit
	sub edi, 24					; 14 might also be ok
	mov esi, [floattext_y]
	sub esi, [camera_y]
	mov edx, r9d
	lea rcx, [floattext_buf]
	call debug_print
.out:
	ret

;================================================================
; place_player_at_hub: drop the player on the hub tile centre
;----------------------------------------------------------------
; worldgen carves a 3x3 wood-floor patch at the map centre and the
; hub is pinned there at world regen by pathing_init_default_hub.
; no walkability check needed - the carve guarantees it.  this is
; the default spawn point.  place_player_on_floor stays around for
; future "random start" or fallback use
;================================================================
place_player_at_hub:
	mov eax, [hub_tx]
	imul eax, TILE_SIZE
	add eax, TILE_SIZE/2
	mov [player_x], eax
	mov eax, [hub_ty]
	imul eax, TILE_SIZE
	add eax, TILE_SIZE/2
	mov [player_y], eax
	ret

;================================================================
; place_player_on_floor: pick a random fully-walkable tile and
; put the player at its centre.  uses tile_speed_at_pixel so the
; object overlay (trees, walls, etc) is rejected too, not just
; the ground.  falls back to a linear scan if 200 random tries
; fail to find anywhere
;================================================================
place_player_on_floor:
	push rbx
	push r12
	push r13
	sub rsp, 8					; align
	mov r12d, 200
.try:
	test r12d, r12d
	jz .scan
	dec r12d

	mov edi, MAP_WIDTH
	call rng_range
	mov ebx, eax				; tx

	mov edi, MAP_HEIGHT
	call rng_range
	mov r13d, eax				; ty

	; tile centre -> pixel, then full ground+object speed check
	mov edi, ebx
	imul edi, TILE_SIZE
	add edi, TILE_SIZE/2
	mov esi, r13d
	imul esi, TILE_SIZE
	add esi, TILE_SIZE/2
	call tile_speed_at_pixel
	cmp eax, 100
	jne .try

	; commit - recompute pixel from tx/ty since the call clobbered
	; the previous edi/esi
	mov edi, ebx
	imul edi, TILE_SIZE
	add edi, TILE_SIZE/2
	mov [player_x], edi
	mov edi, r13d
	imul edi, TILE_SIZE
	add edi, TILE_SIZE/2
	mov [player_y], edi

	add rsp, 8
	pop r13
	pop rbx
	pop r12
	ret

.scan:
	; linear fallback: walk every cell until we hit a walkable one
	xor ebx, ebx				; ebx = idx
.scan_loop:
	cmp ebx, MAP_WIDTH * MAP_HEIGHT
	jge .scan_fail
	; idx -> (tx, ty)
	mov eax, ebx
	xor edx, edx
	mov ecx, MAP_WIDTH
	div ecx						; eax = ty, edx = tx
	; tile centre -> pixel
	mov edi, edx
	imul edi, TILE_SIZE
	add edi, TILE_SIZE/2
	mov esi, eax
	imul esi, TILE_SIZE
	add esi, TILE_SIZE/2
	; stash the candidate centre so we can write it on success
	push rdi
	push rsi
	call tile_speed_at_pixel
	pop rsi
	pop rdi
	cmp eax, 100
	je .scan_found
	inc ebx
	jmp .scan_loop
.scan_found:
	mov [player_x], edi
	mov [player_y], esi
.scan_fail:
	add rsp, 8
	pop r13
	pop rbx
	pop r12
	ret

;================================================================
; sync_player_to_entity: copy player_* into entity[0] before draw
;----------------------------------------------------------------
; we keep player_* as source of truth for input + HUD; the entity
; table mirrors it so it gets y-sorted with everyone else
;
; we also push player_hp/hp_max into the entity slot so AI attacks
; (which damage the entity hp byte) actually hit the player.  the
; reverse sync happens in sync_entity_to_player after AI ticks
;================================================================
sync_player_to_entity:
	xor edi, edi
	call entity_ptr 	; rax = &entity[0]
	mov edi, [player_x]
	mov [rax + ENT_X_OFFSET], edi
	mov edi, [player_y]
	mov [rax + ENT_Y_OFFSET], edi
	mov edi, [player_facing]
	mov byte [rax + ENT_FACING_OFFSET], dil
	mov edi, [player_anim_phase]
	mov byte [rax + ENT_PHASE_OFFSET], dil
	; hp + hp_max: clamp to byte before writing.  player hp is u16
	; (so the /set console can crank it to thousands) but the entity
	; field is u8.  cap at 255 - past that AI attacks taking 2-3 hp
	; per swing are irrelevant anyway
	movzx edi, word [player_hp]
	cmp edi, 255
	jle .hp_ok
	mov edi, 255
.hp_ok:
	mov byte [rax + ENT_HP_OFFSET], dil
	movzx edi, word [player_hp_max]
	cmp edi, 255
	jle .hpmax_ok
	mov edi, 255
.hpmax_ok:
	mov byte [rax + ENT_HP_MAX_OFFSET], dil
	ret

;================================================================
; sync_entity_to_player: pull damage taken back out of entity[0]
;----------------------------------------------------------------
; called once after entity_tick_all.  AI attacks drain the entity
; hp byte; we mirror it back into player_hp.  if the player's
; entity got flagged dead, trigger player_die_and_respawn so the
; slot is restored before any spawn could reclaim it
;================================================================
sync_entity_to_player:
	push rbp
	mov rbp, rsp
	xor edi, edi
	call entity_ptr 	; rax = &entity[0]

	; copy hp back.  AI damage is sat-to-zero (see ai_attack_tick) so
	; this is always in [0, hp_max]
	movzx ecx, byte [rax + ENT_HP_OFFSET]
	mov word [player_hp], cx

	; decay the player's hit-flash pose timer.  NPCs do this inside
	; ai_tick; the player never goes through there
	movzx ecx, byte [rax + ENT_HIT_TIMER_OFFSET]
	test ecx, ecx
	jz .ht_done
	dec ecx
	mov byte [rax + ENT_HIT_TIMER_OFFSET], cl
.ht_done:

	; flagged dead?
	movzx ecx, byte [rax + ENT_FLAGS_OFFSET]
	test ecx, ENT_FLAG_ALIVE
	jnz .out
	call player_die_and_respawn
.out:
	pop rbp
	ret

;================================================================
; player_hp_regen_tick: slow trickle of hp, called once per frame
;----------------------------------------------------------------
; gates on (frame_count % REGEN_PERIOD == 0) - just one bump per
; period, no per-entity stagger needed since there's only the one
; player.  player_hp is u16 (so /set can crank it high), hp_max
; same.  sync_player_to_entity clamps to 255 when copying down to
; the entity byte
;----------------------------------------------------------------
; must run AFTER sync_entity_to_player so we don't get clobbered
; by it pulling damage back the same frame
;================================================================
player_hp_regen_tick:
	mov eax, [frame_count]
	xor edx, edx
	mov ecx, REGEN_PERIOD
	div ecx
	test edx, edx
	jnz .out
	mov ax, [player_hp]
	cmp ax, [player_hp_max]
	jae .out
	inc ax
	mov [player_hp], ax
.out:
	ret

;================================================================
; player_die_and_respawn
;----------------------------------------------------------------
; wake up at "hub", lose a chunk of carried lose half our resources
;
; hp resets to half max so we're not insta-killed on respawn -
; then player_hp_regen_tick works away
;----------------------------------------------------------------
; resets entity[0]'s alive flag, clears any targeting that NPCs had
; on us so they wander off, and logs a status line
;================================================================
section .data
	log_msg_player_died	db "you awake at the hub, poorer.", 0
section .text

player_die_and_respawn:
	push rbp
	mov rbp, rsp

	; --- halve resources ---
	mov ax, [player_res_wood]
	shr ax, 1
	mov [player_res_wood], ax
	mov ax, [player_res_stone]
	shr ax, 1
	mov [player_res_stone], ax
	mov ax, [player_res_food]
	shr ax, 1
	mov [player_res_food], ax
	mov ax, [player_res_gold]
	shr ax, 1
	mov [player_res_gold], ax

	; --- restore hp to half max (at least 1) ---
	mov ax, [player_hp_max]
	shr ax, 1
	test ax, ax
	jnz .hp_ok
	mov ax, 1
.hp_ok:
	mov [player_hp], ax

	; --- teleport to hub tile centre ---
	mov eax, [hub_tx]
	imul eax, TILE_SIZE
	add eax, TILE_SIZE/2
	mov [player_x], eax
	mov eax, [hub_ty]
	imul eax, TILE_SIZE
	add eax, TILE_SIZE/2
	mov [player_y], eax

	; --- restore entity[0]: alive flag, hp/hp_max, clear targets ---
	xor edi, edi
	call entity_ptr			; rax = &entity[0]
	mov byte [rax + ENT_FLAGS_OFFSET], ENT_FLAG_ALIVE
	movzx ecx, word [player_hp]
	mov byte [rax + ENT_HP_OFFSET], cl
	movzx ecx, word [player_hp_max]
	cmp ecx, 255
	jle .ehpmax_ok
	mov ecx, 255
.ehpmax_ok:
	mov byte [rax + ENT_HP_MAX_OFFSET], cl
	; mirror the teleport into entity[0] right away so we don't appear
	; at the death spot for the rest of this frame's render
	mov ecx, [player_x]
	mov [rax + ENT_X_OFFSET], ecx
	mov ecx, [player_y]
	mov [rax + ENT_Y_OFFSET], ecx

	; --- clear any NPC targets that were on us ---
	; if a monster was chasing/fighting us, drop them back to wander
	; otherwise they'd be spawncamping us
	push rbx
	sub rsp, 8	; align for inner calls
	xor ebx, ebx
.npc_loop:
	mov ecx, [entity_count]
	cmp ebx, ecx
	jge .npc_done
	; skip self (slot 0)
	test ebx, ebx
	jz .npc_next
	mov edi, ebx
	call entity_ptr
	movzx ecx, byte [rax + ENT_AI_TARGET_OFFSET]
	cmp ecx, 0		; target = player slot 0?
	jne .npc_next
	mov byte [rax + ENT_AI_TARGET_OFFSET], AI_TARGET_NONE
	mov byte [rax + ENT_AI_MODE_OFFSET], AI_MODE_WANDER
	mov byte [rax + ENT_DECISION_TICKS_OFFSET], 0
.npc_next:
	inc ebx
	jmp .npc_loop
.npc_done:
	add rsp, 8
	pop rbx

	lea rdi, [log_msg_player_died]
	call debug_log

	pop rbp
	ret

;================================================================
; setup_world_entities: wipe + repopulate after a world regen
;----------------------------------------------------------------
; just sets up the player at entity[0].  npcs (heroes & monsters)
; come from spawn_tick over time - heroes in lit areas, monsters
; in dark ones - so the world feels populated by the player's
; actions, not by a pre-scatter
;================================================================
setup_world_entities:
	push rbp
	mov rbp, rsp
	call entity_clear_all

	; player goes at slot 0 directly.  entity_spawn skips slot 0
	; (reserved for the player) so we can't route through it; we'd
	; end up at slot 1 instead.  hand-fill the same fields entity_spawn
	; would, plus bump entity_count past us
	xor edi, edi
	call entity_ptr			; rax = &entity[0]
	mov edi, [player_x]
	mov [rax + ENT_X_OFFSET], edi
	mov edi, [player_y]
	mov [rax + ENT_Y_OFFSET], edi
	mov byte [rax + ENT_TYPE_OFFSET], ENT_TYPE_PLAYER
	mov byte [rax + ENT_FACING_OFFSET], 0
	mov byte [rax + ENT_SLOT_OFFSET], 0
	mov byte [rax + ENT_PHASE_OFFSET], 0
	mov byte [rax + ENT_TIMER_OFFSET], 0
	mov byte [rax + ENT_FLAGS_OFFSET], ENT_FLAG_ALIVE
	mov byte [rax + ENT_HP_OFFSET], 10
	mov byte [rax + ENT_HP_MAX_OFFSET], 10
	mov byte [rax + ENT_AI_DIR_OFFSET], AI_DIR_IDLE
	mov byte [rax + ENT_AI_MODE_OFFSET], AI_MODE_IDLE
	mov word [rax + ENT_AI_TICKS_OFFSET], 0
	mov dword [rax + ENT_AI_ACCUM_OFFSET], 0
	mov byte [rax + ENT_AI_TARGET_OFFSET], AI_TARGET_NONE
	mov byte [rax + ENT_BRAVERY_OFFSET], 128
	mov byte [rax + ENT_SPEED_OFFSET], 100
	mov byte [rax + ENT_DECISION_TICKS_OFFSET], 0
	mov byte [rax + ENT_ATTACK_TICKS_OFFSET], 0
	mov byte [rax + ENT_HIT_TIMER_OFFSET], 0
	mov byte [rax + ENT_STUCK_TICKS_OFFSET], 0
	; make sure entity_count covers us
	mov eax, [entity_count]
	cmp eax, 1
	jge .ec_ok
	mov dword [entity_count], 1
.ec_ok:

	; reset anim/facing - new world, fresh start
	mov dword [player_facing], FACE_DOWN
	mov dword [player_anim_phase], 0
	mov dword [player_anim_timer], 0
	mov dword [move_accum], 0

	; init player stats + inv counts
	mov word [player_hp_max], 10
	mov word [player_hp], 10
	mov word [player_res_wood], 3
	mov word [player_res_stone], 1
	mov word [player_res_food], 5
	mov word [player_res_gold], 0

	pop rbp
	ret

;================================================================
; draw_entities: y-sort the entity table and blit each alive entity
;----------------------------------------------------------------
; sprite slot pick (4-frame layout: 0 d, 1 u, 2 left-A, 3 left-B):
;
; pose selection only applies to PLAYER atm:
;	facing DOWN		-> slot 0, flip alternates with phase
;	facing UP		-> slot 1, flip alternates with phase
;	facing LEFT		-> slot 2 or 3 by phase, no flip
;	facing RIGHT	-> slot 2 or 3 by phase, flipped
;================================================================
draw_entities:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 24						; [rsp]=pose scratch, [rsp+8]=tall_idx

	call entity_sort_draw_order

	; collect visible tall objects into the y-sorted list.
	; we'll flush each one into the framebuffer just before the 1st
	; entity whose entity.y >= tile-top-y, which makes trees/etc
	; work with NPCs
	call collect_visible_tall_tiles
	mov qword [rsp+8], 0			; tall_idx = 0

	mov r14d, [entity_count]
	xor r15d, r15d					; loop idx
.next:
	cmp r15d, r14d
	jge .done

	lea rax, [entity_draw_order]
	movzx ebx, byte [rax + r15]		; ebx = entity idx

	mov edi, ebx
	call entity_ptr
	mov r13, rax					; r13 = entity ptr

	; skip dead
	movzx eax, byte [r13 + ENT_FLAGS_OFFSET]
	test eax, ENT_FLAG_ALIVE
	jz .skip

	; --- flush tall tiles whose sort_y <= this entity's y ---
	; list entries are packed: sort_y in high 16 bits, cell index
	; in low 16.  draining halts when the next tile would sort
	; after this entity
.flush_tall:
	mov ecx, [rsp+8]				; ecx = tall_idx
	cmp ecx, [tall_tile_count]
	jge .flush_done

	; reload entity.y every iter - rax/rcx/rdx are all caller-
	; saved so the draw call below clobbers any value we'd kept
	mov eax, [r13 + ENT_Y_OFFSET]
	lea rdx, [tall_tile_list]
	mov edx, [rdx + rcx*4]			; edx = packed entry
	shr edx, 16						; edx = sort_y
	cmp edx, eax
	jg .flush_done					; tile.sort_y > entity.y ->later

	mov edi, [rsp+8]				; tall_idx for the callee
	lea rsi, [atlas_tex] 
	call draw_tall_tile_one_idx

	inc dword [rsp+8]				; tall_idx++
	jmp .flush_tall
.flush_done:

	; shadow ellipse under entity before sprite
	mov edi, [r13 + ENT_X_OFFSET]
	sub edi, [camera_x]				; screen x
	mov esi, [r13 + ENT_Y_OFFSET]
	sub esi, [camera_y]
	add esi, SHADOW_Y_OFF			; screen y (feet)
	call draw_shadow_ellipse

	; --- pose pick ---
	; the sprites sheet is laid out as 4 rows x N cols, cell 16x16
	; pose row picks the row, facing+phase picks the col within the
	; entity's 4-frame block:
	;	row 0 = walking
	;	row 1 = attack frame A
	;	row 2 = attack frame B
	;	row 3 = hit (damage flash)
	;
	; col offsets within the block:
	;	walk:	down, base, left a, left b
	;	non-walk: down=base, up, left, BLANK
	;
	; r12d ends up as (base + col), r14d as pose row, ecx as flip.
	; [rsp+0] is our scratch slot; we stash the pose row there
	; since we need r14 free for entity_count
	;
	; --- pick pose row ---
	; precedence: hit-flash > attack pose > walk.  attack pose only
	; applies when actually in FIGHTING mode - otherwise the stale
	; attack_ticks value from a previous fight (held between mode
	; transitions, since only ai_attack_tick updates it) locks
	; fleeing/wandering npcs to attack rows by mistake it turns out!
	movzx eax, byte [r13 + ENT_HIT_TIMER_OFFSET]
	test eax, eax
	jnz .pose_hit
	movzx eax, byte [r13 + ENT_AI_MODE_OFFSET]
	cmp eax, AI_MODE_FIGHTING
	jne .pose_walk				; not fighting -> no attack pose
	movzx eax, byte [r13 + ENT_ATTACK_TICKS_OFFSET]
	cmp eax, ATTACK_PERIOD - ATTACK_POSE_FRAMES
	jle .pose_walk				; outside the swing window
	; inside the swing window.  first half = A, second half = B
	cmp eax, ATTACK_PERIOD - (ATTACK_POSE_FRAMES / 2)
	jle .pose_atk_b
	mov dword [rsp], 1			; row 1 = attack A
	jmp .pose_have_row
.pose_atk_b:
	mov dword [rsp], 2			; row 2 = attack B
	jmp .pose_have_row
.pose_hit:
	mov dword [rsp], 3			; row 3 = hit
	jmp .pose_have_row
.pose_walk:
	mov dword [rsp], 0			; row 0 = walking
.pose_have_row:

	; --- pick col + flip ---
	; for non-walk rows we skip the 2-frame phase anim
	movzx r12d, byte [r13 + ENT_SLOT_OFFSET]	; r12 = base slot
	movzx eax, byte [r13 + ENT_FACING_OFFSET]

	; walk row uses the existing 4-col block
	cmp dword [rsp], 0
	jne .non_walk_col

	; --- walk row: original logic ---
	cmp eax, FACE_DOWN
	je .pp_down
	cmp eax, FACE_UP
	je .pp_up
	cmp eax, FACE_LEFT
	je .pp_left
	; right
	add r12d, 2
	movzx edx, byte [r13 + ENT_PHASE_OFFSET]
	add r12d, edx
	mov ecx, 1
	jmp .pose_done
.pp_left:
	add r12d, 2
	movzx edx, byte [r13 + ENT_PHASE_OFFSET]
	add r12d, edx
	xor ecx, ecx
	jmp .pose_done
.pp_down:
	; base+0, flip on phase 1
	movzx ecx, byte [r13 + ENT_PHASE_OFFSET]
	jmp .pose_done
.pp_up:
	add r12d, 1
	movzx ecx, byte [r13 + ENT_PHASE_OFFSET]
	jmp .pose_done

.non_walk_col:
	; non-walk row: col 0/1/2, no phase, right flips col 2
	cmp eax, FACE_DOWN
	je .nw_down
	cmp eax, FACE_UP
	je .nw_up
	cmp eax, FACE_LEFT
	je .nw_left
	; right: col 2 flipped
	add r12d, 2
	mov ecx, 1
	jmp .pose_done
.nw_left:
	add r12d, 2
	xor ecx, ecx
	jmp .pose_done
.nw_down:
	xor ecx, ecx
	jmp .pose_done
.nw_up:
	add r12d, 1
	xor ecx, ecx
.pose_done:

	; pose row was stashed at [rsp].  multiply by SPRITE_SIZE to get
	; src_y, hold in r11d through the upcoming push/pop dance
	; (it's consumed by mov edx, r11d just before the blit call)
	mov r11d, [rsp]
	imul r11d, SPRITE_SIZE

	; now blit.  r12d = slot, ecx = flip, r11d = src_y
	; using callee-saved regs to hold dst_x, dst_y
	push rcx					; flip onto stack briefly
	mov eax, [r13 + ENT_X_OFFSET]
	sub eax, [camera_x]
	sub eax, SPRITE_SIZE/2
	mov ebx, eax				; ebx = dst_x

	mov eax, [r13 + ENT_Y_OFFSET]
	sub eax, [camera_y]
	sub eax, SPRITE_SIZE/2
	; dst_y goes into a stack slot below

	; build call args.  blit_texture_rect_keyed signature:
	; rdi=tex, esi=src_x, edx=src_y, ecx=src_w, r8d=src_h,
	; r9d=dst_x, [rbp+16]=dst_y, [rbp+24]=flip, [rbp+32]=key
	pop rdi			; dil = flip we saved
	movzx edi, dil	; clean upper bits

	; push args right-to-left: key first
	; 16-byte rsp alignment at the call: 3 pushes = 24 bytes
	; would misalign us, so drop an extra 8 first
	sub rsp, 8					; pad
	mov rcx, SPRITE_COLOR_KEY
	push rcx					; key
	push rdi					; flip
	cdqe			; dst_y is in eax; sign-extend for push
	push rax					; dst_y

	lea rdi, [sprites_tex]
	mov esi, r12d
	imul esi, SPRITE_SIZE		; src_x
	mov edx, r11d				; src_y from pose row
	mov ecx, SPRITE_SIZE		; src_w
	mov r8d, SPRITE_SIZE		; src_h
	mov r9d, ebx				; dst_x

	call blit_texture_rect_keyed
	add rsp, 32					; 24 args + 8 pad

	; --- HP bar for non-player npcs ---
	; positioned just above the sprite
	movzx eax, byte [r13 + ENT_TYPE_OFFSET]
	; not sure if i should skip player, as hearts are in hud, hm
	;cmp eax, ENT_TYPE_PLAYER
	;je .skip

	; world -> screen
	mov edi, [r13 + ENT_X_OFFSET]
	sub edi, [camera_x]			; screen cx
	mov esi, [r13 + ENT_Y_OFFSET]
	sub esi, [camera_y]
	sub esi, SPRITE_SIZE / 2	; sprite top
	sub esi, 4					; 4px above sprite
	movzx edx, byte [r13 + ENT_HP_OFFSET]
	movzx ecx, byte [r13 + ENT_HP_MAX_OFFSET]
	call draw_hp_bar

.skip:
	inc r15d
	jmp .next
.done:
	; --- drain any remaining tall tiles south of every entity ---
	; (entities ran out but some tall objects haven't been drawn
	; yet - they all sort south of the southernmost entity)
.drain_tall:
	mov ecx, [rsp+8]
	cmp ecx, [tall_tile_count]
	jge .drain_done
	mov edi, ecx
	lea rsi, [atlas_tex]
	call draw_tall_tile_one_idx
	inc dword [rsp+8]
	jmp .drain_tall
.drain_done:

	add rsp, 24
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret

;================================================================
; draw_hp_bar: small horizontal bar showing entity HP fraction
;----------------------------------------------------------------
; bar is HP_BAR_WIDTH x HP_BAR_HEIGHT, centred horizontally on the
; entity, with screen y = top of the bar.  red bg = full width,
; green fg = width * hp / hp_max.  no-op at full HP and
; dead (caller filters any dead..full HP we just always show atm)
;----------------------------------------------------------------
; in:	edi = screen cx (entity centre x in screen px)
;		esi = screen y top of bar
;		edx = current hp
;		ecx = hp_max
;================================================================
%define HP_BAR_WIDTH		14
%define HP_BAR_HEIGHT		2

draw_hp_bar:
	push rbx
	push r12
	push r13
	push r14
	; 4 pushes (32) + ret (8) = 40 - misaligned, fix with sub 8
	sub rsp, 8

	; clamp hp to [0, hp_max]
	test edx, edx
	jns .hp_lo_ok
	xor edx, edx
.hp_lo_ok:
	cmp edx, ecx
	jle .hp_hi_ok
	mov edx, ecx
.hp_hi_ok:
	; guard against hp_max = 0 (would divide-by-zero)
	test ecx, ecx
	jnz .hpmax_ok
	mov ecx, 1
.hpmax_ok:
	mov r12d, edx				; r12 = hp
	mov r14d, ecx				; r14 = hp_max

	; top-left of bar
	sub edi, HP_BAR_WIDTH / 2
	mov ebx, edi				; ebx = bar x
	mov r13d, esi				; r13 = bar y

	; --- outline ---
	; one fill_rect 1px larger on all sides; the red/green pass
	; below overwrites the interior, leaving a 1px white border
	; hm, first time that large pixels look crappy here, used to
	; very thin outlines on these things in RTSes
	mov edi, ebx
	dec edi
	mov esi, r13d
	dec esi
	mov edx, HP_BAR_WIDTH + 2
	mov ecx, HP_BAR_HEIGHT + 2
	mov r8d, 0x44FFFFFF ; lower opacity seems to look better
	call fill_rect

	; --- bg (red) for the full width ---
	mov edi, ebx
	mov esi, r13d
	mov edx, HP_BAR_WIDTH
	mov ecx, HP_BAR_HEIGHT
	mov r8d, 0xFFB02020			; dark red
	call fill_rect				; nice to get reuse of this!

	; --- fg (green) for the current fraction ---
	; fg_w = HP_BAR_WIDTH * hp / hp_max
	mov eax, HP_BAR_WIDTH
	imul eax, r12d
	cdq
	mov ecx, r14d
	idiv ecx
	test eax, eax
	jle .out					; nothing to draw if 0 wide

	mov edi, ebx
	mov esi, r13d
	mov edx, eax				; fg width
	mov ecx, HP_BAR_HEIGHT
	mov r8d, 0xFF00FF00			; bright green
	call fill_rect

.out:
	add rsp, 8
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

%endif