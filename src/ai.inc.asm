; ai.inc.asm - utility-AI macro/micro tier for hero & monster NPCs
;----------------------------------------------------------------
; each NPC has:
; 3 randomised stat bytes, set at spawn:
;	hp_max
;	bravery	- 0..255, how willing to engage instead of flee
;	speed	- movement % vs base (50 = half speed, 150 = 1.5x)
;
; & AI state:
;	ai_mode			- IDLE/WANDER/ENGAGING/FIGHTING/FLEEING
;	ai_target		- entity index of enemy, AI_TARGET_NONE = none
;	decision_ticks 	- per-frame countdown to next macro decision
;	attack_ticks	- per-frame countdown to next melee attack
; ---
; macro/micro decision split:
; the macro tier picks ai_mode state every DECISION_PERIOD frames by
; scoring each candidate goal
; the micro tier (called from entity_tick_all) drives the per-frame
; behaviour for current mode
;----------------------------------------------------------------
%ifndef AI_INC
%define AI_INC

%define DECISION_PERIOD			30	; frames between macro decisions
%define AGGRO_RADIUS_TILES		8	; sight range
%define ENGAGE_DAMAGE			2	; damage per melee attack
%define ATTACK_PERIOD			30	; frames between attacks
%define FIGHT_RANGE_PX			18	; AABB-ish range for "adjacent"
%define ENGAGE_STEP				1	; px per AI tick when chasing
%define FLEE_STEP				1	; px per AI tick when fleeing

section .text

;================================================================
; ai_is_enemy: do entity types A and B fight each other?
;----------------------------------------------------------------
; in:	dil = type a, sil = type b
; out:	eax = 1 if enemies, 0 otherwise
;================================================================
ai_is_enemy:
	; hero <-> monster
	cmp dil, ENT_TYPE_HERO
	jne .not_hero_first
	cmp sil, ENT_TYPE_MONSTER
	je .yes
	jmp .no
.not_hero_first:
	cmp dil, ENT_TYPE_MONSTER
	jne .check_player
	cmp sil, ENT_TYPE_HERO
	je .yes
	cmp sil, ENT_TYPE_PLAYER
	je .yes
	jmp .no
.check_player:
	xor eax, eax
	ret
.yes:
	mov eax, 1
	ret
.no:
	xor eax, eax
	ret

;================================================================
; ai_find_nearest_enemy: scan the entity table for the closest
; alive enemy of the given type, within AGGRO_RADIUS_TILES
;----------------------------------------------------------------
; using chebyshev distance in pixels (px/TILE_SIZE for tile range)
; in:	edi = self entity index
; out:	eax = enemy entity idx, or -1 if none in range
;----------------------------------------------------------------
; locals on stack (3 pushes + sub 8 = 32, aligned):
;	[rsp+0]  self idx
;	[rsp+4]  self type
;	[rsp+8]  best distance so far
;	[rsp+12] best idx
;================================================================
ai_find_nearest_enemy:
	push rbx
	push r12
	push r13
	sub rsp,16

	mov [rsp + 0], edi			; self idx
	call entity_ptr
	movzx eax, byte [rax + ENT_TYPE_OFFSET]
	mov [rsp + 4], eax			; self type
	; self x,y stashed in callee-saved regs so we don't have to
	; reload each iter
	mov edi, [rsp + 0]
	call entity_ptr
	mov r12d, [rax + ENT_X_OFFSET]
	mov r13d, [rax + ENT_Y_OFFSET]

	mov dword [rsp + 8], 0x7FFFFFFF; init best distance @ infinity
	mov dword [rsp + 12], -1

	xor ebx, ebx				; idx walker
.loop:
	mov ecx, [entity_count]
	cmp ebx, ecx
	jge .done

	; skip self
	cmp ebx, [rsp + 0]
	je .next

	mov edi, ebx
	call entity_ptr

	; alive?
	movzx ecx, byte [rax + ENT_FLAGS_OFFSET]
	test ecx, ENT_FLAG_ALIVE
	jz .next

	; enemy of self?
	movzx edi, byte [rsp + 4]
	movzx esi, byte [rax + ENT_TYPE_OFFSET]
	push rax					; preserve entity ptr across call
	push rcx					; align
	call ai_is_enemy
	pop rcx
	pop rdx						; entity ptr restored to rdx
	test eax, eax
	jz .next

	; chebyshev distance = max(|dx|, |dy|), in pixels
	mov eax, [rdx + ENT_X_OFFSET]
	sub eax, r12d
	test eax, eax
	jns .dx_pos
	neg eax
.dx_pos:
	mov ecx, [rdx + ENT_Y_OFFSET]
	sub ecx, r13d
	test ecx, ecx
	jns .dy_pos
	neg ecx
.dy_pos:
	; cheb = max(eax, ecx)
	cmp eax, ecx
	jge .have_cheb
	mov eax, ecx
.have_cheb:
	; reject if beyond AGGRO_RADIUS in tiles (convert pixels)
	cmp eax, AGGRO_RADIUS_TILES * TILE_SIZE
	jg .next

	;new best?
	cmp eax, [rsp + 8]
	jge .next
	mov [rsp + 8], eax
	mov [rsp + 12], ebx

.next:
	inc ebx
	jmp .loop
.done:
	mov eax, [rsp + 12]
	add rsp, 16
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; ai_decide: pick the AI mode based on stats + world state
;----------------------------------------------------------------
; called every DECISION_PERIOD frames per NPC
; scores 3 candidate modes (WANDER/ENGAGING/FLEEING), picks the max
;
; scoring (all yield small int values):
;	WANDER	= 30 baseline + 1d10 random jitter
;	ENGAGE	= (bravery + hp_pct) - 0  if no enemy in range
;			  else (bravery + hp_pct) - dist_tiles*5
;	FLEE	= enemy_in_range
;			  ? (1.5*missing_hp_pct + (255-bravery)/2) +close_bonus
;			  : 0
;
; missing_hp_pct = (1 - hp/hp_max) * 100
; hp_pct = hp/hp_max * 100
;
; assigns ai_mode and ai_target.  if entering fighting range
; while engaging, ai_decide instead picks FIGHTING - micro tier
; will keep us there so long as the target's alive + close
;----------------------------------------------------------------
; in:	edi = entity index
;----------------------------------------------------------------
; locals on stack after prologue (4 pushes + sub 32 = 64 aligned):
;	[rsp+0]  self idx
;	[rsp+4]  hp_pct (0..100)
;	[rsp+8]  bravery
;	[rsp+12] enemy idx (-1 if none)
;	[rsp+16] enemy dist in pixels
;	[rsp+20] score wander
;	[rsp+24] score engage
;	[rsp+28] score flee
;================================================================
ai_decide:
	push rbx
	push r12
	push r13
	push r14
	sub rsp, 40		; 4 pushes (32) + 40 = 72 -> aligned

	mov [rsp + 0], edi

	; self ptr -> r12
	call entity_ptr
	mov r12, rax

	; hp_pct = hp * 100 / hp_max (saturated to >=1 hp_max)
	movzx eax, byte [r12 + ENT_HP_OFFSET]
	imul eax, 100
	movzx ecx, byte [r12 + ENT_HP_MAX_OFFSET]
	test ecx, ecx
	jnz .hpmax_ok
	mov ecx, 1
.hpmax_ok:
	xor edx, edx
	div ecx
	mov [rsp + 4], eax			; hp_pct
	mov ebx, eax				; ebx = hp_pct for arithmetic

	movzx eax, byte [r12 + ENT_BRAVERY_OFFSET]
	mov [rsp + 8], eax			; bravery
	mov r13d, eax				; r13 = bravery

	; find nearest enemy
	mov edi, [rsp + 0]
	call ai_find_nearest_enemy
	mov [rsp + 12], eax
	mov r14d, eax				; r14 = enemy idx (-1 = none)

	; compute enemy distance in pixels (only valid if r14 != -1)
	test r14d, r14d
	js .no_enemy
	mov edi, r14d
	call entity_ptr
	mov ecx, [rax + ENT_X_OFFSET]
	sub ecx, [r12 + ENT_X_OFFSET]
	test ecx, ecx
	jns .ed_dx_pos
	neg ecx
.ed_dx_pos:
	mov edx, [rax + ENT_Y_OFFSET]
	sub edx, [r12 + ENT_Y_OFFSET]
	test edx, edx
	jns .ed_dy_pos
	neg edx
.ed_dy_pos:
	cmp ecx, edx
	jge .ed_have
	mov ecx, edx
.ed_have:
	mov [rsp + 16], ecx			; enemy_dist_px
	jmp .compute_scores
.no_enemy:
	mov dword [rsp + 16], 0x7FFFFFFF

.compute_scores:
	; --- WANDER ---
	; 30 + rng(10)
	mov edi, 10
	push rax	; align
	call rng_range
	pop rcx
	add eax, 30
	mov [rsp + 20], eax

	; --- ENGAGE ---
	; needs an enemy.  base = bravery + hp_pct
	; penalty = dist_tiles * 5  (distance in pixels / TILE_SIZE)
	test r14d, r14d
	js .engage_zero
	mov eax, r13d				; bravery
	add eax, ebx				; + hp_pct
	mov ecx, [rsp + 16]
	; ecx = dist px.  convert to tiles
	shr ecx, 4					; / 16 (TILE_SIZE)
	imul ecx, 5
	sub eax, ecx
	test eax, eax
	jns .engage_store
	xor eax, eax
.engage_store:
	mov [rsp + 24], eax
	jmp .flee_score
.engage_zero:
	mov dword [rsp + 24], 0

.flee_score:
	; --- FLEE ---
	; needs an enemy too.  more compelling when low hp + low bravery
	; missing_hp = 100 - hp_pct.  contribution = missing_hp * 3/2
	; bravery contribution = (255 - bravery) / 2
	test r14d, r14d
	js .flee_zero
	mov eax, 100
	sub eax, ebx	; missing_hp_pct
	imul eax, 3
	shr eax, 1		; * 1.5
	mov ecx, 255
	sub ecx, r13d
	shr ecx, 1
	add eax, ecx
	; close bonus: if enemy within 3 tiles, +30, seems good
	mov ecx, [rsp + 16]
	cmp ecx, 3 * TILE_SIZE
	jg .flee_save
	add eax, 30
.flee_save:
	mov [rsp + 28], eax
	jmp .pick
.flee_zero:
	mov dword [rsp + 28], 0

.pick:
	; pick the max-scoring mode
	mov eax, [rsp + 20]	; wander
	mov ecx, AI_MODE_WANDER

	cmp [rsp + 24], eax
	jle .skip_engage
	mov eax, [rsp + 24]
	mov ecx, AI_MODE_ENGAGING
.skip_engage:

	cmp [rsp + 28], eax
	jle .skip_flee
	mov eax, [rsp + 28]
	mov ecx, AI_MODE_FLEEING
.skip_flee:

	; --- promote to FIGHTING if engaging and close enough ---
	; ai_decide is called periodically while the entity is already
	; in a mode, so thi sshould stick.  if we'd pick ENGAGE,
	; AND the enemy is close, jump to FIGHTING instead
	cmp ecx, AI_MODE_ENGAGING
	jne .write_mode
	mov edx, [rsp + 16]
	cmp edx, FIGHT_RANGE_PX
	jg .write_mode
	mov ecx, AI_MODE_FIGHTING

.write_mode:
	mov byte [r12 + ENT_AI_MODE_OFFSET], cl

	; target idx (low byte of r14 or sentinel)
	test r14d, r14d 
	js .clear_target
	mov byte [r12 + ENT_AI_TARGET_OFFSET], r14b
	jmp .ticks
.clear_target:
	mov byte [r12 + ENT_AI_TARGET_OFFSET], AI_TARGET_NONE

.ticks:
	; reset the decision countdown.  add a tiny jitter so all npcs
	; don't tick on the same frame
	mov edi, 8
	push rax
	call rng_range
	pop rcx
	add eax, DECISION_PERIOD
	cmp eax, 255
	jle .ticks_ok
	mov eax, 255
.ticks_ok:
	mov byte [r12 + ENT_DECISION_TICKS_OFFSET], al

	add rsp, 40
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; ai_step_toward: pick the cardinal AI_DIR_ that closes distance
; to (target_x, target_y) most.  used by ENGAGING
;----------------------------------------------------------------
; in:	edi = self entity idx, esi = target entity idx
; sets self.ai_dir + self.facing
; returns no value
;================================================================
ai_step_toward:
	push rbx
	push r12
	push r13
	; 3 pushes (24) + ret = aligned
	mov ebx, edi
	mov r12d, esi

	; self ptr
	mov edi, ebx
	call entity_ptr
	mov r13, rax

	; tgt ptr
	mov edi, r12d
	call entity_ptr

	; dx, dy = target - self (signed)
	mov edx, [rax + ENT_X_OFFSET]
	sub edx, [r13 + ENT_X_OFFSET]
	mov ecx, [rax + ENT_Y_OFFSET]
	sub ecx, [r13 + ENT_Y_OFFSET]

	; pick larger axis; tie -> x
	mov eax, edx
	test eax, eax
	jns .ax_pos
	neg eax
.ax_pos:
	mov edi, ecx
	test edi, edi
	jns .ay_pos
	neg edi
.ay_pos:

	cmp eax, edi
	jl .pick_y	; |dy| > |dx| -> step y

	; step x: by sign of dx
	test edx, edx
	jns .step_right
	mov byte [r13 + ENT_AI_DIR_OFFSET], AI_DIR_LEFT
	mov byte [r13 + ENT_FACING_OFFSET], FACE_LEFT
	jmp .out
.step_right:
	mov byte [r13 + ENT_AI_DIR_OFFSET], AI_DIR_RIGHT
	mov byte [r13 + ENT_FACING_OFFSET], FACE_RIGHT
	jmp .out

.pick_y:
	test ecx, ecx
	jns .step_down
	mov byte [r13 + ENT_AI_DIR_OFFSET], AI_DIR_UP
	mov byte [r13 + ENT_FACING_OFFSET], FACE_UP
	jmp .out
.step_down:
	mov byte [r13 + ENT_AI_DIR_OFFSET], AI_DIR_DOWN
	mov byte [r13 + ENT_FACING_OFFSET], FACE_DOWN

.out:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; ai_step_away: mirror of ai_step_toward, picks the dir that
; increases distance from target.  used by FLEEING
;----------------------------------------------------------------
; in:	edi = self entity idx, esi = target entity idx
;================================================================
ai_step_away:
	push rbx
	push r12
	push r13
	mov ebx, edi
	mov r12d, esi

	mov edi, ebx
	call entity_ptr
	mov r13, rax

	mov edi, r12d
	call entity_ptr

	; flee dir is the opposite of step-toward: target - self, then
	; pick larger axis, then step AWAY from target along that axis
	mov edx, [rax + ENT_X_OFFSET]
	sub edx, [r13 + ENT_X_OFFSET]
	mov ecx, [rax + ENT_Y_OFFSET]
	sub ecx, [r13 + ENT_Y_OFFSET]

	mov eax, edx
	test eax, eax
	jns .ax_pos
	neg eax
.ax_pos:
	mov edi, ecx
	test edi, edi
	jns .ay_pos
	neg edi
.ay_pos:

	cmp eax, edi
	jl .pick_y

	; flee along x: opposite sign of dx
	test edx, edx
	jns .away_left	; target is to our right -> we go left
	mov byte [r13 + ENT_AI_DIR_OFFSET], AI_DIR_RIGHT
	mov byte [r13 + ENT_FACING_OFFSET], FACE_RIGHT
	jmp .out
.away_left:
	mov byte [r13 + ENT_AI_DIR_OFFSET], AI_DIR_LEFT
	mov byte [r13 + ENT_FACING_OFFSET], FACE_LEFT
	jmp .out

.pick_y:
	test ecx, ecx
	jns .away_up
	mov byte [r13 + ENT_AI_DIR_OFFSET], AI_DIR_DOWN
	mov byte [r13 + ENT_FACING_OFFSET], FACE_DOWN
	jmp .out
.away_up:
	mov byte [r13 + ENT_AI_DIR_OFFSET], AI_DIR_UP
	mov byte [r13 + ENT_FACING_OFFSET], FACE_UP

.out:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; ai_move_in_dir: take one move step using the entity's current
; ai_dir.  same animation tick logic as wander.  used by ENGAGING
; and FLEEING which both want to keep walking once a dir is set
;----------------------------------------------------------------
; in:	edi = entity idx
;================================================================
ai_move_in_dir:
	push rbx
	push r12
	push r13
	; 3 pushes = aligned
	mov ebx, edi
	call entity_ptr
	mov r13, rax

	mov esi, 0	; dx
	mov edx, 0	; dy
	movzx eax, byte [r13 + ENT_AI_DIR_OFFSET]
	cmp eax, AI_DIR_UP
	jne .not_up
	mov edx, -ENGAGE_STEP
	jmp .have
.not_up:
	cmp eax, AI_DIR_DOWN
	jne .not_down
	mov edx, ENGAGE_STEP
	jmp .have
.not_down:
	cmp eax, AI_DIR_LEFT
	jne .not_left
	mov esi, -ENGAGE_STEP
	jmp .have
.not_left:
	cmp eax, AI_DIR_RIGHT
	jne .have
	mov esi, ENGAGE_STEP
.have:
	; if dx=dy=0 we're idle; no move
	mov eax, esi
	or eax, edx
	jz .idle

	mov edi, ebx
	call entity_try_move
	test eax, eax 
	jz .blocked

	; moved: anim tick
	movzx eax, byte [r13 + ENT_TIMER_OFFSET]
	inc eax
	cmp eax, ANIM_PERIOD
	jl .save_timer
	xor eax, eax
	movzx ecx, byte [r13 + ENT_PHASE_OFFSET]
	xor ecx, 1
	mov byte [r13 + ENT_PHASE_OFFSET], cl
.save_timer:
	mov byte [r13 + ENT_TIMER_OFFSET], al
	jmp .out

.blocked:
	; nudge: try opening a door in front if it's closed
	; recompute the (dx, dy) from ai_dir; entity_try_move trashed it
	xor esi, esi
	xor edx, edx
	movzx eax, byte [r13 + ENT_AI_DIR_OFFSET]
	cmp eax, AI_DIR_UP
	jne .ba_not_up
	mov edx, -ENGAGE_STEP
	jmp .ba_have
.ba_not_up:
	cmp eax, AI_DIR_DOWN
	jne .ba_not_down
	mov edx, ENGAGE_STEP
	jmp .ba_have
.ba_not_down:
	cmp eax, AI_DIR_LEFT
	jne .ba_not_left
	mov esi, -ENGAGE_STEP
	jmp .ba_have
.ba_not_left:
	cmp eax, AI_DIR_RIGHT
	jne .ba_have
	mov esi, ENGAGE_STEP
.ba_have:
	mov edi, ebx
	call entity_try_open_door_in_dir
	test eax, eax
	jnz .out_moved	; door swung - try moving next tick,
					; counts as progress (no stuck)

; --- perpendicular slide: cardinal step blocked, try sidestep ---
	; trying something, not sure it works well
	movzx eax, byte [r13 + ENT_AI_DIR_OFFSET]
	cmp eax, AI_DIR_UP
	je .perp_xaxis
	cmp eax, AI_DIR_DOWN
	je .perp_xaxis
	; left/right blocked -> try y axis
	mov esi, 0
	mov edx, -ENGAGE_STEP			; up
	mov edi, ebx
	call entity_try_move
	test eax, eax
	jnz .out
	mov esi, 0
	mov edx, ENGAGE_STEP			; down
	mov edi, ebx
	call entity_try_move
	jmp .out
.perp_xaxis:
	; up/down blocked -> try x axis
	mov esi, -ENGAGE_STEP			; left
	mov edx, 0
	mov edi, ebx
	call entity_try_move
	test eax, eax
	jnz .out
	mov esi, ENGAGE_STEP			; right
	mov edx, 0
	mov edi, ebx
	call entity_try_move
	jmp .out

.idle:
	mov byte [r13 + ENT_TIMER_OFFSET], 0
	mov byte [r13 + ENT_PHASE_OFFSET], 0
.out:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; ai_attack_tick: in FIGHTING mode, drain attack_ticks and deal
; damage to target on each melee attack.  kills target if hp drops
;----------------------------------------------------------------
; in:	edi = self idx
;================================================================
ai_attack_tick:
	push rbx
	push r12
	push r13
	mov ebx, edi
	call entity_ptr
	mov r12, rax	; self ptr

	; tick the attack cooldown
	movzx eax, byte [r12 + ENT_ATTACK_TICKS_OFFSET]
	test eax, eax
	jz .meleeattack
	dec eax
	mov byte [r12 + ENT_ATTACK_TICKS_OFFSET], al
	jmp .out

.meleeattack:
	; reload cooldown
	mov byte [r12 + ENT_ATTACK_TICKS_OFFSET], ATTACK_PERIOD

	; target?
	movzx eax, byte [r12 + ENT_AI_TARGET_OFFSET]
	cmp eax, AI_TARGET_NONE
	je .out
	mov edi, eax
	call entity_ptr
	mov r13, rax

	; target alive?
	movzx ecx, byte [r13 + ENT_FLAGS_OFFSET]
	test ecx, ENT_FLAG_ALIVE
	jz .out

	; in range? (chebyshev distance in px <= FIGHT_RANGE_PX))
	mov eax, [r13 + ENT_X_OFFSET]
	sub eax, [r12 + ENT_X_OFFSET]
	test eax, eax
	jns .att_dx_pos
	neg eax
.att_dx_pos:
	mov ecx, [r13 + ENT_Y_OFFSET]
	sub ecx, [r12 + ENT_Y_OFFSET]
	test ecx, ecx
	jns .att_dy_pos
	neg ecx
.att_dy_pos:
	cmp eax, ecx
	jge .att_have
	mov eax, ecx
.att_have:
	cmp eax, FIGHT_RANGE_PX
	jg .out	; nope, out of range, skip meleeattack

	; deal damage
	movzx eax, byte [r13 + ENT_HP_OFFSET]
	sub eax, ENGAGE_DAMAGE
	jg .alive_after
	mov byte [r13 + ENT_HP_OFFSET], 0
	movzx edi, byte [r12 + ENT_AI_TARGET_OFFSET]
	call entity_kill
	; clear our target
	mov byte [r12 + ENT_AI_TARGET_OFFSET], AI_TARGET_NONE
	; drop to wander
	mov byte [r12 + ENT_AI_MODE_OFFSET], AI_MODE_WANDER
	mov byte [r12 + ENT_DECISION_TICKS_OFFSET], 0
	jmp .out
.alive_after:
	mov byte [r13 + ENT_HP_OFFSET], al

.out:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; ai_tick: per-frame entry for one NPC
;----------------------------------------------------------------
; drives a small state machine:
;	- decision_ticks > 0?  decrement and continue micro behaviour
;	- else: ai_decide picks a new mode
;
; the per-mode micro behaviour is dispatched at the end
;----------------------------------------------------------------
; in:	edi = entity index
;================================================================
ai_tick:
	push rbx
	push r12
	; 2 pushes (16) + ret (8) = misaligned; pad with sub 8
	sub rsp, 8

	mov ebx, edi
	call entity_ptr
	mov r12, rax

	; --- macro tier: re-decide if countdown elapsed ---
	movzx eax, byte [r12 + ENT_DECISION_TICKS_OFFSET]
	test eax, eax
	jnz .tick_dec
	mov edi, ebx
	call ai_decide
	jmp .post_decide
.tick_dec:
	dec eax
	mov byte [r12 + ENT_DECISION_TICKS_OFFSET], al

.post_decide:
	; --- target sanity: if we have a target that died, clear it
	; and downgrade to wander so we don't keep chasing a corpse
	movzx eax, byte [r12 + ENT_AI_TARGET_OFFSET]
	cmp eax, AI_TARGET_NONE
	je .no_target_check
	mov edi, eax
	call entity_ptr
	movzx ecx, byte [rax + ENT_FLAGS_OFFSET]
	test ecx, ENT_FLAG_ALIVE
	jnz .no_target_check
	; dead - clear and downgrade
	mov byte [r12 + ENT_AI_TARGET_OFFSET], AI_TARGET_NONE
	mov byte [r12 + ENT_AI_MODE_OFFSET], AI_MODE_WANDER
.no_target_check:

	; --- micro tier: dispatch by mode ---
	movzx eax, byte [r12 + ENT_AI_MODE_OFFSET]
	cmp eax, AI_MODE_WANDER
	je .m_wander
	cmp eax, AI_MODE_ENGAGING
	je .m_engage
	cmp eax, AI_MODE_FIGHTING
	je .m_fight
	cmp eax, AI_MODE_FLEEING
	je .m_flee
	; IDLE: do nothing!
	jmp .out

.m_wander:
	mov edi, ebx
	call entity_wander_tick
	jmp .out

.m_engage:
	; refresh step direction toward target each frame so movement
	; tracks a moving enemy.  if no target, we shouldn't be here! -
	; ai_decide cleared the target -> mode dropped to wander already
	movzx esi, byte [r12 + ENT_AI_TARGET_OFFSET]
	cmp esi, AI_TARGET_NONE
	je .out
	mov edi, ebx
	call ai_step_toward
	mov edi, ebx
	call ai_move_in_dir
	jmp .out

.m_fight:
	; while in fight range, the attack_tick swings.  if the target
	; slipped out of range, fall back to ENGAGING immediately so we
	; chase rather than attack nothing for some frames
	movzx esi, byte [r12 + ENT_AI_TARGET_OFFSET]
	cmp esi, AI_TARGET_NONE
	je .out
	; distance check
	mov edi, esi
	call entity_ptr
	; eax = target ptr
	mov ecx, [rax + ENT_X_OFFSET]
	sub ecx, [r12 + ENT_X_OFFSET]
	test ecx, ecx
	jns .mf_dx_pos
	neg ecx
.mf_dx_pos:
	mov edx, [rax + ENT_Y_OFFSET]
	sub edx, [r12 + ENT_Y_OFFSET]
	test edx, edx
	jns .mf_dy_pos
	neg edx
.mf_dy_pos:
	cmp ecx, edx
	jge .mf_have
	mov ecx, edx
.mf_have:
	cmp ecx, FIGHT_RANGE_PX
	jle .do_attack
	; out of range - go chase
	mov byte [r12 + ENT_AI_MODE_OFFSET], AI_MODE_ENGAGING
	mov edi, ebx
	call ai_step_toward
	mov edi, ebx
	call ai_move_in_dir
	jmp .out
.do_attack:
	mov edi, ebx
	call ai_attack_tick
	jmp .out

.m_flee:
	movzx esi, byte [r12 + ENT_AI_TARGET_OFFSET]
	cmp esi, AI_TARGET_NONE
	je .out
	mov edi, ebx
	call ai_step_away
	mov edi, ebx
	call ai_move_in_dir

.out:
	add rsp, 8
	pop r12
	pop rbx
	ret

%endif
