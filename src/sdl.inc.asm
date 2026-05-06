; extern decls for SDL funcs
; linking against libSDL2, linker will resolve them

%ifndef SDL_INC
%define SDL_INC

extern SDL_Init
extern SDL_Quit
extern SDL_SetHint
extern SDL_CreateWindow
extern SDL_DestroyWindow
extern SDL_CreateRenderer
extern SDL_DestroyRenderer
extern SDL_CreateTexture
extern SDL_DestroyTexture
extern SDL_UpdateTexture
extern SDL_RenderClear
extern SDL_RenderCopy
extern SDL_RenderPresent
extern SDL_PollEvent
extern SDL_Delay
extern SDL_GetError
extern SDL_GetTicks
extern SDL_SetWindowSize
extern SDL_RenderSetLogicalSize
extern SDL_GetKeyboardState
extern SDL_StartTextInput
extern SDL_StopTextInput
extern SDL_GetMouseState


; sdl constants we need (from sdl headers, computed at runtime there)
; reference:
; https://github.com/libsdl-org/SDL/blob/SDL2/include/SDL.h
; SDL_Init flags 
%define SDL_INIT_VIDEO				0x00000020
; https://github.com/libsdl-org/SDL/blob/SDL2/include/SDL_video.h
; SDL_WindowFlags: 
%define SDL_WINDOWPOS_CENTERED		0x2FFF0000
%define SDL_WINDOW_SHOWN			0x00000004
; https://github.com/libsdl-org/SDL/blob/SDL2/include/SDL_render.h
; SDL_RendererFlags:
%define SDL_RENDERER_ACCELERATED	0x00000002
%define SDL_RENDERER_PRESENTVSYNC	0x00000004
; SDL_TextureAccess:
%define SDL_TEXTUREACCESS_STREAMING 1
; https://github.com/libsdl-org/SDL/blob/SDL2/include/SDL_pixels.h
; though it's bit-composed through a function there, seems to match
; the SDL3 version @ https://github.com/libsdl-org/SDL/blob/main/include/SDL3/SDL_pixels.h at least
%define SDL_PIXELFORMAT_ARGB8888	0x16362004

; event types
; https://github.com/libsdl-org/SDL/blob/SDL2/include/SDL_events.h
; named SDL_QUIT, SDL_KEYDOWN there as the structs are SDL_QuitEvent, etc
%define SDL_QUIT_EVENT		0x100
%define SDL_KEYDOWN_EVENT	0x300
%define SDL_TEXTINPUT_EVENT 0x303
%define SDL_MOUSEBUTTONDOWN 0x401
%define SDL_MOUSEBUTTONUP   0x402

; SDL_GetMouseState returns button mask, these are the bit positions
%define SDL_BUTTON_LEFT		1
%define SDL_BUTTON_RIGHT	3
%define SDL_BUTTON_LMASK	(1 << (SDL_BUTTON_LEFT - 1))
%define SDL_BUTTON_RMASK	(1 << (SDL_BUTTON_RIGHT - 1))

; scancodes
; https://github.com/libsdl-org/SDL/blob/SDL2/include/SDL_scancode.h
%define SCANCODE_LEFT		80
%define SCANCODE_RIGHT		79
%define SCANCODE_UP			82
%define SCANCODE_DOWN		81
%define SCANCODE_E			8
%define SCANCODE_ESCAPE		41
%define SCANCODE_F3  		60
%define SCANCODE_F4  		61
%define SCANCODE_F5  		62
%define SCANCODE_BACKTICK	53
%define SCANCODE_RETURN		40
%define SCANCODE_BACKSPACE	42

; SDL_Event layout (we only care about the bits we use)
;	offset 0:  Uint32 type
;	offset 12: char text[32] (for SDL_TextInputEvent)
;	offset 16: SDL_Scancode scancode (Uint32, in keysym)
; total size 56 bytes. we'll allocate 64 for alignment safety.
%define SDL_EVENT_TYPE_OFF		0
%define SDL_EVENT_TEXT_OFF		12
%define SDL_EVENT_SCANCODE_OFF	16
%define SDL_EVENT_SIZE			64

%endif