; spawn.inc.asm - periodic NPC spawning gated on the safezone mask
;----------------------------------------------------------------
; monsters spawn in dark tiles, heroes in lit tiles.  both share
; a frame counter so the world ticks them in alternation.  each
; type has its own cap and the loop just skips a side that's
; already at cap
;
; rules per attempt:
;	- tile must be walkable (speed 100)
;	- monsters:
;		- tile must be dark (safezone_at == 0)
;		- tile must be at least SPAWN_MONSTER_MIN_HUB_DIST tiles
;		  from the hub (chebyshev) so the player has breathing
;		  room to build before they encroach
;		- darkness must be above SPAWN_MONSTER_NIGHT_THRESHOLD,
;		  ie only at dusk/night
;	- heroes:
;		- tile must be lit (safezone_at != 0)
;		- tile sampled in a small radius around the hub, since the
;		  lit area is small relative to the world.  random-sampling
;		  the whole map would be wasteful
;
; timing: SPAWN_TICK_PERIOD frames between attempts.  each
; period rolls one side on ticks: evens try monsters, odds try heroes

%ifndef SPAWN_INC
%define SPAWN_INC

%define MONSTER_CAP				64
%define HERO_CAP				16
%define SPAWN_TICK_PERIOD		2;20;120
%define SPAWN_RETRIES			16	; per attempt

; min chebyshev distance from hub for monster spawns - gives us
; a buffer to build out the base before they attack
%define SPAWN_MONSTER_MIN_HUB_DIST	50

; darkness gate for monsters (0=day, 255=night).  > this lets them
; come out at dusk/night.  matches daynight_get_darkness output
%define SPAWN_MONSTER_NIGHT_THRESHOLD	40

; hero spawn search box around hub - keeps them appearing near the
; player rather than scattered round huge dark map
%define SPAWN_HERO_HUB_RADIUS		18

; how many heroes accompany the player at world start
%define STARTING_HERO_COUNT			3

; sprite base slots (must match what setup_world_entities used)
%define HERO_SPRITE_BASE		4
%define MONSTER_SPRITE_BASE		8

section .data
	log_msg_monster_spawn	db "a monster emerged from the dark!", 0
	log_msg_hero_spawn		db "a hero arrived!", 0
	log_msg_starting_heroes	db "your companions gather at the hub", 0

section .bss
	alignb 4
	spawn_tick_counter		resd 1	; counts up to SPAWN_TICK_PERIOD
	spawn_alternator		resd 1	; 0 = monsters, 1 = heroes

section .text

;================================================================
; spawn_reset: zero counters (call from world regen)
;================================================================
spawn_reset:
	mov dword [spawn_tick_counter], 0
	mov dword [spawn_alternator], 0
	ret

;================================================================
; count_alive_of_type: walk entity table, count alive of given type
;----------------------------------------------------------------
; in:  edi = ENT_TYPE_*
; out: eax = count
;================================================================
count_alive_of_type:
	push rbx
	push r12
	push r13
	; 3 pushes (24) = aligned for inner calls
	mov r13d, edi				; target type
	xor r12d, r12d				; count
	xor ebx, ebx				; idx
.loop:
	mov ecx, [entity_count]
	cmp ebx, ecx
	jge .done
	mov edi, ebx
	call entity_ptr				; rax = ent ptr
	movzx edx, byte [rax + ENT_FLAGS_OFFSET]
	test edx, ENT_FLAG_ALIVE
	jz .next
	movzx edx, byte [rax + ENT_TYPE_OFFSET]
	cmp edx, r13d
	jne .next
	inc r12d
.next:
	inc ebx
	jmp .loop
.done:
	mov eax, r12d
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; try_spawn_monster_at: validate + spawn a monster at (tx, ty)
;----------------------------------------------------------------
; returns the entity idx on success, -1 if any check fails.
; checks done here:
;	- in-bounds + walkable
;	- tile is dark (safezone_at == 0)
;	- chebyshev distance from hub >= SPAWN_MONSTER_MIN_HUB_DIST
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = entity idx on success, -1 on fail
;----------------------------------------------------------------
; stack frame (4 callee-saves + ret + sub 8 = 48, aligned):
;	r12 = tx, r13 = ty
;================================================================
try_spawn_monster_at:
	push rbx
	push r12
	push r13
	push r14
	sub rsp, 8

	mov r12d, edi				; tx
	mov r13d, esi				; ty

	; bounds
	test r12d, r12d
	js .fail
	cmp r12d, MAP_WIDTH
	jge .fail
	test r13d, r13d
	js .fail
	cmp r13d, MAP_HEIGHT
	jge .fail

	; need a dark tile (safezone_at == 0)
	mov edi, r12d
	mov esi, r13d
	call safezone_at
	test eax, eax
	jnz .fail

	; walkable centre?
	mov edi, r12d
	imul edi, TILE_SIZE
	add edi, TILE_SIZE / 2
	mov esi, r13d
	imul esi, TILE_SIZE
	add esi, TILE_SIZE / 2
	call tile_speed_at_pixel
	cmp eax, 100
	jne .fail

	; chebyshev from hub >= SPAWN_MONSTER_MIN_HUB_DIST
	mov eax, [hub_tx]
	sub eax, r12d
	test eax, eax
	jns .mh_dx_pos
	neg eax
.mh_dx_pos:
	mov r14d, eax				; |dx|
	mov eax, [hub_ty]
	sub eax, r13d
	test eax, eax
	jns .mh_dy_pos
	neg eax
.mh_dy_pos:
	; cheb = max(|dx|, |dy|)
	cmp eax, r14d
	jge .mh_have
	mov eax, r14d
.mh_have:
	cmp eax, SPAWN_MONSTER_MIN_HUB_DIST
	jl .fail

	; all checks passed - spawn!
	mov edi, ENT_TYPE_MONSTER
	mov esi, r12d
	imul esi, TILE_SIZE
	add esi, TILE_SIZE / 2
	mov edx, r13d
	imul edx, TILE_SIZE
	add edx, TILE_SIZE / 2
	mov ecx, MONSTER_SPRITE_BASE
	call entity_spawn
	cmp eax, 0
	jl .fail

	; randomise stats for this new npc
	mov edi, eax
	push rax
	sub rsp, 8					; align across the call
	call entity_roll_random_stats
	add rsp, 8
	pop rax

	add rsp, 8
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

.fail:
	mov eax, -1
	add rsp, 8
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; try_spawn_hero_at: validate + spawn a hero at (tx, ty)
;----------------------------------------------------------------
; checks done here:
;	- in-bounds + walkable
;	- tile is lit (safezone_at != 0)
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = entity idx on success, -1 on fail
;================================================================
try_spawn_hero_at:
	push rbx
	push r12
	push r13
	push r14
	; 4 pushes (32) + ret (8) = 40, 16-aligned for inner calls

	mov r12d, edi				; tx
	mov r13d, esi				; ty

	; bounds
	test r12d, r12d
	js .fail
	cmp r12d, MAP_WIDTH
	jge .fail
	test r13d, r13d
	js .fail
	cmp r13d, MAP_HEIGHT
	jge .fail

	; needs a lit tile (safezone_at != 0)
	mov edi, r12d
	mov esi, r13d
	call safezone_at
	test eax, eax
	jz .fail

	; walkable?
	mov edi, r12d
	imul edi, TILE_SIZE
	add edi, TILE_SIZE / 2
	mov esi, r13d
	imul esi, TILE_SIZE
	add esi, TILE_SIZE / 2
	call tile_speed_at_pixel
	cmp eax, 100
	jne .fail

	; spawn!
	mov edi, ENT_TYPE_HERO
	mov esi, r12d
	imul esi, TILE_SIZE
	add esi, TILE_SIZE / 2
	mov edx, r13d
	imul edx, TILE_SIZE
	add edx, TILE_SIZE / 2
	mov ecx, HERO_SPRITE_BASE
	call entity_spawn
	cmp eax, 0
	jl .fail

	mov edi, eax
	push rax
	sub rsp, 8					; align across the call
	call entity_roll_random_stats
	add rsp, 8
	pop rax

	pop r14
	pop r13
	pop r12
	pop rbx
	ret

.fail:
	mov eax, -1
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; try_spawn_monster: random tile across the whole map.  the
; *_at validator rejects any that fail the dark/distance checks
;----------------------------------------------------------------
; with the min-hub-dist enforced inside the validator, sampling
; uniformly is fine: we burn a few retries near the hub but
; everywhere else the tile is straight-up considered
;----------------------------------------------------------------
; stack: 2 pushes + sub 8 = 24 + ret 8 = 32, 16-aligned
;================================================================
try_spawn_monster:
	push rbx
	push r12
	sub rsp, 8
	mov ebx, SPAWN_RETRIES
.retry:
	test ebx, ebx
	jz .out
	dec ebx

	mov edi, MAP_WIDTH
	call rng_range
	mov r12d, eax				; tx
	mov edi, MAP_HEIGHT
	call rng_range
	mov esi, eax				; ty
	mov edi, r12d
	call try_spawn_monster_at
	cmp eax, 0
	jl .retry

	lea rdi, [log_msg_monster_spawn]
	call debug_log
.out:
	add rsp, 8
	pop r12
	pop rbx
	ret

;================================================================
; try_spawn_hero: sample tiles in a small box around the hub.
; the validator gates on lit + walkable.  most lit tiles are
; clustered round the hub torch anyway, so this converges fast
;----------------------------------------------------------------
; locals (4 pushes + sub 32 = 64 bytes -> 16-aligned for calls):
;	[rsp+0]   tx_lo
;	[rsp+4]   tx_hi
;	[rsp+8]   ty_lo
;	[rsp+12]  ty_hi
;	[rsp+16]  retries left
;================================================================
try_spawn_hero:
	push rbx
	push r12
	push r13
	push r14
	sub rsp, 32

	; box bounds: hub +/- SPAWN_HERO_HUB_RADIUS, clamped to the map
	mov eax, [hub_tx]
	sub eax, SPAWN_HERO_HUB_RADIUS
	test eax, eax
	jns .x_lo_ok
	xor eax, eax
.x_lo_ok:
	mov [rsp + 0], eax			; tx_lo
	mov eax, [hub_tx]
	add eax, SPAWN_HERO_HUB_RADIUS
	cmp eax, MAP_WIDTH
	jl .x_hi_ok
	mov eax, MAP_WIDTH - 1
.x_hi_ok:
	mov [rsp + 4], eax			; tx_hi

	mov eax, [hub_ty]
	sub eax, SPAWN_HERO_HUB_RADIUS
	test eax, eax
	jns .y_lo_ok
	xor eax, eax
.y_lo_ok:
	mov [rsp + 8], eax			; ty_lo
	mov eax, [hub_ty]
	add eax, SPAWN_HERO_HUB_RADIUS
	cmp eax, MAP_HEIGHT
	jl .y_hi_ok
	mov eax, MAP_HEIGHT - 1
.y_hi_ok:
	mov [rsp + 12], eax			; ty_hi

	mov dword [rsp + 16], SPAWN_RETRIES

.retry:
	mov eax, [rsp + 16]
	test eax, eax
	jz .out
	dec dword [rsp + 16]

	; tx = tx_lo + rng(tx_hi - tx_lo + 1)
	mov edi, [rsp + 4]
	sub edi, [rsp + 0]
	inc edi
	call rng_range
	add eax, [rsp + 0]
	mov r12d, eax				; tx

	; ty = ty_lo + rng(ty_hi - ty_lo + 1)
	mov edi, [rsp + 12]
	sub edi, [rsp + 8]
	inc edi
	call rng_range
	add eax, [rsp + 8]
	mov r13d, eax				; ty

	mov edi, r12d
	mov esi, r13d
	call try_spawn_hero_at
	cmp eax, 0
	jl .retry

	lea rdi, [log_msg_hero_spawn]
	call debug_log
.out:
	add rsp, 32
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; spawn_starting_heroes: place STARTING_HERO_COUNT heroes near
; the hub at world start.  spirals out from the hub looking for
; walkable lit tiles, places one per ring layer
;----------------------------------------------------------------
; called once after worldgen + safezone_recompute.  uses
; try_spawn_hero_at so the same lit/walkable rules apply
;================================================================
spawn_starting_heroes:
	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 16					; 5 pushes (40) + 16 + ret 8 = 64

	xor r15d, r15d				; placed count
	mov r14d, 1					; ring radius (in tiles)
.ring:
	; cap how far out we'll look - if no room within ~hub_radius we
	; give up rather than spawning miles away
	cmp r14d, SPAWN_HERO_HUB_RADIUS
	jg .done
	; walk to try and spawn
	mov ebx, [hub_ty]
	sub ebx, r14d				; ty walker = hub_ty - r
	mov r13d, [hub_ty]
	add r13d, r14d				; ty_max = hub_ty + r
.ring_row:
	cmp ebx, r13d
	jg .ring_done

	mov r12d, [hub_tx]
	sub r12d, r14d				; tx walker = hub_tx - r
.ring_col:
	mov eax, [hub_tx]
	add eax, r14d				; tx_max
	cmp r12d, eax
	jg .ring_row_done

	; only consider cells on the ring's edge (chebyshev == r) -
	; the interior was already swept by smaller r values
	mov eax, r12d
	sub eax, [hub_tx]
	test eax, eax
	jns .sh_dx_pos
	neg eax
.sh_dx_pos:
	mov ecx, eax				; |dx|
	mov eax, ebx
	sub eax, [hub_ty]
	test eax, eax
	jns .sh_dy_pos
	neg eax
.sh_dy_pos:
	cmp ecx, eax
	jge .sh_have
	mov ecx, eax
.sh_have:
	cmp ecx, r14d
	jne .ring_next_col			; not on the ring edge

	; ring tile - try to spawn here
	mov edi, r12d
	mov esi, ebx
	call try_spawn_hero_at
	cmp eax, 0
	jl .ring_next_col			; rejected (dark / blocked / oob)

	inc r15d
	cmp r15d, STARTING_HERO_COUNT
	jge .done

.ring_next_col:
	inc r12d
	jmp .ring_col
.ring_row_done:
	inc ebx
	jmp .ring_row
.ring_done:
	inc r14d
	jmp .ring

.done:
	test r15d, r15d
	jz .no_log
	lea rdi, [log_msg_starting_heroes]
	call debug_log
.no_log:
	add rsp, 16
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; spawn_tick: called each frame from the main loop
;----------------------------------------------------------------
; every SPAWN_TICK_PERIOD frames, alternates between trying to
; spawn a monster (in the dark) and a hero (in the light) so both
; populations grow over time. no spawn happens if its cap reached.
; monsters additionally need the world to be dark enough
;================================================================
spawn_tick:
	inc dword [spawn_tick_counter]
	cmp dword [spawn_tick_counter], SPAWN_TICK_PERIOD
	jl .out
	mov dword [spawn_tick_counter], 0

	; alternate
	mov eax, [spawn_alternator]
	xor dword [spawn_alternator], 1
	test eax, eax
	jnz .try_hero

	; monsters - only at dusk or later
	call daynight_get_darkness
	cmp eax, SPAWN_MONSTER_NIGHT_THRESHOLD
	jle .out					; too bright; no monster spawn
	mov edi, ENT_TYPE_MONSTER
	call count_alive_of_type
	cmp eax, MONSTER_CAP
	jge .out
	call try_spawn_monster
	jmp .out

.try_hero:
	mov edi, ENT_TYPE_HERO
	call count_alive_of_type
	cmp eax, HERO_CAP
	jge .out
	; -- housing gate --
	; allow the primary heroes but then don't let any more spawn til
	; we build some housing
	mov r8d, eax				; stash live hero count
	call room_total_capacity
	cmp r8d, eax
	jge .out					; pop >= cap, no vacancy
	call try_spawn_hero

.out:
	ret

%endif
