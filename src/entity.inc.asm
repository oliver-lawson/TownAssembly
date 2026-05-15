; entity.inc.asm - entity table + utilities
;
; we keep a fixed-size table of entities here
; entity 0 is reserved for player
; other systems can read/write [entity]_table] directly
;
;  ----- STRUCT LAYOUT -----
; 32 bytes for cache-line friendliness/indexing w/ <<5
;+0   x			  int32		pixel coords
;+4   y			  int32
;+8   type		  u8		ENT_TYPE_*
;+9   facing	  u8		FACE_*
;+10  sprite_slot u8		base slot in sprites texture (0..N)
;+11  anim_phase  u8		0/1 - which walk frame?
;+12  anim_timer  u8		counts up to ANIM_PERIOD
;+13  flags		  u8		bit 0 = alive, bit 1 = flip h this frame
;+14  hp		  u8
;+15  pad		  u8
;+16  ai_state	  u32		reserved for utility-AI tick state
;+20  ai_data	  u32		reserved (target tile, goal id, ..?)
;+24  pad		  u64		reserved
;
; the AI/collision/sort fields are reserved for future tinkering

%ifndef ENTITY_INC
%define ENTITY_INC

%define ENT_MAX		256
%define ENT_STRIDE	32

; collision radius
%define ENT_RADIUS	5

; facing direction values
%define FACE_DOWN	0
%define FACE_UP		1
%define FACE_LEFT	2
%define FACE_RIGHT	3

%define ANIM_PERIOD 10

; field offsets
%define ENT_X_OFFSET		0
%define ENT_Y_OFFSET		4
%define ENT_TYPE_OFFSET		8
%define ENT_FACING_OFFSET	9
%define ENT_SLOT_OFFSET		10
%define ENT_PHASE_OFFSET	11
%define ENT_TIMER_OFFSET	12
%define ENT_FLAGS_OFFSET	13
%define ENT_HP_OFFSET		14
%define ENT_HP_MAX_OFFSET	15
%define ENT_AI_DIR_OFFSET	16
%define ENT_AI_MODE_OFFSET	17
%define ENT_AI_TICKS_OFFSET	18
%define ENT_AI_ACCUM_OFFSET	20
%define ENT_AI_TARGET_OFFSET	24
%define ENT_BRAVERY_OFFSET	25
%define ENT_SPEED_OFFSET	26
%define ENT_DECISION_TICKS_OFFSET	27
%define ENT_ATTACK_TICKS_OFFSET		28

; wander direction values (also used as flee/engage direction)
%define AI_DIR_IDLE			0
%define AI_DIR_UP			1
%define AI_DIR_DOWN			2
%define AI_DIR_LEFT			3
%define AI_DIR_RIGHT		4

; AI macro states
%define AI_MODE_IDLE		0
%define AI_MODE_WANDER		1
%define AI_MODE_ENGAGING	2	; walking toward target
%define AI_MODE_FIGHTING	3	; adjacent + attacking
%define AI_MODE_FLEEING		4	; walking away from target

; sentinel for "no target"
%define AI_TARGET_NONE		0xFF

; flag bits
%define ENT_FLAG_ALIVE		0x01
%define ENT_FLAG_FLIP		0x02

; type ids
%define ENT_TYPE_NONE		0
%define ENT_TYPE_PLAYER		1
%define ENT_TYPE_HERO		2
%define ENT_TYPE_MONSTER	3
%define ENT_TYPE_ITEM		4

section .bss
	alignb 8
	entity_table		resb ENT_MAX * ENT_STRIDE
	entity_draw_order	resb ENT_MAX
	entity_count		resd 1	; number of slots actually populated
								; (highest used + 1)

section .data
	; 0.5 as IEEE-754 single: used by collision resolution to split
	; the pushback evenly between two NPCs, while i wonder how to do
	; this across frames or so to avoid floats
	collision_half		dd 0.5

section .text
;================================================================
; entity_clear_all: wipe the table back to empty
; called at startup and on world regen
;================================================================
entity_clear_all:
	push rdi
	push rcx
	push rax
	lea rdi, [entity_table]
	mov ecx, ENT_MAX * ENT_STRIDE
	xor eax, eax
	rep stosb
	mov dword [entity_count], 0
	pop rax
	pop rcx
	pop rdi
	ret

;================================================================
; entity_ptr: get pointer to entity #edi
;----------------------------------------------------------------
; in:  edi = entity index
; out: rax = ptr to entity
;================================================================
entity_ptr:
	mov eax, edi
	shl eax, 5		; * 32 (= ENT_STRIDE)
	lea rcx, [entity_table]
	add rax, rcx
	ret

;================================================================
; entity_spawn: find a free slot, fill in some defaults
;----------------------------------------------------------------
; in:  edi = type, esi = x (pixel), edx = y (pixel), ecx = sprite_slot
; out: eax = entity index, or -1 if table full
;================================================================
entity_spawn:
	push rbx
	push r12
	push r13
	push r14
	push r15

	mov r12d, edi	; type
	mov r13d, esi	; x
	mov r14d, edx	; y
	mov r15d, ecx	; slot

	; scan for first dead slot
	xor ebx, ebx
.scan:
	cmp ebx, ENT_MAX
	jge .full

	mov edi, ebx
	call entity_ptr
	movzx ecx, byte [rax + ENT_FLAGS_OFFSET]
	test ecx, ENT_FLAG_ALIVE
	jz .found
	inc ebx
	jmp .scan

.found:
	; rax already points at the entity
	mov [rax + ENT_X_OFFSET], r13d
	mov [rax + ENT_Y_OFFSET], r14d
	mov byte [rax + ENT_TYPE_OFFSET], r12b
	mov byte [rax + ENT_FACING_OFFSET], 0
	mov byte [rax + ENT_SLOT_OFFSET], r15b
	mov byte [rax + ENT_PHASE_OFFSET], 0
	mov byte [rax + ENT_TIMER_OFFSET], 0
	mov byte [rax + ENT_FLAGS_OFFSET], ENT_FLAG_ALIVE
	; default stats - spawn caller can overwrite for per-npc variance
	mov byte [rax + ENT_HP_OFFSET], 10
	mov byte [rax + ENT_HP_MAX_OFFSET], 10
	mov byte [rax + ENT_AI_DIR_OFFSET], AI_DIR_IDLE
	mov byte [rax + ENT_AI_MODE_OFFSET], AI_MODE_WANDER
	mov word [rax + ENT_AI_TICKS_OFFSET], 0
	mov dword [rax + ENT_AI_ACCUM_OFFSET], 0
	mov byte [rax + ENT_AI_TARGET_OFFSET], AI_TARGET_NONE
	mov byte [rax + ENT_BRAVERY_OFFSET], 128
	mov byte [rax + ENT_SPEED_OFFSET], 100
	mov byte [rax + ENT_DECISION_TICKS_OFFSET], 0
	mov byte [rax + ENT_ATTACK_TICKS_OFFSET], 0

	; bump entity_count if we extended past it
	mov eax, [entity_count]
	mov ecx, ebx
	inc ecx
	cmp ecx, eax
	jle .no_bump
	mov [entity_count], ecx
.no_bump:

	mov eax, ebx
	jmp .out
.full:
	mov eax, -1
.out:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; entity_kill: clear ENT_FLAG_ALIVE on entity #edi
;----------------------------------------------------------------
; not compacting the table - other systems may still hold indices
; needs more thought later, not sure how to manage lifecycles here
; properly
;================================================================
entity_kill:
	call entity_ptr
	mov byte [rax + ENT_FLAGS_OFFSET], 0
	ret

;================================================================
; entity_roll_random_stats: roll random stats for uniquer npcs
;----------------------------------------------------------------
; ranges:
;	hp_max  8..14   (also sets hp = hp_max)
;	bravery 30..220
;	speed   60..140 percent
;----------------------------------------------------------------
; in:	edi = entity index
;================================================================
entity_roll_random_stats:
	push rbx
	push r12
	mov r12d, edi
	call entity_ptr
	mov rbx, rax

	; hp_max = 8 + rng(7)  -> 8..14
	mov edi, 7
	call rng_range
	add eax, 8
	mov byte [rbx + ENT_HP_MAX_OFFSET], al
	mov byte [rbx + ENT_HP_OFFSET], al

	; bravery = 30 + rng(191) -> 30..220
	mov edi, 191
	call rng_range
	add eax, 30
	mov byte [rbx + ENT_BRAVERY_OFFSET], al

	; speed = 60 + rng(81) -> 60..140
	mov edi, 81
	call rng_range
	add eax, 60
	mov byte [rbx + ENT_SPEED_OFFSET], al

	pop r12
	pop rbx
	ret


;================================================================
; entity_sort_draw_order: insertion-sort indices by y ascending
;----------------------------------------------------------------
; entities with low y are drawn first so high-y sprites overlap them
; dead entities go to the end
; we still emit their indices, the draw routine skips them
;================================================================
entity_sort_draw_order:
	push rbx
	push r12
	push r13
	push r14
	push r15
	; 5 pushes + return addr = 48 = 16-aligned for inner calls

	; init the index array as identity, plus collect the y of each
	mov r12d, [entity_count]

	xor ebx, ebx
.fill:
	cmp ebx, r12d
	jge .fill_done
	lea rax, [entity_draw_order]
	mov [rax + rbx], bl
	inc ebx
	jmp .fill
.fill_done:
	; asm insertion sort! for i=1..n-1, lift entity_draw_order[i]
	; back until the prior element's y is <= ours
	;
	; rbx = i, r12 = count, r13 = key idx, r14 = key_y, r15 = j
	; keeping j in r15 (callee-saved) because rcx gets clobbered by
	; calls to entity_ptr inside the loop.. got confused by that one
	; for a while..
	mov ebx, 1
.outer:
	cmp ebx, r12d
	jge .out

	; key = entity_draw_order[i]
	lea rax, [entity_draw_order]
	movzx r13d, byte [rax + rbx]	; key index

	; key_y from the entity table
	mov edi, r13d
	call entity_ptr
	mov r14d, [rax + ENT_Y_OFFSET]		; key_y

	; j = i - 1
	mov r15d, ebx
	dec r15d
.inner:
	test r15d, r15d
	js .place						; j < 0
	; cmp entity_draw_order[j].y > key_y?
	lea rax, [entity_draw_order]
	movzx edi, byte [rax + r15]
	call entity_ptr
	mov edx, [rax + ENT_Y_OFFSET]
	cmp edx, r14d
	jle .place

	; shift: entity_draw_order[j+1] = entity_draw_order[j]
	lea rax, [entity_draw_order]
	movzx edx, byte [rax + r15]
	mov edi, r15d
	inc edi
	mov [rax + rdi], dl

	dec r15d
	jmp .inner

.place:
	; entity_draw_order[j+1] = key
	lea rax, [entity_draw_order]
	mov edi, r15d
	inc edi
	mov [rax + rdi], r13b

	inc ebx
	jmp .outer

.out:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; entity_try_move: player's try_move, but for an entity
;----------------------------------------------------------------
; in:  edi = entity index, esi = dx, edx = dy
; out: eax = 1 if the entity actually moved this frame, 0 otherwise
;================================================================
entity_try_move:
	push rbx
	push r12
	push r13
	push r14
	push r15

	mov r12d, edi		; entity index
	mov r13d, esi		; dx
	mov r14d, edx		; dy

	; ent ptr -> r15
	call entity_ptr
	mov r15, rax

	; destination = (x + dx, y + dy)
	mov edi, [r15 + ENT_X_OFFSET]
	add edi, r13d
	mov esi, [r15 + ENT_Y_OFFSET]
	add esi, r14d
	call tile_speed_at_pixel
	test eax, eax
	jz .blocked

	; combine with entity-specific speed.  both are percentages, so:
	;	combined = tile% * entity% / 100
	; aka on water(50%) at sspeed 50%: 25%. on grass with 100%? 100%.
	movzx ecx, byte [r15 + ENT_SPEED_OFFSET]
	imul eax, ecx
	mov ecx, 100
	xor edx, edx
	div ecx						; eax = combined %

	test eax, eax
	jz .blocked					; 0% combined -> treat as block

	; accumulate
	add [r15 + ENT_AI_ACCUM_OFFSET], eax
	cmp dword [r15 + ENT_AI_ACCUM_OFFSET], 100
	jl .not_yet
	sub dword [r15 + ENT_AI_ACCUM_OFFSET], 100
	add [r15 + ENT_X_OFFSET], r13d
	add [r15 + ENT_Y_OFFSET], r14d
	mov eax, 1
	jmp .out

.blocked:
	; clear accum so a stuck entity doesn't pop on the next free tick
	mov dword [r15 + ENT_AI_ACCUM_OFFSET], 0
	; fallthrough as no-move:
.not_yet:
	xor eax, eax
.out:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; entity_try_open_door_in_dir
;----------------------------------------------------------------
; if the tile one step in front of entity #edi (in direction dx,dy)
; is a closed door, open it. used by NPCs to push through doors
; that are blocking them. closing them is left to the player for now
;
; we use the *destination tile* of the attempted step rather than
; "tile in facing direction" because entity speed varies with tile
; (water etc) and at sub-pixel rates the destination computed here
; matches what entity_try_move just rejected
;----------------------------------------------------------------
; in:  edi = entity index, esi = dx, edx = dy
; out: eax = 1 if a door was opened, 0 otherwise
;================================================================
entity_try_open_door_in_dir:
	push rbx
	push r12
	mov ebx, esi			; dx
	mov r12d, edx			; dy

	; ent ptr -> rax
	call entity_ptr

	; destination pixel = (x + dx, y + dy)
	mov edi, [rax + ENT_X_OFFSET]
	add edi, ebx
	mov esi, [rax + ENT_Y_OFFSET]
	add esi, r12d

	; convert to tile coords (matches tile_at_pixel's floor-divide)
	; for our use we only ever pass small integer dx/dy, so the
	; entity centre + dx is normally still in-bounds; tile_at handles
	; oob as TILE_STONE which won't match a door anyway
	mov eax, edi
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	test edx, edx
	jns .x_ok
	dec eax
.x_ok:
	mov ebx, eax			; tx

	mov eax, esi
	cdq
	idiv ecx
	test edx, edx
	jns .y_ok
	dec eax
.y_ok:
	mov r12d, eax			; ty

	; is it a closed door?
	mov edi, ebx
	mov esi, r12d
	call object_at
	call tile_is_door_closed
	test eax, eax
	jz .nope

	; open it
	mov edi, ebx
	mov esi, r12d
	call door_toggle_at
	mov eax, 1
	jmp .out
.nope:
	xor eax, eax
.out:
	pop r12
	pop rbx
	ret

;================================================================
; entity_wander_tick: per-frame AI for a single wander-style entity
;----------------------------------------------------------------
; if its direction-countdown runs out, picks a new (direction, ticks)
; pair via rng.  else drives a move in the current direction and
; updates facing + animation
;----------------------------------------------------------------
; in: edi = entity index
;================================================================
%define WANDER_STEP	1	; keep same as player's move_step?

entity_wander_tick:
	push rbx
	push r12
	push r13
	; 3 callee-saved + return = 32 bytes - 16-aligned for inner calls
	push rbp
	mov rbp, rsp
	mov ebx, edi		; ebx = ent index
	call entity_ptr
	mov r13, rax		; r13 = ent ptr

	; --- decide phase: if ticks <= 0, pick new dir + countdown ---
	movzx eax, word [r13 + ENT_AI_TICKS_OFFSET]
	test eax, eax
	jnz .have_dir

	; pick new direction
	mov edi, 5
	call rng_range
	mov byte [r13 + ENT_AI_DIR_OFFSET], al

	; ticks = 30 + rng_range(60) -> 30..89 frames at this direction
	mov edi, 60
	call rng_range
	add eax, 30
	mov word [r13 + ENT_AI_TICKS_OFFSET], ax

.have_dir:
	; decrement countdown (either just set it, or it was already>0)
	movzx eax, word [r13 + ENT_AI_TICKS_OFFSET]
	dec eax
	mov word [r13 + ENT_AI_TICKS_OFFSET], ax

	; map direction -> (dx, dy) and update facing
	movzx eax, byte [r13 + ENT_AI_DIR_OFFSET]
	xor r12d, r12d			; dx = 0
	xor ecx, ecx			; dy = 0
	cmp eax, AI_DIR_UP
	je .d_up
	cmp eax, AI_DIR_DOWN
	je .d_down
	cmp eax, AI_DIR_LEFT
	je .d_left
	cmp eax, AI_DIR_RIGHT
	je .d_right
	; fallthrough = idle: dx=dy=0, no move, no facing change:
	jmp .move
.d_up:
	mov ecx, -WANDER_STEP
	mov byte [r13 + ENT_FACING_OFFSET], FACE_UP
	jmp .move
.d_down:
	mov ecx, WANDER_STEP
	mov byte [r13 + ENT_FACING_OFFSET], FACE_DOWN
	jmp .move
.d_left:
	mov r12d, -WANDER_STEP
	mov byte [r13 + ENT_FACING_OFFSET], FACE_LEFT
	jmp .move
.d_right:
	mov r12d, WANDER_STEP
	mov byte [r13 + ENT_FACING_OFFSET], FACE_RIGHT
.move:
	; if dx and dy are both zero, skip move + animate idle
	mov eax, r12d
	or eax, ecx
	jz .idle

	mov edi, ebx
	mov esi, r12d
	mov edx, ecx
	call entity_try_move
	test eax, eax
	jz .blocked_animate	; couldn't move - re-pick direction soon

	; moved: tick anim timer, flip phase on overflow
	movzx eax, byte [r13 + ENT_TIMER_OFFSET]
	inc eax
	cmp eax, ANIM_PERIOD
	jl .anim_timer_save
	xor eax, eax		; reset timer
	movzx ecx, byte [r13 + ENT_PHASE_OFFSET]
	xor ecx, 1
	mov byte [r13 + ENT_PHASE_OFFSET], cl
.anim_timer_save:
	mov byte [r13 + ENT_TIMER_OFFSET], al
	jmp .out

.blocked_animate:
	; bumped *something* - if it was a closed door we can just open it
	; and try again next tick. otherwise cancel the direction so a new
	; one is picked
	;
	; recompute (dx, dy) from AI_DIR_OFFSET because entity_try_move
	; clobbers ecx so our dy is gone by here
	xor esi, esi			; dx
	xor edx, edx			; dy
	movzx eax, byte [r13 + ENT_AI_DIR_OFFSET]
	cmp eax, AI_DIR_UP
	jne .ba_not_up
	mov edx, -WANDER_STEP
	jmp .ba_have_dir
.ba_not_up:
	cmp eax, AI_DIR_DOWN
	jne .ba_not_down
	mov edx, WANDER_STEP
	jmp .ba_have_dir
.ba_not_down:
	cmp eax, AI_DIR_LEFT
	jne .ba_not_left
	mov esi, -WANDER_STEP
	jmp .ba_have_dir
.ba_not_left:
	cmp eax, AI_DIR_RIGHT
	jne .ba_have_dir
	mov esi, WANDER_STEP
.ba_have_dir:
	mov edi, ebx
	call entity_try_open_door_in_dir
	mov word [r13 + ENT_AI_TICKS_OFFSET], 0
	;jmp .idle
.idle:
	mov byte [r13 + ENT_TIMER_OFFSET], 0
	mov byte [r13 + ENT_PHASE_OFFSET], 0
.out:
	pop rbp
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; entity_tick_all: walk the table & tick each alive non-player entity
;----------------------------------------------------------------
; TODO: player still uses its own movement code in main.asm
;================================================================
entity_tick_all:
	push rbx
	push r12
	push r13

	xor ebx, ebx	; loop index
	mov r12d, [entity_count]
.loop:
	cmp ebx, r12d
	jge .done

	mov edi, ebx
	call entity_ptr
	mov r13, rax

	; skip dead
	movzx eax, byte [r13 + ENT_FLAGS_OFFSET]
	test eax, ENT_FLAG_ALIVE
	jz .skip

	; dispatch by type (player skipped, AI runs for hero/monster)
	movzx eax, byte [r13 + ENT_TYPE_OFFSET]
	cmp eax, ENT_TYPE_PLAYER
	je .skip
	cmp eax, ENT_TYPE_NONE
	je .skip

	mov edi, ebx
	call ai_tick

.skip:
	inc ebx
	jmp .loop
.done:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; entity_apply_push: shift an entity by (dx, dy)
;----------------------------------------------------------------
; only pushes along axes that don't end up on a blocked tile
; this lets pushed entities slide instead of entering walls
;----------------------------------------------------------------
; in: rdi = entity ptr, esi = dx, edx = dy
;================================================================
entity_apply_push:
	push rbx
	push r12
	push r13
	mov rbx, rdi		; ent ptr
	mov r12d, esi		; dx
	mov r13d, edx		; dy

	; --- try x? ---
	test r12d, r12d
	jz .skip_x
	mov edi, [rbx + ENT_X_OFFSET]
	add edi, r12d				 ; new x
	mov esi, [rbx + ENT_Y_OFFSET];current y(axes moved independently)
	call tile_speed_at_pixel
	test eax, eax
	jz .skip_x					 ; blocked - drop x component
	add [rbx + ENT_X_OFFSET], r12d
.skip_x:

	; --- try y? ---
	test r13d, r13d
	jz .skip_y
	mov edi, [rbx + ENT_X_OFFSET]	; possibly already-updated x
	mov esi, [rbx + ENT_Y_OFFSET]
	add esi, r13d					; new y
	call tile_speed_at_pixel
	test eax, eax
	jz .skip_y
	add [rbx + ENT_Y_OFFSET], r13d
.skip_y:

	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; entity_resolve_collisions
;----------------------------------------------------------------
; for every alive pair within 2*ENT_RADIUS of each other, push them
; apart along the line joining their centres
; the player is treated as immovable by this for now;
; NPCs get full pushback from player or half from one another
;================================================================
entity_resolve_collisions:
	push rbx
	push r12
	push r13
	push r14
	push r15
	; 5 callee-saves + return = 48 bytes on stack -> 16-aligned
	; we make no calls that need stack alignment here (sqrtss, etc
	; are SSE instructions, not function calls), so no further adjust

	mov r12d, [entity_count]
	cmp r12d, 2
	jl .done			; need at least 2 entities

	xor ebx, ebx		; outer index i = 0
.outer:
	cmp ebx, r12d
	jge .done

	; load entity i, skip if dead
	mov edi, ebx
	call entity_ptr
	mov r13, rax
	movzx eax, byte [r13 + ENT_FLAGS_OFFSET]
	test eax, ENT_FLAG_ALIVE
	jz .next_outer

	; inner index j = i + 1
	mov r14d, ebx
	inc r14d
.inner:
	cmp r14d, r12d
	jge .next_outer

	mov edi, r14d
	call entity_ptr
	mov r15, rax
	movzx eax, byte [r15 + ENT_FLAGS_OFFSET]
	test eax, ENT_FLAG_ALIVE
	jz .next_inner

	; dx = xj - xi, dy = yj - yi
	mov eax, [r15 + ENT_X_OFFSET]
	sub eax, [r13 + ENT_X_OFFSET]
	mov edi, eax		; edi = dx (signed)

	mov eax, [r15 + ENT_Y_OFFSET]
	sub eax, [r13 + ENT_Y_OFFSET]
	mov esi, eax		; esi = dy (signed)

	; quick AABB reject: |dx|>2R or |dy|>2R, no chance of overlap:
	mov eax, edi
	; abs in eax
	cdq
	xor eax, edx
	sub eax, edx
	cmp eax, 2 * ENT_RADIUS
	jg .next_inner
	mov eax, esi
	cdq
	xor eax, edx
	sub eax, edx
	cmp eax, 2 * ENT_RADIUS
	jg .next_inner

	; dist2 = dx*dx + dy*dy
	mov eax, edi
	imul eax, eax
	mov ecx, esi
	imul ecx, ecx
	add eax, ecx
	; if dist2 == 0, uh oh..: push j to the right by 1px
	test eax, eax
	jz .coincident
	; if dist2 >= (2R)^2, no overlap
	cmp eax, (2 * ENT_RADIUS) * (2 * ENT_RADIUS)
	jge .next_inner

	; --- compute dist via sqrtss; build push along dx,dy ---
	; xmm0 = sqrt(dist2)
	cvtsi2ss xmm0, eax
	sqrtss xmm0, xmm0
	; overlap = 2R - dist (positive, since dist < 2R)
	mov ecx, 2 * ENT_RADIUS
	cvtsi2ss xmm1, ecx
	subss xmm1, xmm0				; xmm1 = overlap

	; push direction = (dx,dy) / dist, magnitude per side = overlap/2
	; compute scale = (overlap/2) / dist once, then multiply
	movss xmm2, xmm1
	mulss xmm2, [collision_half]	; xmm2 = overlap/2
	divss xmm2, xmm0				; xmm2 = scale

	; pdx = round(dx * scale), pdy = round(dy * scale)
	; rounding (not truncating) means small fractional pushes go to 0
	; rather than getting bumped to +/- 1 - the latter was causing 
	; jitter when entities were almost touching. small overlaps just
	; persist for a frame or two until movement breaks the symmetry
	cvtsi2ss xmm3, edi				; xmm3 = dx (float)
	mulss xmm3, xmm2
	cvtss2si r8d, xmm3				; r8d = pdx (round-to-nearest)

	cvtsi2ss xmm3, esi
	mulss xmm3, xmm2
	cvtss2si r9d, xmm3				; r9d = pdy

	; if both push components are zero this pair contributes nothing
	; this frame - skip without bothering to do the player branching
	mov eax, r8d
	or eax, r9d
	jz .next_inner

	; apply: i moves by -p, j moves by +p
	; EXCEPT if either side is the player (entity 0):
	; the player never moves; the other side gets the full push
	;
	; we route through entity_apply_push so the new position gets
	; tile-walkability-checked per axis - prevents NPC world clipping
	test ebx, ebx
	jnz .i_movable
	; i is the player: only push j, by 2*p
	mov rdi, r15
	mov esi, r8d
	add esi, r8d
	mov edx, r9d
	add edx, r9d
	call entity_apply_push
	jmp .next_inner

.i_movable:
	test r14d, r14d
	jnz .both_movable
	; j is the player
	; this shouldn't really happen since j > i and player is 0..
	; only push i, by 2*p in the opposite direction
	mov rdi, r13
	mov esi, r8d
	add esi, r8d
	neg esi
	mov edx, r9d
	add edx, r9d
	neg edx
	call entity_apply_push
	jmp .next_inner

.both_movable:
	; standard case: split push between i and j. r8/r9 are caller
	; saved so we stash them on the stack across the first call
	push r8
	push r9
	mov rdi, r13
	mov esi, r8d
	neg esi
	mov edx, r9d
	neg edx
	call entity_apply_push
	pop r9
	pop r8
	mov rdi, r15
	mov esi, r8d
	mov edx, r9d
	call entity_apply_push
	jmp .next_inner

.coincident:
	; exactly the same position!.. just nudge j right by 1px
	; (will resolve properly next frame, as dist2 > 0)
	inc dword [r15 + ENT_X_OFFSET]
	jmp .next_inner

.next_inner:
	inc r14d
	jmp .inner

.next_outer:
	inc ebx
	jmp .outer

.done:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

%endif