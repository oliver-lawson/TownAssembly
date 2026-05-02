; prng

%ifndef RANDOM_INC
%define RANDOM_INC

extern time ; for time-driven seeds

section .bss
	alignb 8
	rng_state resq 1

section .text
;================================================================
; rng_seed: set rng state to specified value, eg time
; C equiv: rng_state = seed ? seed : 1;
; avoids 0 for LCG/hashes getting stuck at 0
;----------------------------------------------------------------
; in: rdi = seed #
;================================================================
rng_seed:
	mov [rng_state], rdi
	test rdi, rdi ; simple 0 check, force 1. not pretty
	jnz .ok
	mov qword [rng_state], 1
.ok:
	ret

;================================================================
; rng_seed_from_time: does what it says on the tin
;
; unix timestamp-derived here, for per-launch randomisation etc
; calls libc time(NULL) which returns s since epoch
;================================================================
rng_seed_from_time:
	xor edi, edi	; don't need out ptr so NULLing
	call time
	mov rdi, rax
	jmp rng_seed 	; put into rng_seed(rdi)


; rng_next - advance the rng state and return some
; 			 random u64 in rax.  basic xorshift
; clobbers : rac, rcx
; preserves: evrything else
; C equivalent:
; state ^= state << 13;
; state ^= state >> 7;
; state ^= state << 17;
rng_next:
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