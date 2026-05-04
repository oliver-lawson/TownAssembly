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

; facing direction values
%define FACE_DOWN   0
%define FACE_UP     1
%define FACE_LEFT   2
%define FACE_RIGHT  3

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
	mov byte [rax + ENT_HP_OFFSET], 10 ;default,callers can overwrite
	mov dword [rax + 16], 0			   ; ai_state TMP
	mov dword [rax + 20], 0			   ; ai_data  TMP

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

%endif
