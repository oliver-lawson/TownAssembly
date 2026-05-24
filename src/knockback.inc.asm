; knockback.inc.asm - melee impact pushback for entities + player
;----------------------------------------------------------------
; when an attacker damages a target, give them a kickback vel
; (kb_vx, kb_vy in px/tick) and a tick countdown.  each
; frame, before the target's normal AI runs, that velocity is
; applied via entity_apply_push so it slides backwards along
; walkable tiles for a few frames.  blocked axes just slide along
; the wall like in collision push
;
; for player, the same side-table slot (index 0) is read by
; player_knockback_tick and drained into player_x/player_y so
; getting hit shoves us back too
; - side table:
;	entity_kb_vx	i8	px/tick along x, signed
;	entity_kb_vy	i8	px/tick along y, signed
;	entity_kb_ticks	u8	frames remaining, 0 = idle
;----------------------------------------------------------------

%ifndef KNOCKBACK_INC
%define KNOCKBACK_INC

; hit slide duration
%define KB_TICKS_INIT		4
; per-frame px push along each axis during slide
%define KB_PUSH_PER_TICK	1

section .bss
	alignb 1
	entity_kb_vx		resb ENT_MAX
	entity_kb_vy		resb ENT_MAX
	entity_kb_ticks		resb ENT_MAX

section .text

;================================================================
; knockback_clear_all: wipe our side tables back to zero
; called from entity_clear_all so a world regen forgets everything
;================================================================
knockback_clear_all:
	push rdi
	push rcx
	push rax
	lea rdi, [entity_kb_vx]
	mov ecx, ENT_MAX * 3 ; vx, vy, ticks are contiguous
	xor eax, eax
	rep stosb
	pop rax
	pop rcx
	pop rdi
	ret

;================================================================
; knockback_apply: set knockback on target #edi away from (esi,edx)
;----------------------------------------------------------------
; computes cardinal sign of (target - attacker) along each
; axis, scales by KB_PUSH_PER_TICK and stashes into our side
; tables.  if both signs are zero, nudges +x to unstick
;
; not tracking any attacker entity id - just the source pixel
; coords - so usable for future explosions etc
;----------------------------------------------------------------
; in:	edi = target entity index
;		esi = attacker x (pixel)
;		edx = attacker y (pixel)
;================================================================
knockback_apply:
	push rbx
	push r12
	push r13
	mov ebx, edi			; target idx
	mov r12d, esi			; ax
	mov r13d, edx			; ay

	; load target ptr -> rax
	mov edi, ebx
	call entity_ptr

	; dx = tx - ax, sign tells us push direction
	mov ecx, [rax + ENT_X_OFFSET]
	sub ecx, r12d
	mov edx, [rax + ENT_Y_OFFSET]
	sub edx, r13d

	; vx = sign(dx) * KB_PUSH_PER_TICK
	xor r8d, r8d			; r8 = vx
	test ecx, ecx
	jz .vx_done
	jns .vx_pos
	mov r8d, -KB_PUSH_PER_TICK
	jmp .vx_done
.vx_pos:
	mov r8d, KB_PUSH_PER_TICK
.vx_done:

	; vy = sign(dy) * KB_PUSH_PER_TICK
	xor r9d, r9d			; r9 = vy
	test edx, edx
	jz .vy_done
	jns .vy_pos
	mov r9d, -KB_PUSH_PER_TICK
	jmp .vy_done
.vy_pos:
	mov r9d, KB_PUSH_PER_TICK
.vy_done:

	; both signs zero? default to +x so it doesn't lock up
	mov eax, r8d
	or eax, r9d
	jnz .have_v
	mov r8d, KB_PUSH_PER_TICK
.have_v:

	; stash into side tables
	lea rcx, [entity_kb_vx]
	mov [rcx + rbx], r8b
	lea rcx, [entity_kb_vy]
	mov [rcx + rbx], r9b
	lea rcx, [entity_kb_ticks]
	mov byte [rcx + rbx], KB_TICKS_INIT

	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; knockback_tick_entity: drain one frame of knockback for entity #edi
;----------------------------------------------------------------
; if kb_ticks > 0, applies (vx, vy) via entity_apply_push and
; decrements ticks.  returns eax = 1 if a push was applied this
; frame, 0 otherwise
;----------------------------------------------------------------
; in:	edi = entity index
; out:	eax = 1 if knockback was active, 0 otherwise
;================================================================
knockback_tick_entity:
	push rbx
	push r12
	push r13
	sub rsp, 8			; 3 pushes + ret + 8 = 32 -> aligned
	mov ebx, edi		; idx

	; ticks>0?
	lea rcx, [entity_kb_ticks]
	movzx eax, byte [rcx + rbx]
	test eax, eax
	jz .idle

	; load vx, vy as signed bytes -> sign-extend to int32
	lea rcx, [entity_kb_vx] 
	movsx r12d, byte [rcx + rbx]
	lea rcx, [entity_kb_vy]
	movsx r13d, byte [rcx + rbx]

	; entity_apply_push(ent_ptr, dx, dy)
	mov edi, ebx
	call entity_ptr		; rax = ent ptr
	mov rdi, rax
	mov esi, r12d
	mov edx, r13d
	call entity_apply_push

	; dec ticks
	lea rcx, [entity_kb_ticks]
	movzx eax, byte [rcx + rbx]
	dec eax
	mov [rcx + rbx], al

	mov eax, 1
	jmp .out
.idle:
	xor eax, eax
.out:
	add rsp, 8
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; player_knockback_tick: drain side-table[0] into player_x/y
;----------------------------------------------------------------
; same shape as knockback_tick_entity, but writes the player's
; canonical position fields directly + tile-checks each axis.
; called once per frame from main, after sync_entity_to_player
; (so any hit landed during entity_tick_all is applied immediately)
;
; entity[0]'s position will be resynced by sync_player_to_entity
; on the next frame, so we don't need to mirror it back here
;================================================================
player_knockback_tick:
	push rbx
	push r12
	sub rsp, 8		; 2 pushes + ret + 8 = 24+8 -> aligned for calls
	; check ticks
	movzx eax, byte [entity_kb_ticks + 0]
	test eax, eax
	jz .out

	; load vx, vy as signed
	movsx ebx, byte [entity_kb_vx + 0]
	movsx r12d, byte [entity_kb_vy + 0]

	; --- try x? ---
	test ebx, ebx
	jz .skip_x
	mov edi, [player_x]
	add edi, ebx
	mov esi, [player_y]
	call tile_speed_at_pixel
	test eax, eax
	jz .skip_x
	add [player_x], ebx
.skip_x:

	; --- try y? ---
	test r12d, r12d
	jz .skip_y
	mov edi, [player_x]	; possibly already updated
	mov esi, [player_y]
	add esi, r12d
	call tile_speed_at_pixel
	test eax, eax
	jz .skip_y
	add [player_y], r12d
.skip_y:

	; dec ticks
	movzx eax, byte [entity_kb_ticks + 0]
	dec eax
	mov [entity_kb_ticks + 0], al
.out:
	add rsp, 8
	pop r12
	pop rbx
	ret

%endif
