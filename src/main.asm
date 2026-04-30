global main
default rel

%include "sdl.inc.asm"
%include "random.inc.asm"
%include "framebuffer.inc.asm"
%include "texture.inc.asm"
%include "blit.inc.asm"
%include "tilemap.inc.asm"

section .data
	window_title        db "Town Assembly", 0
	tile_ppm_file		db "res/tiles.ppm", 0

	%define TILES_X		  (WINDOW_W  / TILE_SIZE)
	%define TILES_Y		  (WINDOW_H / TILE_SIZE)
	; == SDL error messages ==
	; 10 = \n, 0 = C-style string terminator:
	err_init_msg        db "SDL_Init failed", 10, 0 
	err_window_msg      db "SDL_CreateWindow failed", 10, 0
	err_renderer_msg    db "SDL_CreateRenderer failed", 10, 0
	err_texture_msg     db "SDL_CreateTexture failed", 10, 0
	err_ppm_msg     	db "load_ppm failed", 10, 0

section .bss ; uninitialised buffers
	alignb 8
	sdl_window		resq 1
	sdl_renderer 	resq 1
	sdl_event		resb SDL_EVENT_SIZE
	sdl_texture		resq 1

section .text ; begin!

main: ; stack alignment:
	push rbp	 ; align stack to 16, "frame pointer" convention
	mov rbp, rsp ; tell debugger where the frame is

	; load tile atlas, tiles.ppm
	; must be 16^2px tiles, and mathc tile types in tilemap.inc.asm
	lea rdi, [tile_ppm_file]
	call load_ppm
	test eax, eax
	jnz .fail_ppm

	; TMP
	call init_tilemap_test

	; setup SDL
	mov edi, SDL_INIT_VIDEO
	call SDL_Init
	test eax, eax
	jnz .fail_init

	lea rdi, [window_title]
	mov esi, SDL_WINDOWPOS_CENTERED
	mov edx, SDL_WINDOWPOS_CENTERED
	mov ecx, WINDOW_W
	mov r8d, WINDOW_H
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

	; create gpu streaming texture we'll upload to each frame
	mov rdi, [sdl_renderer]
	mov esi, SDL_PIXELFORMAT_ARGB8888
	; SDL_TEXTUREACCESS_STREAMING for telling SDL we're
	; uploading new pixels to this texture often, not STATIC
	; or TARGET.  seems best approach
	mov edx, SDL_TEXTUREACCESS_STREAMING
    mov ecx, WINDOW_W
    mov r8d, WINDOW_H
    call SDL_CreateTexture
    test rax, rax
    jz .fail_texture
    mov [sdl_texture], rax

	call rng_seed ; seems as good a time as any

	; --- main loop ---
.main_loop:
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
	; --- render ---
	call draw_tilemap 

	; upload framebuffer to gpu texture
	mov rdi, [sdl_texture]
	xor rsi, rsi ; NULL - update whole texture, not a rect of it
	lea rdx, [framebuffer]
	mov ecx, FB_PITCH
	call SDL_UpdateTexture ; (texture, NULL, pixels, pitch)

	mov rdi, [sdl_renderer]
	call SDL_RenderClear

	; SDL_RenderCopy(renderer, texture, NULL, NULL):
	mov rdi, [sdl_renderer]
    mov rsi, [sdl_texture]
    xor rdx, rdx
    xor rcx, rcx
    call SDL_RenderCopy

	mov rdi, [sdl_renderer]
	call SDL_RenderPresent

	mov edi, 16 ; delay ms, even if we have vsync enabled
	call SDL_Delay

	jmp .main_loop

.cleanup:
	; === end main ===
	call free_texture
	mov rdi, [sdl_texture]
	call SDL_DestroyTexture
	mov rdi, [sdl_renderer]
	call SDL_DestroyRenderer
	mov rdi, [sdl_window]
	call SDL_DestroyWindow
	call SDL_Quit
	leave 	; mov rsp,rbp and pop rbp to restore stack
	ret		; returns to crt1.o which calls exit()

.fail_ppm:
	lea rdi, [err_ppm_msg]
	call print_error
	mov eax, 1
	leave
	ret
.fail_init:
	lea rdi, [err_init_msg]
	call print_error
	call free_texture
	mov eax, 1 ; exit code
	leave
	ret
.fail_window:
	lea rdi, [err_window_msg]
	call print_error
	call free_texture
	call SDL_Quit
	mov eax, 1
	leave
	ret
.fail_renderer:
	lea rdi, [err_renderer_msg]
	call print_error
	call free_texture
	mov rdi, [sdl_window]
	call SDL_DestroyWindow
	call SDL_Quit
	mov eax, 1
	leave
	ret
.fail_texture:
	lea rdi, [err_texture_msg]
	call print_error
	call free_texture
	mov rdi, [sdl_renderer]
	call SDL_DestroyRenderer
	mov rdi, [sdl_window]
	call SDL_DestroyWindow
	call SDL_Quit
	mov eax, 1
	leave
	ret

;================================================================
; print_error: writes a null-terminated string to stderr
;----------------------------------------------------------------
; in: rdi = string pointer
;================================================================
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
