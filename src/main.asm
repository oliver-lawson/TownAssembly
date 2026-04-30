global main
default rel

%include "sdl.inc.asm"
%include "random.inc.asm"
%include "framebuffer.inc.asm"
%include "texture.inc.asm"


%define TILE_SIZE	  16
%define TILES_X		  (WINDOW_W  / TILE_SIZE)
%define TILES_Y		  (WINDOW_H / TILE_SIZE)


section .data
	window_title        db "Town Assembly", 0
	texture_file		db "res/test/test.ppm", 0

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

	; load test texture before any window loading
	lea rdi, [texture_file]
	call load_ppm
	test eax, eax
	jnz .fail_ppm

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
	; fill framebuffer with colourful tiles to test
	call draw_tiles

	; upload framebuffer to gpu texture
	; SDL_UpdateTexture(texture, NULL, pixels, pitch):
	mov rdi, [sdl_texture]
	xor rsi, rsi ; NULL - update whole texture, not a rect of it
	lea rdx, [framebuffer]
	mov ecx, FB_PITCH
	call SDL_UpdateTexture

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

draw_tiles:
	; draw some coloured ppm tiles to test .ppm read, random, framebuffer

    ; push callee saveds used:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    push rbx ;scratch
    push r12 ;tx
    push r13 ;ty
    push r14 ;px
    push r15 ;py
    
    ; for ty in 0..TILES_Y:
    xor r13, r13 ; ty=0
.ty_loop:
    cmp r13, TILES_Y
    jge .ty_done 

    ; for tx in 0..TILES_X:
    xor r12, r12 ; tx=0
.tx_loop:
	cmp r12, TILES_X
	jge .tx_done
	; call random tint for this tile, using top bytes of rng_state
	; as rgb tint factors in range 0..255 then scaled by
	; tint_channel/256 via a mul+shift
	call rng_next
	; brighten a bit to see our texture,
	; ORing in 0x60 to each channel byte seems to work
	or eax, 0x00606060
	mov [rbp-4], eax
	;     for py in 0..TILE_SIZE:
    xor r15, r15 ; py=0
.py_loop:
	cmp r15, TILE_SIZE
	jge .py_done

	xor r14, r14 ; px=0
.px_loop:
	cmp r14, TILE_SIZE
	jge .px_done

	; sample texture at this pixel's position within the til
	; u = px * 0x10000 / TILE_SIZE, v = py * 0x10000 / TILE_SIZE
	; since TILE_SIZE is 16, diving 0x10000 by 16 = 0x1000
	; so, u = px * 0x1000, v = py * 0x1000
	mov edi, r14d
	shl edi, 12			; u = px * 0x1000
	mov esi, r15d
	shl esi, 12			; v = py * 0x1000
	call sample_texture
	; eax now = ARGB texel from the texture

	; tint: multipying each channel by tint, then shifting
	; down by 8. doing r,g,b separately
	mov ebx, [rbp-4]	; ebx = tint colour

	;r
	mov ecx, eax
	shr ecx, 16
	and ecx, 0xFF		; ecx = tex red
	mov edx, ebx
	shr edx, 16
	and edx, 0xFF		; edx = tint red
	imul ecx, edx		; ecx = tex_r*tint_r
	shr ecx, 8			; scale back to 0..255

	;g
	mov edx, eax
	shr edx, 8
	and edx, 0xFF
	mov edi, ebx
	shr edi, 8
	and edi, 0xFF
	imul edx, edi
	shr edx, 8

	;b
	mov esi, eax
	and esi, 0xFF
	mov edi, ebx
	and edi, 0xFF
	imul esi, edi
	shr esi, 8

	; push back into ARGB
	mov eax, 0xFF000000
	shl ecx, 16
	or eax, ecx ;r
	shl edx, 8
	or eax, edx ;g
	or eax, esi ;b

	; write pixel to framebuffer
	;screen_x = tx * TILE_SIZE + px
	mov rcx, r12
	imul rcx, TILE_SIZE
	add rcx, r14
	; scren_y
	mov rdx, r13
	imul rdx, TILE_SIZE
	add rdx, r15
	; offset = (screen_y * WINDOW_W + screen_x) * 4
	imul rdx, WINDOW_W
	add rdx, rcx
	shl rdx, 2
	mov dword [framebuffer + rdx], eax

    inc r14 ; px++
    jmp .px_loop

.px_done:
	inc r15 ; py++
	jmp .py_loop

.py_done:
	inc r12 ; tx++
	jmp .tx_loop

.tx_done:
	inc r13 ; ty++
	jmp .ty_loop
    ;
    ; registers:
    ; callee-saved, pop & push:
    ; r12 = tx, r13 = ty, r14 = px, r15 = py
    ; caller-saved:
    ; rax = screen_x, rcx = screen_y, rdx = offset
    ; ebx = colour buffer


.ty_done: ;aka everything done, end the loop
	; pop callee-saveds:
	pop r15 ;py
	pop r14 ;px
	pop r13 ;ty
	pop r12 ;tx
	pop rbx ;colour
	leave ; undo the stack frame entered in top of draw_tiles
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
