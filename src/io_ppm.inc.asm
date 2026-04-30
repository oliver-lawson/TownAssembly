; io_ppm.inc.asm - load PPM (P6) files into shared texture buffer
;
; format spec:
; "P6"		- magic
; whitespace
; width		- ascii decimal
; whitespace
; height	- ascii decimal
; whitespace
; maxval	- ascii decimal. i'm just sticking to 255 for assets
; whitepace (ONE byte)
; <raw RGB bytes>
;
; 1. mmap the file
; 2. parse the header
; 3. convert the pixel data into a malloc'd ARGB buffer
; 4. munmap to remove mmap
; 5. ARGB buffer persists
;
; writes into tex_pixels, tex_width, tex_height
; which live in texture.inc.asm and includes this file

%ifndef IO_PPM_INC
%define IO_PPM_INC

extern mmap
extern munmap
extern malloc
extern free
extern open
extern close
extern fstat

%define O_RDONLY    0
%define PROT_READ   1
%define MAP_PRIVATE 2

; stat's response struct is platform-specific:
; on my manjaro x86_x64, st_size seems to be at offset 48:
; checked with https://gist.github.com/xieyuheng/b90898000668e5cac10f
%define STAT_BUFFER_SIZE 144
%define STAT_ST_SIZE_OFFSET 48

section .bss
	alignb 8
	tex_stat_buf	resb STAT_BUFFER_SIZE

section .text

;================================================================
; load_ppm: read a P6 PPM file into tex_pixels as ARGB
; in:		rdi = ptr to null-terminated filename
; out:		eax = 0 on success, nonzero on fail
;----------------------------------------------------------------
; stack frame:
;	[rbp-8]    = file descriptor
;	[rbp-16]   = mmap'd ptr
;	[rbp-24]   = file size
;	[rbp-32]   = parser cursor (byte ptr into mmap'd file)
;	[rbp-40]   = end-of-file ptr
;================================================================
load_ppm:
	push rbp
	mov rbp, rsp
	sub rsp, 64
	push rsp
	push rbx
	push r12
	push r13
	push r14
	push r15

	; --- open(filename, O_RDONLY) ---
	; rdi already has filename in
	; flags ref: man 2 open
	mov esi, O_RDONLY
	xor edx, edx
	call open
	test eax, eax
	js .fail_early		; <0 = error
	mov [rbp-8], rax	; save fd - file descriptor, small integer
						; handle the OS gives us to refer to a file
						; on the kernel's open file (fd)table

	; --- fstat(fd, &stat_buf) to get filesize ---
	mov edi, eax
	lea rsi, [tex_stat_buf]
	call fstat
	test eax, eax
	jnz .fail_close

	mov rax, [tex_stat_buf + STAT_ST_SIZE_OFFSET]
	mov [rbp-24], rax		; save file size

	; --- mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0) --
	; flags ref: man 2 mmap
	xor edi, edi			; addr = NULL
	mov rsi, rax			; length
	mov edx, PROT_READ
	mov ecx, MAP_PRIVATE
	mov r8d, [rbp-8]		; fd
	xor r9d, r9d			; offset
	call mmap
	cmp rax, -1
	je .fail_close
	mov [rbp-16], rax		; mmap ptr
	mov rbx, rax			; rbx = parser cursor
	mov [rbp-32], rbx		; set parser cursor

	; end-of-file ptr
	mov rcx, [rbp-24]		; file size
	add rcx, rbx			; cursor + fs = eof
	mov [rbp-40], rcx		; eof ptr

	; --- parse header ---
	; check magic "P6"
	cmp word [rbx], 0x3650	; '6' << 8 | 'P' little-endian
	jne .fail_unmap
	add rbx, 2				; bytes past magic

	; skip ws + comments
	call .skip_ws_and_comments

	; parse width
	call .parse_uint
	test eax, eax
	js .fail_unmap			; negative = parse error
	mov [tex_width], eax
	mov r12d, eax			; r12 = width

	call .skip_ws_and_comments
	call .parse_uint
	test eax, eax
	js .fail_unmap
	mov [tex_height], eax
	mov r13d, eax			; r13 = height

	call .skip_ws_and_comments
	call .parse_uint
	test eax, eax
	js .fail_unmap
	cmp eax, 255
	jne .fail_unmap			; i'm only gonna use max value 255
							; for 8 bit for now. maybe some fun
							; palettised ideas for later with smaller
							; number if it's supported
	; the one whitepace byte after maxval
	cmp rbx, [rbp-40]		; eof ptr
	jge .fail_unmap
	inc rbx ; advance 1 byte
	;rbx is now pointing at our RGB bytes!

	; --- allocate ARGB buffer : w*h*4b ---
	mov eax, r12d
	imul eax, r13d
	mov r14d, eax			; r14 = pixel count
	shl rax, 2				; * bytes
	mov rdi, rax
	call malloc
	test rax, rax
	jz .fail_unmap
	mov [tex_pixels], rax
	mov r15, rax			; r15 = dest cursor

	; --- convert RGB -> ARGB ---
	; for each pixel: read R,G,B bytes, write B,G,R,0xFF
	; reading little-endian into eax we'd get RGB? so building manually
	mov ecx, r14d			; loop counter = pixel count
.convert_loop:
	; bounds check: rbx + 3 > end?:
	mov rax, rbx
	add rax, 3
	cmp rax, [rbp-40]		; eof ptr
	jg .convert_short		; ERR: not enough bytes left

	movzx eax, byte [rbx]		; r
	movzx edx, byte [rbx+1]		; g
	movzx esi, byte [rbx+2]		; b
	; pack into r=eax, g=edx, b=esi
	; resulting bytes (little-endian) will be b,g,r,a
	mov edi, 0xFF000000
	shl eax, 16					; r into byte 2
	or edi, eax
	shl edx, 8					; g into byte 1
	or edi, edx
	or edi, esi					; b in byte 0
	mov [r15], edi
	add r15, 4
	add rbx, 3
	dec ecx
	jnz .convert_loop

	; --- munmap and close ---
	mov rdi, [rbp-16]			; mmap ptr
	mov rsi, [rbp-24]			; fs
	call munmap

	mov edi, [rbp-8]			; fd
	call close

	xor eax, eax				; success
	jmp .cleanup_exit

.convert_short:
	; got partway through but ran out of data; free the buffer
	mov rdi, [tex_pixels]
	call free
	mov qword [tex_pixels], 0
.fail_unmap:
	mov rdi, [rbp-16]			; mmap ptr
	mov rsi, [rbp-24]			; fs
	call munmap
.fail_close:
	mov edi, [rbp-8]			; fd
	call close

.fail_early:
	mov eax, 1 ; error code
.cleanup_exit:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	leave
	ret

;================================================================
; .skip_ws_and_comments: advance rbx past any ws/# comments
;================================================================
.skip_ws_and_comments:
.sw_loop:
	cmp rbx, [rbp-40]
	jge .sw_done
	mov al, [rbx]
	cmp al, ' '
	je .sw_advance
	cmp al, 9		; tab
	je .sw_advance
	cmp al, 10		; LF
	je .sw_advance
	cmp al, 13		; CR
	je .sw_advance
	cmp al, '#'
	je .sw_comment
	jmp .sw_done
.sw_advance:
	inc rbx
	jmp .sw_loop
.sw_comment:
	; skip until newline
.sw_comment_loop:
	inc rbx
	cmp rbx, [rbp-40]
	jge .sw_done
	cmp byte [rbx], 10
	jne .sw_comment_loop
	inc rbx			; past the LF
	jmp .sw_loop
.sw_done:
	ret


;================================================================
; .parse_uint: read ascii decimal numbers at rbx
; advances rbx past the digits.
;---------------------------------------------------------------- 
; out: eax = parsed value (or -1 if no digits found)
; clobbers: ecx, edx, al
;================================================================
.parse_uint:
	xor ecx, ecx		; accumulator
	xor edx, edx		; digits-seen flag
.pu_loop:
	cmp rbx, [rbp-40]	; eof ptr
	jge .pu_done
	mov al, [rbx]
	cmp al, '0'
	jl .pu_done
	cmp al, '9'
	jg .pu_done
	; digit
	sub al, '0'
	movzx eax, al
	imul ecx, ecx, 10
	add ecx, eax
	mov edx, 1			; mark: saw at least one digit
	inc rbx
	jmp .pu_loop
.pu_done:
	test edx, edx
	jz .pu_fail
	mov eax, ecx
	ret
.pu_fail:
	mov eax, -1
	ret

%endif