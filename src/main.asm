
global main
default rel

%include "sdl.inc.asm"
%include "random.inc.asm"

%define WINDOW_WIDTH  640
%define WINDOW_HEIGHT 480
%define TILE_SIZE	  32
%define TILES_X		  (WINDOW_WIDTH  / TILE_SIZE)
%define TILES_Y		  (WINDOW_HEIGHT / TILE_SIZE)
%define FB_BYTES	  (WINDOW_WIDTH * WINDOW_HEIGHT * 4)
; 4 bytes per pixel: A,R,G<B in SDL_PIXELFORMAT_ARGB8888
%define FB_PITCH	  (WINDOW_WIDTH * 4) ; bytes per row

section .data
	window_title        db "Town Assembly", 0

	; == SDL error messages ==
	; 10 = \n, 0 = C-style string terminator:
	err_init_msg        db "SDL_Init failed", 10, 0 
	err_window_msg      db "SDL_CreateWindow failed", 10, 0
	err_renderer_msg    db "SDL_CreateRenderer failed", 10, 0
	err_texture_msg     db "SDL_CreateTexture failed", 10, 0

section .bss ; uninitialised buffers
	alignb 8
	sdl_window		resq 1
	sdl_renderer 	resq 1
	sdl_event		resb SDL_EVENT_SIZE
	framebuffer		resb FB_BYTES
	sdl_texture		resq 1

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

	; create gpu streaming texture we'll upload to each frame
	mov rdi, [sdl_renderer]
	mov esi, SDL_PIXELFORMAT_ARGB8888
	; SDL_TEXTUREACCESS_STREAMING for telling SDL we're
	; uploading new pixels to this texture often, not STATIC
	; or TARGET.  seems best approach
	mov edx, SDL_TEXTUREACCESS_STREAMING
    mov ecx, WINDOW_WIDTH
    mov r8d, WINDOW_HEIGHT
    call SDL_CreateTexture
    test rax, rax
    jz .fail_texture
    mov [sdl_texture], rax

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
	mov rdi, [sdl_texture]
	call SDL_DestroyTexture
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
	;call SDL_Quit ; was never created
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
.fail_texture:
	lea rdi, [err_texture_msg]
	call print_error
	mov rdi, [sdl_renderer]
	call SDL_DestroyRenderer
	mov rdi, [sdl_window]
	call SDL_DestroyWindow
	call SDL_Quit
	mov eax, 1
	leave
	ret

draw_tiles:
	; draw some coloured gradient tiles to test the framebuffer
    ; push callee saveds used:
    push rbx ;colour
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

    ; ==============================================
    ; compute colour for this tile, store in ebx
    ; 0xFF000000 | (tx*12)<<16 | (ty*16)<<8 | 	0
    ;    	A			R			G			B
    ; ==============================================
    ;
    ; alpha
    mov ebx, 0xFF000000
    ; red: (tx * 12) << 16
    imul eax, r12d, 12
    shl eax, 16
    or ebx, eax

    ; green: (ty * 16) << 8  ==  ty << 12
    mov eax, r13d
    ;imul eax, 16
    ;shl eax, 8
    shl eax, 12
    or ebx, eax

    ; blue: add some random noise per frame
    call rand_u64
    mov eax, [rng_state]
    shl eax, 16
    or ebx, eax

    ;     for py in 0..TILE_SIZE:
    xor r15, r15 ; py=0
.py_loop:
	cmp r15, TILE_SIZE
	jge .py_done

	xor r14, r14 ; px=0
.px_loop:
	cmp r14, TILE_SIZE
	jge .px_done

	; == pixel write ==
    ;         for px in 0..TILE_SIZE:
    ;             screen_x = tx * TILE_SIZE + px
    mov rax, r12 		; rax=tx
    imul rax, TILE_SIZE ; rax*=TILE_SIZE
    add rax, r14 		; rax+=px
    ;             screen_y = ty * TILE_SIZE + py
    mov rcx, r13 		; rcx=ty
    imul rcx, TILE_SIZE ; rcx*=TILE_SIZE
    add rcx, r15		; rcx+=py
    ;             offset   = (screen_y * WINDOW_WIDTH + screen_x) * 4
    mov rdx, rcx		; rdx=screen_y
    imul rdx, WINDOW_WIDTH ; rdx*=WINDOW_WIDTH
    add rdx, rax		; rdx+=screen_x
    shl rdx, 2			; rdx*=4
    ;             [framebuffer + offset] = colour     (32-bit write)
    ; write 32-bit pixel to framebuffer
    mov dword [framebuffer + rdx], ebx

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
