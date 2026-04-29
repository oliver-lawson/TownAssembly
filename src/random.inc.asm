; prng

%ifndef RANDOM_INC
%define RANDOM_INC

section .data
	; first seed for our rando mstate
	; can be any non-zero 64bit value, so not in .bss
	rng_state dq 0xfdcc567cc32193de

section .text

; rand_u64 - advance the rng state and return some
; 			 random u64 in rax.  basic xorshift
; clobbers : rac, rcx
; preserves: evrything else
; C equivalent:
; state ^= state << 13;
; state ^= state >> 7;
; state ^= state << 17;
rand_u64:
    mov rax, [rng_state]
    mov rcx, rax	; state2 = state
    shl rcx, 13		; state2 << 13
    xor rax, rcx	; state ^= state2
    mov rcx, rax	; state2 = state
    shr rcx, 7		; state2 >> 7
    xor rax, rcx	; state ^= state2
    mov rcx, rax	; state2 = state
    shl rcx, 17		; state2 << 17
    xor rax, rcx	; state ^= state2
    mov [rng_state], rax
    ret
%endif