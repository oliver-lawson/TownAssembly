; dmgfloat.inc.asm - small red numbers above entities on hit
;----------------------------------------------------------------
; combat feedback.  when ai_attack_tick lands a hit, it calls
; spawn_dmgfloat(x, y, dmg) and a small red number floats up
; above the victim for some frames before fading
;
; multi-slot (unlike the player's +1 wood floattext which is just
; one slot).  oldest will disappear if too many
%ifndef DMGFLOAT_INC
%define DMGFLOAT_INC

%define DMGF_MAX			16
%define DMGF_LIFETIME		45
%define DMGF_LIFT_PERIOD	4 ; lift 1px every N ticks
%define DMGF_COLOUR			0xFFFF4040

section .bss
	; slots[].active = 1 if live
	alignb 2
	dmgf_active		resb DMGF_MAX
	alignb 2
	dmgf_ttl		resw DMGF_MAX
	alignb 4
	dmgf_x			resd DMGF_MAX
	dmgf_y			resd DMGF_MAX
	; value to display - bytes for now, as damage is small atm
	alignb 1
	dmgf_value		resb DMGF_MAX
	alignb 4
	dmgf_head		resd 1

section .text

;================================================================
; spawn_dmgfloat: drop a damage number above (x, y)
;----------------------------------------------------------------
; in:	edi = pixel x, esi = pixel y, edx = damage value (0..255)
;================================================================
global spawn_dmgfloat
spawn_dmgfloat: 
	mov eax, [dmgf_head]		; index of slot to claim

	; mark active
	lea rcx, [dmgf_active]
	mov byte [rcx + rax], 1

	; ttl
	lea rcx, [dmgf_ttl]
	mov word [rcx + rax*2], DMGF_LIFETIME

	; x
	lea rcx, [dmgf_x]
	mov [rcx + rax*4], edi

	; sit above
	sub esi, 12
	lea rcx, [dmgf_y]
	mov [rcx + rax*4], esi

	; value
	lea rcx, [dmgf_value]
	mov [rcx + rax], dl

	; advance head modulo DMGF_MAX
	inc eax
	cmp eax, DMGF_MAX
	jl .no_wrap
	xor eax, eax
.no_wrap:
	mov [dmgf_head], eax
	ret

;================================================================
; dmgfloat_tick: per-frame: ttl-- and lift every nth tick
;----------------------------------------------------------------
; one pass over the slot array
;================================================================
global dmgfloat_tick
dmgfloat_tick:
	push rbx
	xor ebx, ebx ; slot index
.loop:
	cmp ebx, DMGF_MAX
	jge .done
	lea rcx, [dmgf_active]
	cmp byte [rcx + rbx], 0
	je .next

	lea rcx, [dmgf_ttl]
	movzx eax, word [rcx + rbx*2]
	test eax, eax
	jz .expire
	dec eax
	mov word [rcx + rbx*2], ax

	; lift y? 1px every DMGF_LIFT_PERIOD ticks - test(LIFETIME - ttl)
	; % period == 0
	xor edx, edx
	mov ecx, DMGF_LIFT_PERIOD
	div ecx
	test edx, edx
	jnz .next
	lea rcx, [dmgf_y]
	dec dword [rcx + rbx*4]
	jmp .next
.expire:
	lea rcx, [dmgf_active]
	mov byte [rcx + rbx], 0
.next:
	inc ebx
	jmp .loop
.done:
	pop rbx
	ret

;================================================================
; dmgfloat_draw_all: render every active slot
;----------------------------------------------------------------
; each slot draws a single-byte int.  uses debug_print_int with a
; ttl-modulated colour so the number fades to dark as it expires.
; only colour's r is faded; g and b already low, simple!
;----------------------------------------------------------------
; stack: 3 callee saves + ret = 32, aligned
;================================================================
global dmgfloat_draw_all
dmgfloat_draw_all:
	push rbx
	push r12
	push r13
	xor ebx, ebx
.loop:
	cmp ebx, DMGF_MAX
	jge .done
	lea rcx, [dmgf_active]
	cmp byte [rcx + rbx], 0
	je .next

	; fade: intensity = ttl * 255 / LIFETIME, 0..255
	lea rcx, [dmgf_ttl]
	movzx eax, word [rcx + rbx*2]
	imul eax, 255
	mov ecx, DMGF_LIFETIME
	xor edx, edx
	div ecx
	mov r12d, eax ; intensity 0..255
	; build the red colour
	mov eax, (DMGF_COLOUR >> 16) & 0xFF
	imul eax, r12d
	mov ecx, 255
	xor edx, edx
	div ecx
	shl eax, 16
	or eax, DMGF_COLOUR & 0xFF00FFFF ; reattach A, G, B from base
	mov r13d, eax ; final ARGB

	; screen pos
	lea rcx, [dmgf_x]
	mov edi, [rcx + rbx*4]
	sub edi, [camera_x]
	lea rcx, [dmgf_y]
	mov esi, [rcx + rbx*4]
	sub esi, [camera_y]
	; nudge
	sub edi, 4
	lea rcx, [dmgf_value]
	movzx ecx, byte [rcx + rbx]
	mov edx, r13d
	call debug_print_int

.next:
	inc ebx
	jmp .loop
.done:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; dmgfloat_clear: reset all slots (called on world restart)
;================================================================
global dmgfloat_clear
dmgfloat_clear:
	lea rdi, [dmgf_active]
	mov ecx, DMGF_MAX
	xor eax, eax
	rep stosb
	mov dword [dmgf_head], 0
	ret

%endif
