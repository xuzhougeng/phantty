//! Native Win32 windowing backend for Phantty.
//!
//! Replaces GLFW with direct Win32 API calls for window creation,
//! input handling, and message loop. Uses WGL for OpenGL context
//! (temporary bridge — will be replaced with D3D11 in Phase 2).
//!
//! References:
//!   - Flow editor: https://github.com/neurocyte/flow/tree/master/src/win32
//!   - direct2d-zig: https://github.com/marler8997/direct2d-zig

const std = @import("std");
const windows = std.os.windows;

// ============================================================================
// Win32 API types
// ============================================================================

pub const HWND = windows.HWND;
pub const HDC = *opaque {};
pub const HGLRC = *opaque {};
pub const HINSTANCE = windows.HINSTANCE;
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};
pub const HMENU = *opaque {};
pub const ATOM = u16;
pub const WPARAM = windows.WPARAM;
pub const LPARAM = windows.LPARAM;
pub const LRESULT = windows.LRESULT;
pub const BOOL = windows.BOOL;
pub const DWORD = windows.DWORD;
pub const UINT = u32;
pub const BYTE = u8;
pub const WORD = u16;
pub const LONG = i32;
pub const INT = i32;
pub const WCHAR = u16;

pub const RECT = extern struct {
    left: LONG,
    top: LONG,
    right: LONG,
    bottom: LONG,
};

pub const POINT = extern struct {
    x: LONG,
    y: LONG,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: INT = 0,
    cbWndExtra: INT = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const WCHAR = null,
    lpszClassName: [*:0]const WCHAR,
    hIconSm: ?HICON = null,
};

pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: WORD = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: WORD = 1,
    dwFlags: DWORD = 0,
    iPixelType: BYTE = 0,
    cColorBits: BYTE = 0,
    cRedBits: BYTE = 0,
    cRedShift: BYTE = 0,
    cGreenBits: BYTE = 0,
    cGreenShift: BYTE = 0,
    cBlueBits: BYTE = 0,
    cBlueShift: BYTE = 0,
    cAlphaBits: BYTE = 0,
    cAlphaShift: BYTE = 0,
    cAccumBits: BYTE = 0,
    cAccumRedBits: BYTE = 0,
    cAccumGreenBits: BYTE = 0,
    cAccumBlueBits: BYTE = 0,
    cAccumAlphaBits: BYTE = 0,
    cDepthBits: BYTE = 0,
    cStencilBits: BYTE = 0,
    cAuxBuffers: BYTE = 0,
    iLayerType: BYTE = 0,
    bReserved: BYTE = 0,
    dwLayerMask: DWORD = 0,
    dwVisibleMask: DWORD = 0,
    dwDamageMask: DWORD = 0,
};

pub const PAINTSTRUCT = extern struct {
    hdc: ?HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]BYTE,
};

pub const WINDOWPOS = extern struct {
    hwnd: ?HWND,
    hwndInsertAfter: ?HWND,
    x: INT,
    y: INT,
    cx: INT,
    cy: INT,
    flags: UINT,
};

pub const NCCALCSIZE_PARAMS = extern struct {
    rgrc: [3]RECT,
    lppos: *WINDOWPOS,
};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

// ============================================================================
// Constants
// ============================================================================

// Window styles
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_VISIBLE: DWORD = 0x10000000;

// Extended window styles
pub const WS_EX_APPWINDOW: DWORD = 0x00040000;

// Window class styles
pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_OWNDC: UINT = 0x0020;
pub const CS_DBLCLKS: UINT = 0x0008;

// ShowWindow commands
pub const SW_MINIMIZE: INT = 6;
pub const SW_SHOW: INT = 5;
pub const SW_RESTORE: INT = 9;
pub const SW_MAXIMIZE: INT = 3;

// CW_USEDEFAULT
pub const CW_USEDEFAULT: INT = @bitCast(@as(u32, 0x80000000));

// Pixel format flags
pub const PFD_DRAW_TO_WINDOW: DWORD = 0x00000004;
pub const PFD_SUPPORT_OPENGL: DWORD = 0x00000020;
pub const PFD_DOUBLEBUFFER: DWORD = 0x00000001;
pub const PFD_TYPE_RGBA: BYTE = 0;
pub const PFD_MAIN_PLANE: BYTE = 0;

// Window messages
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_LBUTTONDBLCLK: UINT = 0x0203;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_NCMBUTTONDOWN: UINT = 0x00A8;
pub const WM_NCMBUTTONUP: UINT = 0x00A9;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_DPICHANGED: UINT = 0x02E0;
pub const WM_NCCALCSIZE: UINT = 0x0083;
pub const WM_NCHITTEST: UINT = 0x0084;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_NCLBUTTONDOWN: UINT = 0x00A1;
pub const WM_NCLBUTTONUP: UINT = 0x00A2;
pub const WM_NCMOUSEMOVE: UINT = 0x00A0;
pub const WM_NCMOUSELEAVE: UINT = 0x02A2;
pub const WM_MOUSELEAVE: UINT = 0x02A3;
pub const WM_ACTIVATE: UINT = 0x0006;
pub const WM_GETMINMAXINFO: UINT = 0x0024;

// TrackMouseEvent
pub const TME_LEAVE: DWORD = 0x00000002;
pub const TME_NONCLIENT: DWORD = 0x00000010;

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: DWORD = 0,
    hwndTrack: ?HWND = null,
    dwHoverTime: DWORD = 0,
};

extern "user32" fn TrackMouseEvent(lpEventTrack: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;

// NCHITTEST return values
pub const HTCLIENT: LRESULT = 1;
pub const HTCAPTION: LRESULT = 2;
pub const HTSYSMENU: LRESULT = 3;
pub const HTMINBUTTON: LRESULT = 8;
pub const HTMAXBUTTON: LRESULT = 9;
pub const HTLEFT: LRESULT = 10;
pub const HTRIGHT: LRESULT = 11;
pub const HTTOP: LRESULT = 12;
pub const HTTOPLEFT: LRESULT = 13;
pub const HTTOPRIGHT: LRESULT = 14;
pub const HTBOTTOM: LRESULT = 15;
pub const HTBOTTOMLEFT: LRESULT = 16;
pub const HTBOTTOMRIGHT: LRESULT = 17;
pub const HTCLOSE: LRESULT = 20;

// Virtual key codes
pub const VK_RETURN: WPARAM = 0x0D;
pub const VK_BACK: WPARAM = 0x08;
pub const VK_TAB: WPARAM = 0x09;
pub const VK_ESCAPE: WPARAM = 0x1B;
pub const VK_UP: WPARAM = 0x26;
pub const VK_DOWN: WPARAM = 0x28;
pub const VK_LEFT: WPARAM = 0x25;
pub const VK_RIGHT: WPARAM = 0x27;
pub const VK_HOME: WPARAM = 0x24;
pub const VK_END: WPARAM = 0x23;
pub const VK_PRIOR: WPARAM = 0x21; // Page Up
pub const VK_NEXT: WPARAM = 0x22; // Page Down
pub const VK_INSERT: WPARAM = 0x2D;
pub const VK_DELETE: WPARAM = 0x2E;
pub const VK_SHIFT: WPARAM = 0x10;
pub const VK_CONTROL: WPARAM = 0x11;
pub const VK_MENU: WPARAM = 0x12; // Alt
pub const VK_CAPITAL: WPARAM = 0x14; // Caps Lock
pub const VK_LWIN: WPARAM = 0x5B;
pub const VK_RWIN: WPARAM = 0x5C;
pub const VK_NUMLOCK: WPARAM = 0x90;
pub const VK_SCROLL: WPARAM = 0x91;
pub const VK_LSHIFT: WPARAM = 0xA0;
pub const VK_RSHIFT: WPARAM = 0xA1;
pub const VK_LCONTROL: WPARAM = 0xA2;
pub const VK_RCONTROL: WPARAM = 0xA3;
pub const VK_LMENU: WPARAM = 0xA4; // Left Alt
pub const VK_RMENU: WPARAM = 0xA5; // Right Alt
pub const VK_OEM_COMMA: WPARAM = 0xBC;
pub const VK_OEM_PLUS: WPARAM = 0xBB; // '+' / '=' key
pub const VK_OEM_MINUS: WPARAM = 0xBD; // '-' / '_' key
pub const VK_OEM_4: WPARAM = 0xDB; // '[' key
pub const VK_OEM_6: WPARAM = 0xDD; // ']' key
pub const VK_F11: WPARAM = 0x7A;

// GetKeyState
pub const KEY_PRESSED: i16 = @bitCast(@as(u16, 0x8000));

// ============================================================================
// Win32 API imports
// ============================================================================

extern "user32" fn LoadImageW(
    hInst: ?HINSTANCE,
    name: usize, // MAKEINTRESOURCE returns a usize
    type: UINT,
    cx: INT,
    cy: INT,
    fuLoad: UINT,
) callconv(.winapi) ?HICON;
extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: [*:0]const WCHAR,
    lpWindowName: [*:0]const WCHAR,
    dwStyle: DWORD,
    X: INT,
    Y: INT,
    nWidth: INT,
    nHeight: INT,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: INT) callconv(.winapi) BOOL;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) BOOL;
extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT, wRemoveMsg: UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(nExitCode: INT) callconv(.winapi) void;
pub extern "user32" fn PostMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.winapi) INT;
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForWindow(hWnd: HWND) callconv(.winapi) UINT;
extern "user32" fn SendMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) ?HDC;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn GetKeyState(nVirtKey: INT) callconv(.winapi) i16;
extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: [*:0]const WCHAR) callconv(.winapi) BOOL;
extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: usize) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?HWND, X: INT, Y: INT, cx: INT, cy: INT, uFlags: UINT) callconv(.winapi) BOOL;
extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn MessageBeep(uType: UINT) callconv(.winapi) BOOL;
extern "user32" fn FlashWindowEx(pfwi: *const FLASHWINFO) callconv(.winapi) BOOL;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;

// Clipboard
pub extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn SetClipboardData(uFormat: UINT, hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn IsClipboardFormatAvailable(format: UINT) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalLock(hMem: *anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(hMem: *anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalSize(hMem: *anyopaque) callconv(.winapi) usize;

// ============================================================================
// ConPTY, pipes, and process management
// ============================================================================

pub const HPCON = windows.HANDLE;
pub const COORD = extern struct {
    X: i16,
    Y: i16,
};
pub const HRESULT = i32;
pub const S_OK: HRESULT = 0;

pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: BOOL,
};

pub const STARTUPINFOEXW = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

// Process creation flags
pub const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
pub const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;
pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
pub const HANDLE_FLAG_INHERIT: DWORD = 0x00000001;

// Named pipe constants
pub const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
pub const PIPE_ACCESS_OUTBOUND: DWORD = 0x00000002;
pub const PIPE_ACCESS_INBOUND: DWORD = 0x00000001;
pub const PIPE_TYPE_BYTE: DWORD = 0x00000000;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x00080000;
pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const OPEN_EXISTING: DWORD = 3;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x00000080;

// Wait constants
pub const WAIT_OBJECT_0: DWORD = 0x00000000;
pub const WAIT_TIMEOUT: DWORD = 0x00000102;
pub const INFINITE: DWORD = 0xFFFFFFFF;

pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
pub extern "kernel32" fn SetHandleInformation(hObject: windows.HANDLE, dwMask: DWORD, dwFlags: DWORD) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreatePipe(
    hReadPipe: *windows.HANDLE,
    hWritePipe: *windows.HANDLE,
    lpPipeAttributes: ?*const SECURITY_ATTRIBUTES,
    nSize: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateNamedPipeW(
    lpName: [*:0]const u16,
    dwOpenMode: DWORD,
    dwPipeMode: DWORD,
    nMaxInstances: DWORD,
    nOutBufferSize: DWORD,
    nInBufferSize: DWORD,
    nDefaultTimeOut: DWORD,
    lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES,
) callconv(.winapi) windows.HANDLE;

pub extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;

pub extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: windows.HANDLE,
    hOutput: windows.HANDLE,
    dwFlags: DWORD,
    phPC: *HPCON,
) callconv(.winapi) HRESULT;

pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;

pub extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: COORD) callconv(.winapi) HRESULT;

pub extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?*anyopaque,
    dwAttributeCount: DWORD,
    dwFlags: DWORD,
    lpSize: *usize,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: ?*anyopaque,
    dwFlags: DWORD,
    Attribute: usize,
    lpValue: ?*anyopaque,
    cbSize: usize,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*usize,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: ?*anyopaque) callconv(.winapi) void;

pub extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *STARTUPINFOEXW,
    lpProcessInformation: *windows.PROCESS_INFORMATION,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpBuffer: ?*anyopaque,
    nBufferSize: DWORD,
    lpBytesRead: ?*DWORD,
    lpTotalBytesAvail: ?*DWORD,
    lpBytesLeftThisMessage: ?*DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn CancelIoEx(
    hFile: windows.HANDLE,
    lpOverlapped: ?*windows.OVERLAPPED,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;

pub extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*anyopaque,
    bManualReset: BOOL,
    bInitialState: BOOL,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?windows.HANDLE;

pub extern "kernel32" fn SetEvent(hEvent: windows.HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn ResetEvent(hEvent: windows.HANDLE) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetExitCodeProcess(hProcess: windows.HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;

// Fullscreen
pub extern "user32" fn GetWindowLongW(hWnd: HWND, nIndex: INT) callconv(.winapi) LONG;
pub extern "user32" fn SetWindowLongW(hWnd: HWND, nIndex: INT, dwNewLong: LONG) callconv(.winapi) LONG;
pub extern "user32" fn MonitorFromWindow(hWnd: HWND, dwFlags: DWORD) callconv(.winapi) ?HMONITOR;
pub extern "user32" fn GetMonitorInfoW(hMonitor: HMONITOR, lpmi: *MONITORINFO) callconv(.winapi) BOOL;

pub const HMONITOR = *opaque {};
pub const MONITORINFO = extern struct {
    cbSize: DWORD = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    rcWork: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    dwFlags: DWORD = 0,
};

extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) INT;
extern "gdi32" fn SetPixelFormat(hdc: HDC, format: INT, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;

extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) ?HGLRC;
extern "opengl32" fn wglMakeCurrent(hdc: HDC, hglrc: ?HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglGetProcAddress(lpszProc: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

// DWM (Desktop Window Manager)
extern "dwmapi" fn DwmSetWindowAttribute(hWnd: HWND, dwAttribute: DWORD, pvAttribute: *const anyopaque, cbAttribute: DWORD) callconv(.winapi) windows.HRESULT;
extern "dwmapi" fn DwmExtendFrameIntoClientArea(hWnd: HWND, pMarInset: *const MARGINS) callconv(.winapi) windows.HRESULT;
extern "dwmapi" fn DwmDefWindowProc(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM, plResult: *LRESULT) callconv(.winapi) BOOL;

pub const MARGINS = extern struct {
    cxLeftWidth: INT,
    cxRightWidth: INT,
    cyTopHeight: INT,
    cyBottomHeight: INT,
};

// FlashWindowEx
pub const FLASHWINFO = extern struct {
    cbSize: UINT,
    hwnd: HWND,
    dwFlags: DWORD,
    uCount: UINT,
    dwTimeout: DWORD,
};
pub const FLASHW_ALL: DWORD = 3; // Flash both caption and taskbar
pub const FLASHW_TIMERNOFG: DWORD = 12; // Flash until window comes to foreground

// MessageBeep
pub const MB_OK: UINT = 0x00000000; // Default system sound

// kernel32 for GetModuleHandle and GetProcAddress
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const WCHAR) callconv(.winapi) ?HINSTANCE;
extern "kernel32" fn GetProcAddress(hModule: HINSTANCE, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

// System metrics
pub extern "user32" fn GetSystemMetrics(nIndex: INT) callconv(.winapi) INT;
pub const SM_CXSIZEFRAME: INT = 32;
pub const SM_CYSIZEFRAME: INT = 33;
pub const SM_CXPADDEDBORDER: INT = 92;

// IsZoomed (maximized check)
pub extern "user32" fn IsZoomed(hWnd: HWND) callconv(.winapi) BOOL;

// Screen-to-client coordinate conversion
pub extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;

// Cursor management
pub extern "user32" fn SetCursor(hCursor: ?HCURSOR) callconv(.winapi) ?HCURSOR;
pub fn LoadCursor(hInstance: ?HINSTANCE, lpCursorName: usize) ?HCURSOR {
    return LoadCursorW(hInstance, lpCursorName);
}

// IDC_* cursor resources (MAKEINTRESOURCE values)
pub const IDC_ARROW: usize = 32512;
pub const IDC_SIZEWE: usize = 32644; // Horizontal resize (left-right)
pub const IDC_SIZENS: usize = 32645; // Vertical resize (up-down)

// DWM attributes
const DWMWA_USE_IMMERSIVE_DARK_MODE: DWORD = 20;

/// Height of the custom title bar area in pixels.
/// This is where tabs will eventually be drawn.
/// Windows Terminal uses ~40px at 96 DPI. We match that.
pub const TITLEBAR_HEIGHT: i32 = 34;

// PM_REMOVE for PeekMessage
const PM_REMOVE: UINT = 0x0001;

// SWP flags for SetWindowPos
const SWP_NOZORDER: UINT = 0x0004;
const SWP_NOMOVE: UINT = 0x0002;
const SWP_NOSIZE: UINT = 0x0001;
const SWP_FRAMECHANGED: UINT = 0x0020;

// ============================================================================
// Window state
// ============================================================================

// ============================================================================
// Input event types
// ============================================================================

/// Keyboard events (special keys via WM_KEYDOWN/WM_SYSKEYDOWN)
pub const KeyEvent = struct {
    vk: WPARAM,
    ctrl: bool,
    shift: bool,
    alt: bool,
};

/// Character input events (text via WM_CHAR, after TranslateMessage)
pub const CharEvent = struct {
    codepoint: u21,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

pub const MouseButton = enum { left, right, middle };
pub const MouseButtonAction = enum { press, release, double_click };

/// Mouse button events
pub const MouseButtonEvent = struct {
    button: MouseButton,
    action: MouseButtonAction,
    x: i32,
    y: i32,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

/// Mouse move events
pub const MouseMoveEvent = struct {
    x: i32,
    y: i32,
};

/// Mouse wheel events
pub const MouseWheelEvent = struct {
    delta: i16, // positive = up, negative = down
    xpos: i32, // mouse x position in window coordinates
    ypos: i32, // mouse y position in window coordinates
};

// Fixed-size ring buffers for events (avoids allocation in WndProc)
fn RingBuffer(comptime T: type, comptime N: usize) type {
    return struct {
        items: [N]T = undefined,
        head: usize = 0,
        count: usize = 0,

        pub fn push(self: *@This(), item: T) void {
            const idx = (self.head + self.count) % N;
            self.items[idx] = item;
            if (self.count < N) {
                self.count += 1;
            } else {
                // Overflow: drop oldest
                self.head = (self.head + 1) % N;
            }
        }

        pub fn pop(self: *@This()) ?T {
            if (self.count == 0) return null;
            const item = self.items[self.head];
            self.head = (self.head + 1) % N;
            self.count -= 1;
            return item;
        }
    };
}

pub const CaptionButton = enum { none, minimize, maximize, close };

/// Platform window handle and associated state.
pub const Window = struct {
    hwnd: HWND,
    hdc: HDC,
    hglrc: HGLRC,
    should_close: bool = false,
    width: i32 = 800,
    height: i32 = 600,
    focused: bool = true,
    is_fullscreen: bool = false,

    // Custom title bar
    titlebar_height: i32 = TITLEBAR_HEIGHT,
    /// Which caption button is currently hovered (if any).
    /// Updated each frame from mouse position.
    hovered_button: CaptionButton = .none,
    /// Which caption button is currently pressed (mouse down, waiting for up)
    pressed_button: CaptionButton = .none,
    /// Tab count (synced from main.zig each frame, used for hit-testing)
    tab_count: usize = 1,
    /// Current sidebar width (synced from renderer/input, used for double-click routing)
    sidebar_width: i32 = 220,
    /// Plus button x range (synced from renderer, used for double-click suppression)
    plus_btn_x_start: i32 = 0,
    plus_btn_x_end: i32 = 0,
    /// Per-tab close button x ranges (synced from renderer, used for double-click suppression)
    close_btn_x_start: [16]i32 = .{0} ** 16,
    close_btn_x_end: [16]i32 = .{0} ** 16,
    /// Current mouse position in client coordinates (for hover tracking)
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,

    // Input event queues (written by WndProc, read by main loop)
    key_events: RingBuffer(KeyEvent, 64) = .{},
    char_events: RingBuffer(CharEvent, 64) = .{},
    mouse_button_events: RingBuffer(MouseButtonEvent, 32) = .{},
    mouse_move_events: RingBuffer(MouseMoveEvent, 64) = .{},
    mouse_wheel_events: RingBuffer(MouseWheelEvent, 16) = .{},
    size_changed: bool = false, // set by WM_SIZE, cleared after processing

    /// Optional callback invoked from WM_SIZE so the application can
    /// do a GL clear+swap during the Win32 modal resize loop. Without
    /// this, newly exposed pixels show as black until the main loop
    /// renders the next frame.
    on_resize: ?*const fn (width: i32, height: i32) void = null,

    /// Initialize a Win32 window with an OpenGL 3.3 core profile context.
    ///
    /// Modern OpenGL on Win32 requires a two-step bootstrap:
    /// 1. Create a dummy window + legacy WGL context
    /// 2. Load wglCreateContextAttribsARB from the legacy context
    /// 3. Create the real window + OpenGL 3.3 core profile context
    /// 4. Destroy the dummy window
    pub fn init(
        width: i32,
        height: i32,
        title: [*:0]const WCHAR,
        x: ?i32,
        y: ?i32,
        maximize: bool,
    ) !Window {
        const hInstance = GetModuleHandleW(null);

        // --- Step 1: Register window classes ---
        const dummy_class = std.unicode.utf8ToUtf16LeStringLiteral("PhanttyDummyClass");
        const real_class = std.unicode.utf8ToUtf16LeStringLiteral("PhanttyWindowClass");

        const dummy_wc = WNDCLASSEXW{
            .style = CS_OWNDC,
            .lpfnWndProc = DefWindowProcW,
            .hInstance = hInstance,
            .lpszClassName = dummy_class,
        };
        _ = RegisterClassExW(&dummy_wc);

        // Load application icon from embedded resource (resource ID 1, set in phantty.rc).
        // MAKEINTRESOURCE(1) = 1, IMAGE_ICON = 1, LR_SHARED = 0x8000
        const IMAGE_ICON: UINT = 1;
        const LR_SHARED: UINT = 0x8000;
        const icon_big = LoadImageW(hInstance, 1, IMAGE_ICON, 0, 0, LR_SHARED);
        const icon_small = LoadImageW(hInstance, 1, IMAGE_ICON, 16, 16, 0);

        const real_wc = WNDCLASSEXW{
            .style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC | CS_DBLCLKS,
            .lpfnWndProc = wndProc,
            .hInstance = hInstance,
            .hIcon = icon_big,
            .hCursor = LoadCursorW(null, IDC_ARROW),
            .lpszClassName = real_class,
            .hIconSm = icon_small,
        };
        if (RegisterClassExW(&real_wc) == 0) {
            // May already be registered from a previous call — that's OK
        }

        // --- Step 2: Create dummy window + legacy context to load WGL extensions ---
        const dummy_hwnd = CreateWindowExW(
            0,
            dummy_class,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            0, // not visible
            0,
            0,
            1,
            1,
            null,
            null,
            hInstance,
            null,
        ) orelse {
            std.debug.print("Win32: Failed to create dummy window\n", .{});
            return error.CreateWindowFailed;
        };

        const dummy_hdc = GetDC(dummy_hwnd) orelse {
            _ = DestroyWindow(dummy_hwnd);
            return error.GetDCFailed;
        };

        const pfd = PIXELFORMATDESCRIPTOR{
            .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
            .iPixelType = PFD_TYPE_RGBA,
            .cColorBits = 32,
            .cDepthBits = 24,
            .cStencilBits = 8,
            .iLayerType = PFD_MAIN_PLANE,
        };

        const dummy_pf = ChoosePixelFormat(dummy_hdc, &pfd);
        if (dummy_pf == 0) {
            _ = DestroyWindow(dummy_hwnd);
            return error.ChoosePixelFormatFailed;
        }
        _ = SetPixelFormat(dummy_hdc, dummy_pf, &pfd);

        const dummy_gl = wglCreateContext(dummy_hdc) orelse {
            _ = DestroyWindow(dummy_hwnd);
            return error.WGLCreateContextFailed;
        };
        _ = wglMakeCurrent(dummy_hdc, dummy_gl);

        // Load the modern context creation function
        const wglCreateContextAttribsARB_ptr = wglGetProcAddress("wglCreateContextAttribsARB");
        const wglChoosePixelFormatARB_ptr = wglGetProcAddress("wglChoosePixelFormatARB");

        // Clean up dummy resources
        _ = wglMakeCurrent(dummy_hdc, null);
        _ = wglDeleteContext(dummy_gl);
        _ = DestroyWindow(dummy_hwnd);

        if (wglCreateContextAttribsARB_ptr == null) {
            std.debug.print("Win32: wglCreateContextAttribsARB not available\n", .{});
            return error.WGLExtensionNotAvailable;
        }

        const createContextAttribs: *const fn (HDC, ?HGLRC, ?[*]const i32) callconv(.winapi) ?HGLRC =
            @ptrCast(wglCreateContextAttribsARB_ptr.?);

        // --- Step 3: Create the real window ---
        const hwnd = CreateWindowExW(
            WS_EX_APPWINDOW,
            real_class,
            title,
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            if (x) |xv| xv else CW_USEDEFAULT,
            if (y) |yv| yv else CW_USEDEFAULT,
            width,
            height,
            null,
            null,
            hInstance,
            null,
        ) orelse {
            std.debug.print("Win32: Failed to create window\n", .{});
            return error.CreateWindowFailed;
        };

        // Enable dark mode on the title bar
        var dark_mode: BOOL = 1;
        _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE,
            @ptrCast(&dark_mode),
            @sizeOf(BOOL),
        );

        // Extend frame into client area for custom title bar
        // Setting top margin = -1 tells DWM to extend the entire frame into client area,
        // letting us paint our own title bar while keeping the window shadow.
        const margins = MARGINS{
            .cxLeftWidth = 0,
            .cxRightWidth = 0,
            .cyTopHeight = -1,
            .cyBottomHeight = 0,
        };
        _ = DwmExtendFrameIntoClientArea(hwnd, &margins);

        // Force Windows to recalculate the non-client area using our WM_NCCALCSIZE handler.
        // Without this, the native titlebar may still appear until the window is resized.
        _ = SetWindowPos(hwnd, null, 0, 0, 0, 0, SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER);

        const hdc = GetDC(hwnd) orelse {
            _ = DestroyWindow(hwnd);
            return error.GetDCFailed;
        };

        // Set pixel format on the real window
        // If we have wglChoosePixelFormatARB, use it for better format selection
        var pixel_format: i32 = 0;
        if (wglChoosePixelFormatARB_ptr) |choose_ptr| {
            const choosePixelFormat: *const fn (
                HDC,
                [*]const i32,
                ?[*]const f32,
                u32,
                *i32,
                *u32,
            ) callconv(.winapi) BOOL = @ptrCast(choose_ptr);

            const WGL_DRAW_TO_WINDOW_ARB: i32 = 0x2001;
            const WGL_SUPPORT_OPENGL_ARB: i32 = 0x2010;
            const WGL_DOUBLE_BUFFER_ARB: i32 = 0x2011;
            const WGL_PIXEL_TYPE_ARB: i32 = 0x2013;
            const WGL_TYPE_RGBA_ARB: i32 = 0x202B;
            const WGL_COLOR_BITS_ARB: i32 = 0x2014;
            const WGL_DEPTH_BITS_ARB: i32 = 0x2022;
            const WGL_STENCIL_BITS_ARB: i32 = 0x2023;

            const attribs = [_]i32{
                WGL_DRAW_TO_WINDOW_ARB, 1,
                WGL_SUPPORT_OPENGL_ARB, 1,
                WGL_DOUBLE_BUFFER_ARB,  1,
                WGL_PIXEL_TYPE_ARB,     WGL_TYPE_RGBA_ARB,
                WGL_COLOR_BITS_ARB,     32,
                WGL_DEPTH_BITS_ARB,     24,
                WGL_STENCIL_BITS_ARB,   8,
                0, // terminator
            };
            var num_formats: u32 = 0;
            _ = choosePixelFormat(hdc, &attribs, null, 1, &pixel_format, &num_formats);
        }

        if (pixel_format == 0) {
            // Fallback to basic ChoosePixelFormat
            pixel_format = ChoosePixelFormat(hdc, &pfd);
        }

        if (pixel_format == 0) {
            _ = DestroyWindow(hwnd);
            return error.ChoosePixelFormatFailed;
        }
        if (SetPixelFormat(hdc, pixel_format, &pfd) == 0) {
            _ = DestroyWindow(hwnd);
            return error.SetPixelFormatFailed;
        }

        // --- Step 4: Create OpenGL 3.3 core profile context ---
        const WGL_CONTEXT_MAJOR_VERSION_ARB: i32 = 0x2091;
        const WGL_CONTEXT_MINOR_VERSION_ARB: i32 = 0x2092;
        const WGL_CONTEXT_PROFILE_MASK_ARB: i32 = 0x9126;
        const WGL_CONTEXT_CORE_PROFILE_BIT_ARB: i32 = 0x00000001;

        const ctx_attribs = [_]i32{
            WGL_CONTEXT_MAJOR_VERSION_ARB, 3,
            WGL_CONTEXT_MINOR_VERSION_ARB, 3,
            WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            0, // terminator
        };

        const hglrc = createContextAttribs(hdc, null, &ctx_attribs) orelse {
            std.debug.print("Win32: Failed to create OpenGL 3.3 core context\n", .{});
            _ = DestroyWindow(hwnd);
            return error.WGLCreateContextFailed;
        };

        if (wglMakeCurrent(hdc, hglrc) == 0) {
            _ = wglDeleteContext(hglrc);
            _ = DestroyWindow(hwnd);
            return error.WGLMakeCurrentFailed;
        }

        // Get actual client area size
        var rect: RECT = undefined;
        _ = GetClientRect(hwnd, &rect);

        std.debug.print("Win32: Window created {}x{} (client: {}x{})\n", .{
            width, height, rect.right - rect.left, rect.bottom - rect.top,
        });

        var window = Window{
            .hwnd = hwnd,
            .hdc = hdc,
            .hglrc = hglrc,
            .width = rect.right - rect.left,
            .height = rect.bottom - rect.top,
            .is_fullscreen = false, // Fullscreen is applied later via toggleFullscreen
        };

        // Apply initial window state (maximize)
        // Note: fullscreen is handled separately via toggleFullscreen after init
        if (maximize) {
            _ = ShowWindow(hwnd, SW_MAXIMIZE);
            // Update size after maximize
            _ = GetClientRect(hwnd, &rect);
            window.width = rect.right - rect.left;
            window.height = rect.bottom - rect.top;
        }

        return window;
    }

    pub fn deinit(self: *Window) void {
        _ = wglMakeCurrent(self.hdc, null);
        _ = wglDeleteContext(self.hglrc);
        _ = DestroyWindow(self.hwnd);
    }

    pub fn swapBuffers(self: *Window) void {
        _ = SwapBuffers(self.hdc);
    }

    /// Get the client area size (for OpenGL viewport).
    pub fn getFramebufferSize(self: *Window) struct { width: i32, height: i32 } {
        var rect: RECT = undefined;
        _ = GetClientRect(self.hwnd, &rect);
        return .{
            .width = rect.right - rect.left,
            .height = rect.bottom - rect.top,
        };
    }

    /// Process all pending window messages. Returns false if WM_QUIT received.
    pub fn pollEvents(self: *Window) bool {
        var msg: MSG = undefined;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
            if (msg.message == 0x0012) { // WM_QUIT
                self.should_close = true;
                return false;
            }
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        return !self.should_close;
    }

    /// Play the system default notification sound.
    pub fn playBell(_: *Window) void {
        _ = MessageBeep(MB_OK);
    }

    /// Flash the taskbar icon to get user attention (only when not focused).
    pub fn flashTaskbar(self: *Window) void {
        // Only flash if this window is not the foreground window
        if (GetForegroundWindow() == self.hwnd) return;
        var fwi = FLASHWINFO{
            .cbSize = @sizeOf(FLASHWINFO),
            .hwnd = self.hwnd,
            .dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG,
            .uCount = 3,
            .dwTimeout = 0, // Use default cursor blink rate
        };
        _ = FlashWindowEx(&fwi);
    }

    /// Resize the window to fit the given client area dimensions.
    pub fn setSize(self: *Window, w: i32, h: i32) void {
        // We need to account for window chrome (title bar, borders)
        var rect = RECT{
            .left = 0,
            .top = 0,
            .right = w,
            .bottom = h,
        };
        // AdjustWindowRectEx to account for chrome
        adjustWindowRectEx(&rect, WS_OVERLAPPEDWINDOW, 0, WS_EX_APPWINDOW);
        _ = SetWindowPos(
            self.hwnd,
            null,
            0,
            0,
            rect.right - rect.left,
            rect.bottom - rect.top,
            SWP_NOZORDER | SWP_NOMOVE,
        );
    }
};

/// OpenGL function loader for GLAD.
/// On Windows, wglGetProcAddress only returns extension functions (GL 1.2+).
/// Core OpenGL 1.0/1.1 functions must come from opengl32.dll via GetProcAddress.
/// This matches what GLFW's glfwGetProcAddress does internally.
var opengl32_handle: ?HINSTANCE = null;

pub fn glGetProcAddress(name: [*:0]const u8) callconv(.c) ?*const anyopaque {
    // Try wglGetProcAddress first (extensions + GL 1.2+ functions)
    const wgl_result = wglGetProcAddress(name);
    if (wgl_result) |ptr| return ptr;

    // Fall back to GetProcAddress from opengl32.dll (GL 1.0/1.1 core functions)
    const handle = opengl32_handle orelse blk: {
        const h = GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("opengl32.dll"));
        opengl32_handle = h;
        break :blk h;
    };
    if (handle) |h| {
        return GetProcAddress(h, name);
    }
    return null;
}

// AdjustWindowRectEx — accounts for window chrome when sizing
extern "user32" fn AdjustWindowRectEx(lpRect: *RECT, dwStyle: DWORD, bMenu: BOOL, dwExStyle: DWORD) callconv(.winapi) BOOL;

fn adjustWindowRectEx(rect: *RECT, style: DWORD, menu: BOOL, ex_style: DWORD) void {
    _ = AdjustWindowRectEx(rect, style, menu, ex_style);
}

// ============================================================================
// Window procedure (message handler)
// ============================================================================

// Global pointer to the active window (for the WndProc callback)
// Thread-local so each window thread has its own pointer
threadlocal var g_win32_window: ?*Window = null;

/// Set the global window pointer so WndProc can update it.
pub fn setGlobalWindow(w: *Window) void {
    g_win32_window = w;
}

fn getModifiers() struct { ctrl: bool, shift: bool, alt: bool } {
    return .{
        .ctrl = (GetKeyState(@intCast(VK_CONTROL)) & KEY_PRESSED) != 0,
        .shift = (GetKeyState(@intCast(VK_SHIFT)) & KEY_PRESSED) != 0,
        .alt = (GetKeyState(@intCast(VK_MENU)) & KEY_PRESSED) != 0,
    };
}

fn pushMouseButtonEvent(w: *Window, button: MouseButton, action: MouseButtonAction, x: i32, y: i32) void {
    const mods = getModifiers();
    w.mouse_button_events.push(.{
        .button = button,
        .action = action,
        .x = x,
        .y = y,
        .ctrl = mods.ctrl,
        .shift = mods.shift,
        .alt = mods.alt,
    });
}

fn getResizeBorderThickness() i32 {
    // SM_CXSIZEFRAME + SM_CXPADDEDBORDER gives the total resize border width
    return GetSystemMetrics(SM_CXSIZEFRAME) + GetSystemMetrics(SM_CXPADDEDBORDER);
}

/// Get the caption button width (min/max/close area).
/// Each button is ~46px wide at 96 DPI. Three buttons = ~138px.
fn getCaptionButtonWidth() i32 {
    return 46 * 3;
}

fn wndProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    // Let DWM handle some non-client messages first (for window shadow, etc.)
    // BUT skip WM_NCCALCSIZE and WM_NCHITTEST — we handle those ourselves
    // for the custom title bar.
    // Let DWM handle some non-client messages (window shadow, etc.)
    // Skip messages we handle ourselves to prevent legacy button rendering:
    // - WM_NCCALCSIZE, WM_NCHITTEST: custom title bar
    // - WM_NCLBUTTONDOWN (0x00A1): prevents Win95-style button on click+hold
    // - WM_NCMOUSEMOVE, WM_NCMOUSELEAVE: our hover tracking
    if (msg != WM_NCCALCSIZE and msg != WM_NCHITTEST and
        msg != WM_NCLBUTTONDOWN and msg != WM_NCLBUTTONUP and
        msg != WM_NCMBUTTONDOWN and msg != WM_NCMBUTTONUP and
        msg != WM_NCMOUSEMOVE and msg != WM_NCMOUSELEAVE)
    {
        var dwm_result: LRESULT = 0;
        if (DwmDefWindowProc(hwnd, msg, wParam, lParam, &dwm_result) != 0) {
            return dwm_result;
        }
    }

    // Handle WM_NCCALCSIZE even before g_win32_window is set (during CreateWindowExW).
    // This is critical for removing the native titlebar on window creation.
    if (msg == WM_NCCALCSIZE) {
        if (wParam == 1) {
            // Remove all non-client area (no default title bar or borders).
            // Our WM_NCHITTEST handler provides resize borders and caption.
            // Note: maximized window handling is done below when w is available.
            if (g_win32_window) |w| {
                if (IsZoomed(hwnd) != 0 and !w.is_fullscreen) {
                    const params: *NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lParam)));
                    const border = getResizeBorderThickness();
                    params.rgrc[0].top += border;
                    params.rgrc[0].left += border;
                    params.rgrc[0].right -= border;
                    params.rgrc[0].bottom -= border;
                }
            }
            return 0;
        }
        return 0;
    }

    const w = g_win32_window orelse return DefWindowProcW(hwnd, msg, wParam, lParam);

    switch (msg) {
        WM_CLOSE => {
            w.should_close = true;
            return 0;
        },
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        WM_SIZE => {
            const width: i32 = @as(i16, @bitCast(@as(u16, @intCast(lParam & 0xFFFF))));
            const height: i32 = @as(i16, @bitCast(@as(u16, @intCast((lParam >> 16) & 0xFFFF))));
            w.width = width;
            w.height = height;
            w.size_changed = true;
            // Render a frame immediately so newly exposed pixels show
            // the terminal background instead of black. This runs inside
            // the Win32 modal resize loop where our main loop is blocked.
            if (w.on_resize) |cb| cb(width, height);
            return 0;
        },
        WM_ACTIVATE => {
            // Re-extend frame on activation changes to keep the custom frame
            const margins = MARGINS{
                .cxLeftWidth = 0,
                .cxRightWidth = 0,
                .cyTopHeight = -1,
                .cyBottomHeight = 0,
            };
            _ = DwmExtendFrameIntoClientArea(hwnd, &margins);
            return 0;
        },
        WM_SETFOCUS => {
            w.focused = true;
            return 0;
        },
        WM_KILLFOCUS => {
            w.focused = false;
            return 0;
        },
        WM_ERASEBKGND => {
            return 1;
        },

        // WM_NCCALCSIZE is handled before the switch (to work during CreateWindowExW)

        // --- Custom title bar: hit testing ---
        WM_NCHITTEST => {
            // Convert screen coordinates to client coordinates
            var pt = POINT{
                .x = @as(i16, @bitCast(@as(u16, @intCast(lParam & 0xFFFF)))),
                .y = @as(i16, @bitCast(@as(u16, @intCast((lParam >> 16) & 0xFFFF)))),
            };
            _ = ScreenToClient(hwnd, &pt);

            var client_rect: RECT = undefined;
            _ = GetClientRect(hwnd, &client_rect);

            const border = getResizeBorderThickness();
            const titlebar_h = w.titlebar_height;

            // Resize borders (top, left, right, bottom, corners)
            const right_border: i32 = 3; // Thin right border to avoid scrollbar conflict
            if (IsZoomed(hwnd) == 0) { // not maximized
                if (pt.y < border) {
                    if (pt.x < border) return HTTOPLEFT;
                    if (pt.x >= client_rect.right - right_border) return HTTOPRIGHT;
                    return HTTOP;
                }
                if (pt.y >= client_rect.bottom - border) {
                    if (pt.x < border) return HTBOTTOMLEFT;
                    if (pt.x >= client_rect.right - right_border) return HTBOTTOMRIGHT;
                    return HTBOTTOM;
                }
                if (pt.x < border) return HTLEFT;
                if (pt.x >= client_rect.right - right_border) return HTRIGHT;
            }

            // Title bar area
            if (pt.y < titlebar_h) {
                // Caption buttons are on the right side (min/max/close)
                // Return HTMAXBUTTON for the maximize button area to enable
                // Windows 11 snap layouts
                const btn_width = getCaptionButtonWidth();
                if (pt.x >= client_rect.right - btn_width) {
                    const btn_zone = client_rect.right - pt.x;
                    if (btn_zone <= 46) return HTCLOSE;
                    if (btn_zone <= 92) return HTMAXBUTTON;
                    return HTMINBUTTON;
                }

                // App-handled settings button immediately left of caption buttons.
                if (pt.x >= client_rect.right - btn_width - 46 and pt.x < client_rect.right - btn_width) {
                    return HTCLIENT;
                }

                // The top bar no longer contains tabs. Only the left sidebar
                // toggle and settings button are client-handled; the rest is
                // draggable caption area.
                if (pt.x < 46) {
                    return HTCLIENT;
                }

                return HTCAPTION;
            }

            // Client area (terminal content)
            return HTCLIENT;
        },

        // --- Caption button hover tracking ---
        WM_NCMOUSEMOVE => {
            // wParam contains the HT value from WM_NCHITTEST
            w.hovered_button = switch (@as(LRESULT, @bitCast(wParam))) {
                HTCLOSE => .close,
                HTMAXBUTTON => .maximize,
                HTMINBUTTON => .minimize,
                else => .none,
            };

            // Mouse left client area — set position to -1 so + button hover clears
            w.mouse_x = -1;
            w.mouse_y = -1;

            // Request WM_NCMOUSELEAVE so we know when the mouse leaves
            var tme = TRACKMOUSEEVENT{
                .dwFlags = TME_LEAVE | TME_NONCLIENT,
                .hwndTrack = hwnd,
            };
            _ = TrackMouseEvent(&tme);

            return 0;
        },
        WM_NCLBUTTONDOWN => {
            // Record which caption button was pressed (action on mouse-up)
            const hit = @as(LRESULT, @bitCast(wParam));
            w.pressed_button = switch (hit) {
                HTCLOSE => .close,
                HTMAXBUTTON => .maximize,
                HTMINBUTTON => .minimize,
                else => .none,
            };
            if (w.pressed_button != .none) return 0;
            // For HTCAPTION etc., let DefWindowProc handle dragging
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        WM_NCMBUTTONDOWN => {
            // Eat it to prevent default behavior
            return 0;
        },
        WM_NCMBUTTONUP => {
            // Convert screen coords to client coords and push as middle-click release
            var pt = POINT{
                .x = @as(i16, @bitCast(@as(u16, @intCast(lParam & 0xFFFF)))),
                .y = @as(i16, @bitCast(@as(u16, @intCast((lParam >> 16) & 0xFFFF)))),
            };
            _ = ScreenToClient(hwnd, &pt);
            pushMouseButtonEvent(w, .middle, .release, pt.x, pt.y);
            return 0;
        },
        WM_NCLBUTTONUP => {
            const pressed = w.pressed_button;
            w.pressed_button = .none;

            // Only activate if mouse is still on the same button
            if (pressed == w.hovered_button) {
                switch (pressed) {
                    .close => {
                        w.should_close = true;
                        return 0;
                    },
                    .maximize => {
                        if (w.is_fullscreen) {
                            w.key_events.push(.{ .vk = VK_RETURN, .alt = false, .ctrl = true, .shift = false });
                        } else if (IsZoomed(hwnd) != 0) {
                            _ = ShowWindow(hwnd, SW_RESTORE);
                        } else {
                            _ = ShowWindow(hwnd, SW_MAXIMIZE);
                        }
                        return 0;
                    },
                    .minimize => {
                        _ = ShowWindow(hwnd, SW_MINIMIZE);
                        return 0;
                    },
                    .none => {},
                }
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        WM_NCMOUSELEAVE => {
            w.hovered_button = .none;
            return 0;
        },
        WM_MOUSELEAVE => {
            w.hovered_button = .none;
            return 0;
        },

        // --- Keyboard input ---
        WM_KEYDOWN, WM_SYSKEYDOWN => {
            const mods = getModifiers();
            w.key_events.push(.{
                .vk = wParam,
                .ctrl = mods.ctrl,
                .shift = mods.shift,
                .alt = mods.alt,
            });
            // Let DefWindowProc handle Alt+key for system menu, etc.
            if (msg == WM_SYSKEYDOWN) {
                // But suppress the beep for Alt+key combos we handle
                if (mods.alt and wParam == VK_RETURN) return 0;
            }
            return 0;
        },
        WM_CHAR => {
            // wParam is UTF-16 code unit from TranslateMessage
            const char_code: u16 = @intCast(wParam & 0xFFFF);
            // Skip control characters — those come through WM_KEYDOWN
            if (char_code >= 32) {
                const mods = getModifiers();
                w.char_events.push(.{
                    .codepoint = @intCast(char_code),
                    .ctrl = mods.ctrl,
                    .shift = mods.shift,
                    .alt = mods.alt,
                });
            }
            return 0;
        },

        // --- Mouse input ---
        WM_LBUTTONDOWN => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @intCast(lParam & 0xFFFF))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @intCast((lParam >> 16) & 0xFFFF))));

            // Titlebar clicks outside the sidebar toggle initiate window drag.
            const in_settings_button = blk: {
                var rect: RECT = undefined;
                _ = GetClientRect(hwnd, &rect);
                const btn_width = getCaptionButtonWidth();
                break :blk x >= rect.right - btn_width - 46 and x < rect.right - btn_width;
            };
            if (y < w.titlebar_height and x >= 46 and !in_settings_button) {
                _ = ReleaseCapture();
                _ = SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, lParam);
                return 0;
            }

            pushMouseButtonEvent(w, .left, .press, x, y);
            // Capture mouse so we get move events outside the window during drag
            _ = SetCapture(hwnd);
            return 0;
        },
        WM_LBUTTONDBLCLK => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @intCast(lParam & 0xFFFF))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @intCast((lParam >> 16) & 0xFFFF))));
            // Double-click in titlebar
            if (y < w.titlebar_height) {
                pushMouseButtonEvent(w, .left, .double_click, x, y);
                return 0;
            }
            if (w.sidebar_width > 0 and x >= 0 and x < w.sidebar_width) {
                pushMouseButtonEvent(w, .left, .double_click, x, y);
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        WM_LBUTTONUP => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @intCast(lParam & 0xFFFF))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @intCast((lParam >> 16) & 0xFFFF))));
            pushMouseButtonEvent(w, .left, .release, x, y);
            _ = ReleaseCapture();
            return 0;
        },
        WM_RBUTTONDOWN => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @intCast(lParam & 0xFFFF))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @intCast((lParam >> 16) & 0xFFFF))));
            pushMouseButtonEvent(w, .right, .press, x, y);
            return 0;
        },
        WM_RBUTTONUP => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @intCast(lParam & 0xFFFF))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @intCast((lParam >> 16) & 0xFFFF))));
            pushMouseButtonEvent(w, .right, .release, x, y);
            return 0;
        },
        WM_MBUTTONDOWN => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @intCast(lParam & 0xFFFF))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @intCast((lParam >> 16) & 0xFFFF))));
            pushMouseButtonEvent(w, .middle, .press, x, y);
            return 0;
        },
        WM_MBUTTONUP => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @intCast(lParam & 0xFFFF))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @intCast((lParam >> 16) & 0xFFFF))));
            pushMouseButtonEvent(w, .middle, .release, x, y);
            return 0;
        },
        WM_MOUSEMOVE => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @intCast(lParam & 0xFFFF))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @intCast((lParam >> 16) & 0xFFFF))));
            w.mouse_x = x;
            w.mouse_y = y;
            w.mouse_move_events.push(.{ .x = x, .y = y });
            return 0;
        },
        WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @intCast((wParam >> 16) & 0xFFFF)));
            // WM_MOUSEWHEEL gives screen coordinates in lParam, convert to client
            const screen_x: i16 = @bitCast(@as(u16, @intCast(lParam & 0xFFFF)));
            const screen_y: i16 = @bitCast(@as(u16, @intCast((lParam >> 16) & 0xFFFF)));
            var pt = POINT{ .x = screen_x, .y = screen_y };
            _ = ScreenToClient(hwnd, &pt);
            w.mouse_wheel_events.push(.{
                .delta = delta,
                .xpos = pt.x,
                .ypos = pt.y,
            });
            return 0;
        },

        else => {},
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}
