;linux syscalls
%define SYS_WRITE	1
%define SYS_EXIT	60
%define SYS_IOCTL	16
;linux file descriptors
%define STDIN		0
%define STDOUT		1

section .data
    ; escape sequences
    ; note - db is def byte(s) here, lays down as many bytes as given
    clear_screen		db 0x1b, "[2J"
    clear_screen_l		equ $ - clear_screen
    cursor_to_topleft	db 0x1b, "[H"
    cursor_to_topleft_l	equ $ - cursor_to_topleft
    title_text 			db "Town Assembly"
    title_text_l		equ $ - title_text

section .bss ; uninitialised buffers
	winsize  resb 8		; 4x 16-bit values: rows,cols,xpixel,ypixel
	cursor_x resb 2
	cursor_y resb 2
	cursor_pos_string resb 16

section .text ; begin!
    global _start

; ------------
; start screen
; ------------
start_screen:
	; set up screen
	call get_terminal_size
	
	; clear screen
	lea rsi, [clear_screen]
	mov rdx, clear_screen_l
	call print_string
	lea rsi, [cursor_to_topleft]
	mov rdx, cursor_to_topleft_l
	call print_string
	; position cursor in middle
	mov rax, [winsize]
	mov rbx, rax ; make a copy
	and rax, 0xFFFF ; mask extract just the row
	shr rbx, 16 ; shift down into bottom 16bits
	and rbx, 0xFFFF ; mask extra the column
	shr ax, 1
	shr bx, 1
	sub bx, title_text_l / 2 ;shl by half string l
	mov r8, rax ;x
	mov r9, rbx ;y
	call set_cursor_pos

	; write title text
	lea rsi, [title_text]
	mov rdx, title_text_l
	call print_string

	jmp quit_game

print_string:
	mov rax, SYS_WRITE
	mov rdi, STDOUT
	syscall ; writes to rdi, with bytes at [rsi], for rdx num of bytes
	; rax always means "which syscall"
	; rdi,rsx,rdx are then the arg slots 0,1,2 and differ per syscall
	; bytes must be in [rsi], not a register
	ret

get_terminal_size:
	mov rax, SYS_IOCTL
	mov rdi, STDOUT
	mov rsi, 0x5413  ; TIOCGWINSZ
	lea rdx, [winsize]
	syscall
	; winsize now contains [winsize]: rows(16bit) [winsize+2]: cols(16bit)
	movzx eax, word [winsize] 	; rows
	movzx ebx, word [winsize+2] ; cols
	ret

quit_game:
	; before quit, cursor to tl so prompt draws there
	lea rsi, [cursor_to_topleft]
	mov rdx, cursor_to_topleft_l
	call print_string

	mov rax, SYS_EXIT
    xor rdi, rdi
    syscall

set_cursor_pos:
	; inputs  = r8: x, r9: y
	lea rsi, [cursor_pos_string]
	mov r10, rsi ; save start position
	xor rax, rax ; ensure rax is cleared
	mov byte [rsi], 0x1b
	inc rsi
	mov byte [rsi], '['
	inc rsi

	mov rax, r8 ; input x
	call number_to_ascii_decimals

	mov byte [rsi], ';'
	inc rsi

	mov rax, r9 ; input y
	call number_to_ascii_decimals

	mov byte [rsi], 'H'
	inc rsi
	
	mov rdx, rsi
	mov rsi, r10
	sub rdx, rsi
	;print_string: rsi=loc, rdx=bytes
	call print_string

	ret

number_to_ascii_decimals:
	; input  = rax; number to convert
	; output = cursor_pos_string; 16bytes in .bss
	xor rcx, rcx ; digit counter
.divide_loop:
	xor rdx,rdx ; must clear rdx first, is upper half of dividend
				; div dives by rdx:rax combined as 128-bit number
	mov rbx, 10 ; what we divide by
	div rbx		; divs rax. outputs: rax = quotient, rdx = remainder
	add dl, '0' ; remainder to ascii, just the low byte for char
	push rdx	; push to stack
	inc rcx		; count it
	cmp rax, 0	; quotient left? then:
	jne .divide_loop
.write_loop:
	pop rdx		; get digit from stack
	mov [rsi], dl ;write ascii byte to buffer
	inc rsi
	dec rcx
	jne .write_loop
	ret

_start:
    jmp start_screen

; --------------------
; mutable state data
; --------------------
section .data
