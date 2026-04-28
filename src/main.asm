
global main
default rel

%include "sdl.inc.asm"

%define WINDOW_WIDTH  640
%define WINDOW_HEIGHT 480

section .data
	window_title        db "Town Assembly", 0

	err_init_msg        db "SDL_Init failed", 10, 0
	err_window_msg      db "SDL_CreateWindow failed", 10, 0
	err_renderer_msg    db "SDL_CreateRenderer failed", 10, 0

section .bss ; uninitialised buffers
	alignb 8
	sdl_window		resq 1
	sdl_renderer 	resq 1
	sdl_event		resb SDL_EVENT_SIZE

section .text ; begin!

main: ; stack alignment:
	push rbp	 ; align stack to 16, "frame pointer" convention
	mov rbp, rsp ; tell debugger where the frame is
	; now do stuff

	; setup SDL
	mov edi, SDL_INIT_VIDEO
	call SDL_Init
	test eax, eax
	jnz .fail_init

	lea rdi, [window_title]
	mov esi, SDL_WINDOWPOS_CENTERED
	mov edx, SDL_WINDOWPOS_CENTERED
	mov ecx, WINDOW_WIDTH
	mov r8d, WINDOW_HEIGHT
	mov r9d, SDL_WINDOW_SHOWN
	call SDL_CreateWindow
	test rax, rax
	jz .fail_window
	mov [sdl_window], rax ; store new pointer to window

	mov rdi, [sdl_window]
	mov esi, -1
	call SDL_CreateRenderer
	test rax, rax
	jz .fail_renderer
	mov [sdl_renderer], rax ; store pointer to renderer

.main_loop:
	; === event polling ===
.poll_loop:
	lea rdi, [sdl_event]
	call SDL_PollEvent
	test eax, eax
	jz .poll_done	; queue empty

	mov eax, [sdl_event + SDL_EVENT_TYPE_OFF]
	cmp eax, SDL_QUIT_EVENT
	je .cleanup
	cmp eax, SDL_KEYDOWN_EVENT
	jne .poll_loop	; not keydown, get next

	mov eax, [sdl_event + SDL_EVENT_SCANCODE_OFF]
	cmp eax, SCANCODE_ESCAPE
	je .cleanup
	jmp .poll_loop

.poll_done:
	; === render ===
	mov rdi, [sdl_renderer]
	call SDL_RenderClear

	mov rdi, [sdl_renderer]
	call SDL_RenderPresent

	mov edi, 16 ; delay ms, even if we have vsync enabled
	call SDL_Delay

	jmp .main_loop

.cleanup:
	; === end main ===
	mov rdi, [sdl_renderer]
	call SDL_DestroyRenderer
	mov rdi, [sdl_window]
	call SDL_DestroyWindow
	call SDL_Quit
	leave 	; mov rsp,rbp and pop rbp to restore stack
	ret		; returns to crt1.o which calls exit()

.fail_init:
	lea rdi, [err_init_msg]
	call print_error
	call SDL_Quit
	mov eax, 1 ; exit code
	leave
	ret
.fail_window:
	lea rdi, [err_window_msg]
	call print_error
	call SDL_Quit
	mov eax, 1
	leave
	ret
.fail_renderer:
	lea rdi, [err_renderer_msg]
	call print_error
	mov rdi, [sdl_window]
	call SDL_DestroyWindow
	call SDL_Quit
	mov eax, 1
	leave
	ret

print_error:
	push rbp
	mov rbp, rsp
	mov rsi, rdi
	xor rcx, rcx ; rsi, rcx are caller saved, can clobber
.strlen:
	cmp byte [rsi + rcx], 0
	je .got_len
	inc rcx
	jmp .strlen
.got_len:
	mov rax, 1
	mov rdx, rcx
	mov rdi, 2
	syscall
	pop rbp
	ret
