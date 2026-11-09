# -*- mode: python ; coding: utf-8 -*-
# Build script PyInstaller untuk MacDrive Rescue.

import os
import sys

block_cipher = None

base = os.path.abspath(os.getcwd())

a = Analysis(
    ["main.py"],
    pathex=[base],
    binaries=[],
    datas=[],
    hiddenimports=[
        "pyfsapfs",
        "pyfshfs",
        "tkinter",
        "tkinter.ttk",
        "tkinter.scrolledtext",
        "tkinter.filedialog",
        "tkinter.messagebox",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["numpy", "PIL", "pytest", "setuptools", "pip"],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name="MacDriveRescue",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    uac_admin=True,
    icon=None,
)