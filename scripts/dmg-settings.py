"""Finder layout for the branded installer. Loaded by dmgbuild, without Finder."""

import ctypes
import os
import plistlib
import struct
import subprocess

application = defines["app"]
background = defines["background"]
with open(os.path.join(application, "Contents", "Info.plist"), "rb") as info:
    icon_name = plistlib.load(info)["CFBundleIconFile"]
if not icon_name.endswith(".icns"):
    icon_name += ".icns"
icon = os.path.join(application, "Contents", "Resources", icon_name)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
# Do not use hide_extensions: SetFile adds FinderInfo to the signed bundle
# and causes codesign's strict resource validation to reject it.

# Point coordinates match render-dmg-background.swift, including its 2x image.
# Finder's title bar occupies up to 32 points in addition to the artwork.
window_rect = ((160, 160), (760, 532))
icon_locations = {"illogical.app": (204, 310), "Applications": (556, 310)}
icon_size = 104
text_size = 14
default_view = "icon-view"
arrange_by = None
label_pos = "bottom"
show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False


def create_hook(mount_point, settings):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                    os.path.join(mount_point, "illogical.app")], check=True)
    # HFS+ Finder info word 2 is the folder to open on mount. Set only that
    # word, preserving the volume ID and other metadata. `bless --openfolder`
    # no longer works on Apple Silicon. ATTR_VOL_INFO selects the volume
    # header rather than the root directory's com.apple.FinderInfo attribute.
    class AttrList(ctypes.Structure):
        _fields_ = [("count", ctypes.c_uint16), ("reserved", ctypes.c_uint16),
                    ("common", ctypes.c_uint32), ("volume", ctypes.c_uint32),
                    ("directory", ctypes.c_uint32), ("file", ctypes.c_uint32),
                    ("fork", ctypes.c_uint32)]

    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    for name in ("getattrlist", "setattrlist"):
        function = getattr(libc, name)
        function.argtypes = [ctypes.c_char_p, ctypes.POINTER(AttrList),
                             ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong]
        function.restype = ctypes.c_int
    attributes = AttrList(5, 0, 0x00004000, 0x80000000, 0, 0, 0)
    data = ctypes.create_string_buffer(36)  # length followed by eight words
    path = os.fsencode(mount_point)
    if libc.getattrlist(path, ctypes.byref(attributes), data, 36, 0):
        raise OSError(ctypes.get_errno(), "Cannot read DMG volume metadata")
    info = bytearray(data.raw[4:36])
    struct.pack_into(">I", info, 8, os.stat(mount_point).st_ino)
    output = ctypes.create_string_buffer(bytes(info), 32)
    if libc.setattrlist(path, ctypes.byref(attributes), output, 32, 0):
        raise OSError(ctypes.get_errno(), "Cannot set the DMG opening folder")
