"""Play/control Apple TV apps with the PC keyboard.

Opens a small window; while it has focus, key presses/releases are sent to the app running
on the Apple TV as HID keyboard-page (0x07) UDP packets (see sdk/atvremote.h).
Usage: python tools/atvkeys.py [host]    (default 192.168.0.101)
"""
import socket
import struct
import sys
import tkinter as tk

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.0.101"
PORT = 37777

USAGES = {
    "return": 0x28, "escape": 0x29, "backspace": 0x2A, "tab": 0x2B, "space": 0x2C,
    "minus": 0x2D, "equal": 0x2E, "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
    "control_l": 0xE0, "shift_l": 0xE1, "alt_l": 0xE2,
    "control_r": 0xE4, "shift_r": 0xE5, "alt_r": 0xE6,
}


def usage_for(keysym):
    k = keysym.lower()
    if len(k) == 1 and "a" <= k <= "z":
        return 0x04 + ord(k) - ord("a")
    if len(k) == 1 and "1" <= k <= "9":
        return 0x1E + ord(k) - ord("1")
    if k == "0":
        return 0x27
    return USAGES.get(k)


sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)


def send(event, down):
    u = usage_for(event.keysym)
    if u is not None:
        sock.sendto(struct.pack("<III", 0x07, u, down), (HOST, PORT))
    return "break"  # keep Alt/Tab etc. from acting on the window


assert usage_for("A") == 0x04 and usage_for("0") == 0x27 and usage_for("Control_L") == 0xE0

root = tk.Tk()
root.title(f"ATV keys -> {HOST}")
tk.Label(root, padx=20, pady=20, justify="left", text=(
    f"Sending keys to {HOST}:{PORT}\n\n"
    "Doom: arrows move, Ctrl fire, Space use, Shift run,\n"
    "Alt strafe, 1-7 weapons, Esc menu, Enter select, Tab map")).pack()
root.bind("<KeyPress>", lambda e: send(e, 1))
root.bind("<KeyRelease>", lambda e: send(e, 0))
root.mainloop()
