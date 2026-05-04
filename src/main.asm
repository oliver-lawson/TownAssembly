global main
default rel

%include "sdl.inc.asm"
%include "random.inc.asm"
%include "framebuffer.inc.asm"
%include "texture.inc.asm"
%include "blit.inc.asm"
%include "tilemap.inc.asm"
%include "worldgen.inc.asm"
%include "debug.inc.asm"

section .data
	window_title		db "Town Assembly", 0
	tile_ppm_file		db "res/tiles.ppm", 0
	scale_quality_hint  db "SDL_RENDER_SCALE_QUALITY", 0
	scale_quality_value db "0", 0 ; "0" = nearest-neighbour

	%define TILES_X		  (WINDOW_W  / TILE_SIZE)
	%define TILES_Y		  (WINDOW_H / TILE_SIZE)
	; == SDL error messages ==
	; 10 = \n, 0 = C-style string terminator:
	err_init_msg		db "SDL_Init failed", 10, 0 
	err_window_msg		db "SDL_CreateWindow failed", 10, 0
	err_renderer_msg	db "SDL_CreateRenderer failed", 10, 0
	err_texture_msg		db "SDL_CreateTexture failed", 10, 0
	err_ppm_msg			db "load_ppm failed", 10, 0

	; HUD text
	hud_label_fps		db "fps", 0
	hud_label_iters		db "iters", 0
	hud_label_seed		db "seed", 0
	hud_help			db "F3 hud  F5 restart  ESC quit", 0

	; log messages
	log_msg_started		db 0x1, " world generated! ", 0x3, 0
	log_msg_restart		db "regenerated world", 0
	log_msg_itered		db "iterated cellular automata", 0
	log_msg_hud_toggles	db "hud toggled", 0

section .bss ; uninitialised buffers
	alignb 8
	sdl_window			resq 1
	sdl_renderer 		resq 1
	sdl_texture			resq 1
	current_scale		resq 1

	; input state
		; - sustained -
	key_quit			resb 1
		; - one shots -
	key_toggle_pressed	resb 1
	key_iterateworld_pressed	resb 1
	key_restart_pressed	resb 1

	; fps tracking
	alignb 4
	frame_count			resd 1
	last_fps_ticks		resd 1	; SDL_GetTicks value @ last fps sample
	last_fps_frame		resd 1	; frame_count @ last fps sample
	current_fps			resd 1	; final computed fps for display
	current_seed		resd 1	; stash for HUD

	alignb 8
	event_buf			resb SDL_EVENT_SIZE
section .text ; begin!

main: ; stack alignment:
	push rbp	 ; align stack to 16, "frame pointer" convention
	mov rbp, rsp ; tell debugger where the frame is

	; load tile atlas - tiles.ppm
	; must be 16^2px tiles, and match tile types in tilemap.inc.asm
	lea rdi, [tile_ppm_file]
	call load_ppm
	test eax, eax
	jnz .fail_ppm

	; seed rng and generate world
	;call rng_seed_from_time
	mov [rng_state], byte 1
	mov eax, [rng_state]
	mov [current_seed], eax ; store current seed for HUD
	call generate_world
	;call init_tilemap_test

	lea rdi, [log_msg_started]
	call debug_log

	; set video scale
	mov dword [current_scale], 2

	; SDL hints - must be done before SDL_INIT_VIDEO
	lea rdi, [scale_quality_hint]
	lea rsi, [scale_quality_value]
	call SDL_SetHint

	; setup SDL
	mov edi, SDL_INIT_VIDEO
	call SDL_Init
	test eax, eax
	jnz .fail_init

	; window titl, pos, scale
	lea rdi, [window_title]
	mov esi, SDL_WINDOWPOS_CENTERED
	mov edx, SDL_WINDOWPOS_CENTERED
	mov ecx, WINDOW_W * 2 ; default scale
	mov r8d, WINDOW_H * 2
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

	; + tell SDL the renderer's logical size if WINDOW_W * WINDOW_H
	; this means RenderCopy with NULL dst rect will scale our texture
	; to fill the window, regardless of window size
	mov rdi, [sdl_renderer]
	mov esi, WINDOW_W
	mov edx, WINDOW_H
	call SDL_RenderSetLogicalSize

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

	; grab the starting tick count for FPS calc
	call SDL_GetTicks
	mov [last_fps_ticks], eax

	; --- main loop ---
.main_loop:
	call process_sdl_events

	cmp byte [key_quit], 0
	jne .cleanup

	; --- handle one shot keys ---

	; F4: iterate wordlgen CA
	cmp byte [key_iterateworld_pressed], 0
	je .no_iterateworld
	mov byte [key_iterateworld_pressed], 0
	; iterate world
	call iterate_world
	lea rdi, [log_msg_itered]
	call debug_log


.no_iterateworld:
	; F5: restart game
	cmp byte [key_restart_pressed], 0
	je .no_restart
	mov byte [key_restart_pressed], 0
	; restart pressed
	;call rng_seed_from_time
	call reset_world_iterations
	call rng_next
	mov eax, [rng_state]
	mov [current_seed], eax
	call generate_world
	lea rdi, [log_msg_restart]
	call debug_log

.no_restart:
	; F3: toggle HUD
	cmp byte [key_toggle_pressed], 0
	je .no_toggle
	mov byte [key_toggle_pressed], 0
	call debug_toggle
	lea rdi, [log_msg_hud_toggles]
	call debug_log

.no_toggle:
	; --- fps calculation ---
	; sampling every 500ms and scaling up
	;
	; C equiv:
	;	uint32_t now = SDL_GetTicks();
	;	uint32_t elapsed = now - last_fps_ticks;
	;	if (elapsed >= 500) {
	;		uint32_t frames = frame_count - last_fps_frame;
	;		current_fps = frames * 1000 / elapsed;
	;		last_fps_ticks = now;
	;		last_fps_frame = frame_count;
	;	}
	call SDL_GetTicks
	mov ecx, eax				; ecx = now
	mov r11d, ecx
	sub r11d, [last_fps_ticks]	; r11d = elapsed ms
	cmp r11d, 500
	jl .fps_done
	; enough time has passed - compute fps
	mov eax, [frame_count]
	sub eax, [last_fps_frame]	; eax = frames since last sample
	imul eax, 1000				; scale to per-second
	xor edx, edx
	div r11d					; eax = fps
	mov [current_fps], eax
	mov [last_fps_ticks], ecx	; reset sample window
	mov eax, [frame_count]
	mov [last_fps_frame], eax
.fps_done:

	; --- render ---
	call draw_tilemap 

	; ------ draw debug hud (if enabled) ------
	call is_debug_hud_enabled
	test eax, eax
	jz .skip_hud_draw

	;top row: fps counter
	mov edi, 4 ; x
	mov esi, 4 ; y
	mov edx, 0xFF004400 ; some green, would be cool to speed-tint
	lea rcx, [hud_label_fps]
	mov r8d, [current_fps]
	call debug_print_label_int
	; iterations
	add eax, 8 ; bit of a gap between labels
	mov edi, eax
	mov esi, 4
	mov edx, 0xFF0033AA
	lea rcx, [hud_label_iters]
	mov r8d, [ca_iterations_count]
	call debug_print_label_int
	; seed
	add eax, 8 ; bit of a gap between labels
	mov edi, eax
	mov esi, 4
	mov edx, 0xFF000000
	lea rcx, [hud_label_seed]
	mov r8d, [current_seed]
	call debug_print_label_int

	; second line: help text
	mov edi, 4
	mov esi, 14
	mov edx, 0xFF000000;
	lea rcx, [hud_help]
	call debug_print

	; log lines at the bottom
	call debug_render_log
	; -------- end hud (if enabled) -------
	.skip_hud_draw:

	inc dword [frame_count]

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

	;mov edi, 16 ; delay ms, even if we have vsync enabled
	;call SDL_Delay

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
	xor eax, eax ; 0
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

; -- process_sdl_events --
; drain SDL event quere & update key state
;
; one-shot (latched) key state:
;	key_toggle_pressed set to 1 on keydown, acted on by main loop
;   and then cleared.  so it's a "do once" latch
; sustained: eg key_quit, stays set once triggered  
process_sdl_events:
	push rbp
	mov rbp, rsp
.poll:
	lea rdi, [event_buf]
	call SDL_PollEvent
	test eax, eax
	jz .done				; queue empty

	mov eax, [event_buf + SDL_EVENT_TYPE_OFF]
	cmp eax, SDL_QUIT_EVENT
	je .got_quit
	cmp eax, SDL_KEYDOWN_EVENT
	je .got_keydown
	jmp .poll				; ignore other events

.got_quit:
	mov byte [key_quit], 1
	jmp .poll

.got_keydown:
	mov eax, [event_buf + SDL_EVENT_SCANCODE_OFF]
	cmp eax, SCANCODE_ESCAPE
	je .key_escape
	cmp eax, SCANCODE_F3
	je .key_f3
	cmp eax, SCANCODE_F4
	je .key_f4
	cmp eax, SCANCODE_F5
	je .key_f5
	jmp .poll

.key_escape:
	mov byte [key_quit], 1
	jmp .poll
.key_f3:
	mov byte [key_toggle_pressed], 1
	jmp .poll
.key_f4:
	mov byte [key_iterateworld_pressed], 1
	jmp .poll
.key_f5:
	mov byte [key_restart_pressed], 1
	jmp .poll

.done:
	pop rbp
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
