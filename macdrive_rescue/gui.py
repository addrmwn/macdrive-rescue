"""GUI MacDrive Rescue - transfer data drive Mac ke Windows tanpa MacDrive.

Aplikasi membaca partisi APFS/HFS+ langsung dari disk fisik (raw), sehingga
tidak terpengaruh driver MacDrive yang trial-nya habis atau rusak.
"""

from __future__ import annotations

import ctypes
import os
import queue
import subprocess
import sys
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from tkinter.scrolledtext import ScrolledText

from . import discovery, engine, rawdisk
from .fsmac import MacVolume
from .util import free_space, human_eta, human_size, human_speed

APP_TITLE = "MacDrive Rescue"
APP_TAGLINE = "Salin data drive Mac (APFS / HFS+) ke Windows"
APP_VERSION = "1.1"

# ---------------------------------------------------------------------------
# Palet warna (tema gelap yang nyaman dilihat)
# ---------------------------------------------------------------------------

BG = "#0f1117"          # latar aplikasi
CARD = "#171a23"        # latar kartu
CARD_INNER = "#1e2230"  # latar elemen di dalam kartu
BORDER = "#2a2f42"      # garis tepi
TEXT = "#e8eaf2"        # teks utama
MUTED = "#8b90a5"       # teks sekunder
ACCENT = "#4f8cff"      # biru aksi utama
ACCENT_DIM = "#2d4f96"  # biru redup (hover/tekan)
GREEN = "#3ddc84"
RED = "#ff5c5c"
YELLOW = "#ffc857"
WHITE = "#ffffff"

FONT = "Segoe UI"


# ---------------------------------------------------------------------------
# Elevasi UAC
# ---------------------------------------------------------------------------

def is_admin() -> bool:
    return rawdisk.is_admin()


def relaunch_as_admin() -> bool:
    """Luncurkan ulang aplikasi dengan hak Administrator. True bila berhasil."""
    try:
        if getattr(sys, "frozen", False):
            exe = sys.executable
            params = subprocess.list2cmdline(sys.argv[1:])
        else:
            exe = sys.executable
            params = subprocess.list2cmdline([os.path.abspath(sys.argv[0]), *sys.argv[1:]])
        rc = ctypes.windll.shell32.ShellExecuteW(None, "runas", exe, params, os.getcwd(), 1)
        return int(rc) > 32
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Komponen UI dasar
# ---------------------------------------------------------------------------

def styled_button(parent, text, command, primary=False, width=None):
    style = "Accent.TButton" if primary else "Secondary.TButton"
    btn = ttk.Button(parent, text=text, command=command, style=style, cursor="hand2")
    if width:
        btn.configure(width=width)
    return btn


class Card(tk.Frame):
    """Kartu berjudul dengan badge nomor langkah."""

    def __init__(self, parent, step: str, title: str, subtitle: str = ""):
        super().__init__(parent, bg=CARD, highlightbackground=BORDER,
                         highlightthickness=1, bd=0)
        head = tk.Frame(self, bg=CARD)
        head.pack(fill="x", padx=14, pady=(10, 0))
        if step:
            badge = tk.Label(
                head, text=step, bg=ACCENT, fg=WHITE, font=(FONT, 9, "bold"),
                width=3, pady=1,
            )
            badge.pack(side="left")
        tk.Label(
            head, text=title, bg=CARD, fg=TEXT, font=(FONT, 11, "bold")
        ).pack(side="left", padx=(10, 0))
        if subtitle:
            tk.Label(
                head, text=subtitle, bg=CARD, fg=MUTED, font=(FONT, 9)
            ).pack(side="left", padx=(10, 0))
        self.body = tk.Frame(self, bg=CARD)
        self.body.pack(fill="x", padx=14, pady=(8, 12))


def dark_label(parent, text="", muted=False, bold=False, size=10, bg=CARD):
    font = (FONT, size, "bold") if bold else (FONT, size)
    return tk.Label(parent, text=text, bg=bg, fg=MUTED if muted else TEXT, font=font)


# ---------------------------------------------------------------------------
# Dialog pilih folder di volume Mac
# ---------------------------------------------------------------------------

class MacFolderBrowser(tk.Toplevel):
    """Treeview lazy-load untuk menjelajahi volume Mac."""

    def __init__(self, parent, volume: MacVolume, start_entry=None):
        super().__init__(parent, bg=BG)
        self.title("Pilih folder sumber — %s" % volume.display_name)
        self.volume = volume
        self.result = None
        self.geometry("760x560")
        self.transient(parent)
        self.grab_set()

        self._nodes: dict[str, object] = {}

        head = tk.Frame(self, bg=BG)
        head.pack(fill="x", padx=16, pady=(14, 8))
        tk.Label(
            head, text="Pilih folder yang ingin disalin", bg=BG, fg=TEXT,
            font=(FONT, 13, "bold"),
        ).pack(anchor="w")
        tk.Label(
            head,
            text="Klik dua kali untuk membuka folder. Tekan \u201cSalin Folder Ini\u201d untuk memilih.",
            bg=BG, fg=MUTED, font=(FONT, 9),
        ).pack(anchor="w", pady=(2, 0))

        tree_wrap = tk.Frame(self, bg=CARD, highlightbackground=BORDER, highlightthickness=1)
        tree_wrap.pack(fill="both", expand=True, padx=16)

        self.tree = ttk.Treeview(
            tree_wrap, columns=("size",), selectmode="browse", style="Browser.Treeview"
        )
        self.tree.heading("#0", text="Nama", anchor="w")
        self.tree.heading("size", text="Ukuran", anchor="e")
        self.tree.column("#0", width=560, anchor="w")
        self.tree.column("size", width=120, anchor="e")
        vsb = ttk.Scrollbar(tree_wrap, orient="vertical", command=self.tree.yview,
                            style="Dark.Vertical.TScrollbar")
        self.tree.configure(yscrollcommand=vsb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        vsb.pack(side="right", fill="y")

        self.tree.bind("<<TreeviewOpen>>", self._on_open)
        self.tree.bind("<Double-1>", self._on_double)
        self.tree.bind("<Return>", lambda e: self._choose())

        root_entry = start_entry or volume.root
        root_text = "\U0001F4BE  %s (seluruh volume)" % volume.display_name
        root_id = self.tree.insert("", "end", text=root_text, values=("",), open=False)
        self._nodes[root_id] = root_entry
        self.tree.insert(root_id, "end", text="Memuat...")
        self._auto_expand(root_id)

        buttons = tk.Frame(self, bg=BG)
        buttons.pack(fill="x", padx=16, pady=14)
        styled_button(buttons, "Batal", self.destroy).pack(side="right")
        styled_button(buttons, "Salin Folder Ini", self._choose, primary=True).pack(
            side="right", padx=(0, 8)
        )

        self.bind("<Escape>", lambda e: self.destroy())

    def _auto_expand(self, iid):
        self.tree.item(iid, open=True)
        self._load_children(iid)

    def _on_open(self, _event=None):
        sel = self.tree.focus()
        if sel:
            self._load_children(sel)

    def _on_double(self, _event=None):
        sel = self.tree.focus()
        if not sel:
            return
        self._load_children(sel)
        self.tree.item(sel, open=not self.tree.item(sel, "open"))

    def _load_children(self, iid):
        entry = self._nodes.get(iid)
        if entry is None or not entry.is_dir:
            return
        children = self.tree.get_children(iid)
        if children and not all(self.tree.item(c, "text") == "Memuat..." for c in children):
            return
        for c in children:
            self.tree.delete(c)
        try:
            entries = self.volume.list_dir(entry)
        except Exception as exc:
            self.tree.insert(iid, "end", text="(gagal membaca: %s)" % exc)
            return
        dirs = sorted([e for e in entries if e.is_dir], key=lambda e: e.name.lower())
        files = sorted([e for e in entries if not e.is_dir], key=lambda e: e.name.lower())
        for e in dirs:
            child = self.tree.insert(iid, "end", text="\U0001F4C1  " + e.name, values=("",))
            self._nodes[child] = e
            self.tree.insert(child, "end", text="Memuat...")
        for e in files:
            child = self.tree.insert(
                iid, "end", text="\U0001F4C4  " + e.name, values=(human_size(e.size),)
            )
            self._nodes[child] = e

    def _choose(self):
        sel = self.tree.focus()
        if not sel and self.tree.selection():
            sel = self.tree.selection()[0]
        if not sel:
            self.destroy()
            return
        node = self._nodes.get(sel)
        if node is None:
            self.destroy()
            return
        if not node.is_dir:
            parent = self.tree.parent(sel)
            if parent:
                node = self._nodes.get(parent, node)
            self.result = node
        else:
            self.result = node
        self.destroy()


# ---------------------------------------------------------------------------
# Aplikasi utama
# ---------------------------------------------------------------------------

class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.configure(bg=BG)
        self.title("%s — %s" % (APP_TITLE, APP_TAGLINE))
        self.geometry("1100x900")
        self.minsize(960, 760)

        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except Exception:
            pass

        self.drives: list[discovery.MacDrive] = []
        self.current_volume: MacVolume | None = None
        self.source_entry = None
        self.source_label = tk.StringVar(value="Belum ada folder dipilih")
        self.source_path_var = tk.StringVar(value="")
        self.dest_var = tk.StringVar(
            value=os.path.join(os.path.expanduser("~"), "Documents", "Mac Transfer")
        )
        self.drive_var = tk.StringVar()
        self.status_var = tk.StringVar(value="Menyiapkan...")
        self.summary_var = tk.StringVar(value="Pilih folder sumber, lalu klik Pindai.")
        self.progress_var = tk.DoubleVar(value=0.0)
        self.progress_text = tk.StringVar(value="0%")
        self.speed_var = tk.StringVar(value="")
        self.eta_var = tk.StringVar(value="")
        self.current_file_var = tk.StringVar(value="")

        self.opts = {
            "skip_system": tk.BooleanVar(value=True),
            "skip_hidden": tk.BooleanVar(value=False),
            "skip_app_bundles": tk.BooleanVar(value=True),
            "skip_build_dirs": tk.BooleanVar(value=True),
            "verify": tk.BooleanVar(value=True),
            "preserve_times": tk.BooleanVar(value=True),
            "dry_run": tk.BooleanVar(value=False),
        }
        self.overwrite_var = tk.StringVar(value="skip")
        self.symlink_var = tk.StringVar(value="skip")
        self.colon_var = tk.StringVar(value="-")

        self.worker: threading.Thread | None = None
        self.cancel_event = threading.Event()
        self.events: queue.Queue = queue.Queue()
        self.scan_result: engine.ScanResult | None = None
        self.copy_stats: engine.CopyStats | None = None
        self._copy_bytes_done = 0
        self._copy_started = 0.0
        self._last_ui_update = 0.0
        self._scan_total_bytes = 0

        self._setup_style()
        self._build_ui()
        self.after(100, self._poll_events)

        if not is_admin():
            self._prompt_elevation()
        else:
            self._start_scan_drives()

    # ================================================================= tema
    def _setup_style(self):
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass

        style.configure(".", font=(FONT, 10), background=BG, foreground=TEXT)

        # Tombol utama
        style.configure(
            "Accent.TButton",
            background=ACCENT, foreground=WHITE, borderwidth=0,
            focusthickness=0, font=(FONT, 10, "bold"), padding=(16, 9),
        )
        style.map(
            "Accent.TButton",
            background=[("pressed", ACCENT_DIM), ("active", "#5f99ff"),
                        ("disabled", "#2a3040")],
            foreground=[("disabled", MUTED)],
        )

        # Tombol sekunder
        style.configure(
            "Secondary.TButton",
            background=CARD_INNER, foreground=TEXT, borderwidth=0,
            focusthickness=0, padding=(14, 8),
        )
        style.map(
            "Secondary.TButton",
            background=[("pressed", "#262b3d"), ("active", "#2b3145"),
                        ("disabled", "#181b25")],
            foreground=[("disabled", "#5a5f73")],
        )

        # Combobox gelap
        style.configure(
            "Dark.TCombobox",
            fieldbackground=CARD_INNER, background=CARD_INNER, foreground=TEXT,
            arrowcolor=MUTED, borderwidth=0, padding=6,
        )
        style.map(
            "Dark.TCombobox",
            fieldbackground=[("readonly", CARD_INNER), ("disabled", CARD)],
            foreground=[("readonly", TEXT), ("disabled", MUTED)],
            selectbackground=[("readonly", CARD_INNER)],
            selectforeground=[("readonly", TEXT)],
        )
        self.option_add("*TCombobox*Listbox.background", CARD_INNER)
        self.option_add("*TCombobox*Listbox.foreground", TEXT)
        self.option_add("*TCombobox*Listbox.selectBackground", ACCENT)
        self.option_add("*TCombobox*Listbox.selectForeground", WHITE)
        self.option_add("*TCombobox*Listbox.font", (FONT, 10))

        # Progress bar
        style.configure(
            "Accent.Horizontal.TProgressbar",
            troughcolor=CARD_INNER, background=ACCENT, borderwidth=0,
            thickness=14,
        )

        # Scrollbar gelap
        style.configure(
            "Dark.Vertical.TScrollbar",
            background=CARD_INNER, troughcolor=CARD, borderwidth=0,
            arrowcolor=MUTED,
        )
        style.map("Dark.Vertical.TScrollbar", background=[("active", "#2b3145")])

        # Treeview gelap (dialog browser)
        style.configure(
            "Browser.Treeview",
            background=CARD, fieldbackground=CARD, foreground=TEXT,
            rowheight=28, borderwidth=0, font=(FONT, 10),
        )
        style.configure(
            "Browser.Treeview.Heading",
            background=CARD_INNER, foreground=MUTED, borderwidth=0,
            font=(FONT, 9, "bold"), padding=(8, 6),
        )
        style.map(
            "Browser.Treeview",
            background=[("selected", ACCENT_DIM)],
            foreground=[("selected", WHITE)],
        )

        # Checkbutton & Radiobutton gelap
        for name in ("TCheckbutton", "TRadiobutton"):
            style.configure(
                name, background=CARD, foreground=TEXT, focuscolor=CARD,
                font=(FONT, 10),
            )
            style.map(
                name,
                background=[("active", CARD)],
                foreground=[("disabled", MUTED)],
                indicatorcolor=[("selected", ACCENT), ("!selected", CARD_INNER)],
            )

        style.configure(
            "TEntry",
            fieldbackground=CARD_INNER, foreground=TEXT, borderwidth=0,
            insertcolor=TEXT, padding=8,
        )
        style.map("TEntry", fieldbackground=[("disabled", CARD)])

    # ================================================================= UI
    def _build_ui(self):
        # ---------------- Header ----------------
        header = tk.Frame(self, bg="#12141d")
        header.pack(fill="x")
        inner = tk.Frame(header, bg="#12141d")
        inner.pack(fill="x", padx=22, pady=14)

        icon = tk.Label(
            inner, text="\U0001F4BE", bg=ACCENT, fg=WHITE, font=(FONT, 16),
            width=2, height=1,
        )
        icon.pack(side="left")
        titles = tk.Frame(inner, bg="#12141d")
        titles.pack(side="left", padx=(12, 0))
        tk.Label(
            titles, text=APP_TITLE, bg="#12141d", fg=TEXT, font=(FONT, 15, "bold")
        ).pack(anchor="w")
        tk.Label(
            titles, text=APP_TAGLINE, bg="#12141d", fg=MUTED, font=(FONT, 9)
        ).pack(anchor="w")

        badge_text = "Mode Administrator" if is_admin() else "Tanpa akses Administrator"
        badge_bg = "#173b26" if is_admin() else "#3b1f1f"
        badge_fg = GREEN if is_admin() else RED
        tk.Label(
            inner, text="  %s  " % badge_text, bg=badge_bg, fg=badge_fg,
            font=(FONT, 9, "bold"), pady=4,
        ).pack(side="right")

        accent_line = tk.Frame(self, bg=ACCENT, height=2)
        accent_line.pack(fill="x")

        # ---------------- Status bar (pack dulu agar selalu terlihat) ----------------
        status = tk.Frame(self, bg="#12141d")
        status.pack(fill="x", side="bottom")
        tk.Label(
            status, textvariable=self.status_var, bg="#12141d", fg=MUTED,
            font=(FONT, 9), anchor="w",
        ).pack(side="left", padx=16, pady=6)
        tk.Label(
            status, text="v%s" % APP_VERSION, bg="#12141d", fg="#4a4f63",
            font=(FONT, 8),
        ).pack(side="right", padx=16)

        # ---------------- Body ----------------
        body = tk.Frame(self, bg=BG)
        body.pack(fill="both", expand=True, padx=18, pady=12)

        # ---- Kartu 1: Sumber ----
        card1 = Card(body, "1", "Pilih data dari drive Mac",
                     "semua dibaca langsung dari disk — aman, read-only")
        card1.pack(fill="x")

        row = tk.Frame(card1.body, bg=CARD)
        row.pack(fill="x")
        dark_label(row, "Drive", muted=True, size=9).pack(side="left")
        self.drive_combo = ttk.Combobox(
            row, textvariable=self.drive_var, state="readonly", width=62,
            style="Dark.TCombobox", font=(FONT, 10),
        )
        self.drive_combo.pack(side="left", padx=(8, 8), ipady=2)
        self.drive_combo.bind("<<ComboboxSelected>>", self._on_drive_selected)
        self.rescan_btn = styled_button(
            row, "\u21BB  Pindai Ulang", self._start_scan_drives
        )
        self.rescan_btn.pack(side="left")

        source_box = tk.Frame(card1.body, bg=CARD_INNER)
        source_box.pack(fill="x", pady=(8, 0))
        left = tk.Frame(source_box, bg=CARD_INNER)
        left.pack(side="left", fill="x", expand=True, padx=12, pady=8)
        dark_label(left, "FOLDER SUMBER", muted=True, size=8, bg=CARD_INNER).pack(anchor="w")
        tk.Label(
            left, textvariable=self.source_label, bg=CARD_INNER, fg=ACCENT,
            font=(FONT, 11, "bold"),
        ).pack(anchor="w", pady=(1, 0))
        tk.Label(
            left, textvariable=self.source_path_var, bg=CARD_INNER, fg=MUTED,
            font=(FONT, 8), anchor="w", justify="left", wraplength=560,
        ).pack(anchor="w")

        btn_col = tk.Frame(source_box, bg=CARD_INNER)
        btn_col.pack(side="right", padx=10, pady=8)
        self.browse_btn = styled_button(
            btn_col, "Pilih Folder...", self._browse_folder, primary=True
        )
        self.browse_btn.pack(fill="x")
        styled_button(btn_col, "Seluruh Volume", self._use_whole_volume).pack(
            fill="x", pady=(6, 0)
        )

        # ---- Kartu 2: Tujuan ----
        card2 = Card(body, "2", "Simpan ke folder Windows",
                     "folder sumber akan muncul di dalam folder ini")
        card2.pack(fill="x", pady=(10, 0))

        drow = tk.Frame(card2.body, bg=CARD)
        drow.pack(fill="x")
        self.dest_entry = tk.Entry(
            drow, textvariable=self.dest_var, bg=CARD_INNER, fg=TEXT,
            insertbackground=TEXT, relief="flat", font=(FONT, 10),
            highlightthickness=1, highlightbackground=BORDER,
            highlightcolor=ACCENT,
        )
        self.dest_entry.pack(side="left", fill="x", expand=True, ipady=8, padx=(0, 8))
        styled_button(drow, "Telusuri...", self._browse_dest).pack(side="left")
        self.free_space_label = dark_label(card2.body, "", muted=True, size=9)
        self.free_space_label.pack(anchor="w", pady=(6, 0))
        self.dest_var.trace_add("write", lambda *a: self._update_free_space())
        self._update_free_space()

        # ---- Kartu 3: Opsi ----
        card3 = Card(body, "3", "Opsi penyalinan", "default sudah aman untuk kebanyakan orang")
        card3.pack(fill="x", pady=(10, 0))

        o1 = tk.Frame(card3.body, bg=CARD)
        o1.pack(fill="x")
        self._check(o1, "Lewati file sistem Mac (.DS_Store, ._*, .Trashes)",
                    self.opts["skip_system"]).pack(side="left")
        self._check(o1, "Lewati folder build/cache", self.opts["skip_build_dirs"]).pack(
            side="left", padx=(14, 0)
        )
        self._check(o1, "Lewati .app/.framework", self.opts["skip_app_bundles"]).pack(
            side="left", padx=(14, 0)
        )
        self._check(o1, "Verifikasi hash", self.opts["verify"]).pack(side="left", padx=(14, 0))
        self._check(o1, "Pertahankan tanggal", self.opts["preserve_times"]).pack(
            side="left", padx=(14, 0)
        )

        o2 = tk.Frame(card3.body, bg=CARD)
        o2.pack(fill="x", pady=(6, 0))
        dark_label(o2, "Jika file sudah ada", muted=True, size=9).pack(side="left")
        ttk.Combobox(
            o2, textvariable=self.overwrite_var, state="readonly", width=11,
            values=("skip", "overwrite", "rename"), style="Dark.TCombobox",
            font=(FONT, 9),
        ).pack(side="left", padx=(6, 14))
        dark_label(o2, "Karakter ':' jadi", muted=True, size=9).pack(side="left")
        ttk.Combobox(
            o2, textvariable=self.colon_var, state="readonly", width=5,
            values=("-", "_", "\uFF1A"), style="Dark.TCombobox", font=(FONT, 9),
        ).pack(side="left", padx=(6, 14))
        self._check(o2, "Lewati file tersembunyi", self.opts["skip_hidden"]).pack(side="left")
        self._check(o2, "Simulasi saja", self.opts["dry_run"]).pack(side="left", padx=(14, 0))

        # ---- Aksi ----
        act = tk.Frame(body, bg=BG)
        act.pack(fill="x", pady=(12, 0))
        self.scan_btn = styled_button(act, "Pindai Sumber", self._start_scan_source)
        self.scan_btn.pack(side="left")
        self.copy_btn = styled_button(act, "\u25B6  Mulai Transfer", self._start_copy, primary=True)
        self.copy_btn.pack(side="left", padx=(8, 0))
        self.cancel_btn = styled_button(act, "Batalkan", self._cancel)
        self.cancel_btn.pack(side="left", padx=(8, 0))
        self.open_dest_btn = styled_button(act, "Buka Folder Tujuan", self._open_dest)
        self.open_dest_btn.pack(side="right")

        # ---- Progress ----
        prog_card = tk.Frame(body, bg=CARD, highlightbackground=BORDER, highlightthickness=1)
        prog_card.pack(fill="x", pady=(12, 0))
        prog_inner = tk.Frame(prog_card, bg=CARD)
        prog_inner.pack(fill="x", padx=16, pady=12)

        top = tk.Frame(prog_inner, bg=CARD)
        top.pack(fill="x")
        self.summary_label = tk.Label(
            top, textvariable=self.summary_var, bg=CARD, fg=TEXT, font=(FONT, 10, "bold")
        )
        self.summary_label.pack(side="left")
        tk.Label(
            top, textvariable=self.progress_text, bg=CARD, fg=ACCENT, font=(FONT, 10, "bold")
        ).pack(side="right")

        self.progress = ttk.Progressbar(
            prog_inner, variable=self.progress_var, maximum=100.0,
            style="Accent.Horizontal.TProgressbar",
        )
        self.progress.pack(fill="x", pady=(8, 6))

        bottom = tk.Frame(prog_inner, bg=CARD)
        bottom.pack(fill="x")
        tk.Label(
            bottom, textvariable=self.current_file_var, bg=CARD, fg=MUTED,
            font=(FONT, 8), anchor="w",
        ).pack(side="left", fill="x", expand=True)
        tk.Label(
            bottom, textvariable=self.speed_var, bg=CARD, fg=MUTED, font=(FONT, 9)
        ).pack(side="right", padx=(12, 0))
        tk.Label(
            bottom, textvariable=self.eta_var, bg=CARD, fg=MUTED, font=(FONT, 9)
        ).pack(side="right", padx=(12, 0))

        # ---- Log ----
        log_wrap = tk.Frame(body, bg=CARD, highlightbackground=BORDER, highlightthickness=1)
        log_wrap.pack(fill="both", expand=True, pady=(10, 0))
        log_head = tk.Frame(log_wrap, bg=CARD)
        log_head.pack(fill="x", padx=14, pady=(8, 0))
        dark_label(log_head, "Aktivitas", bold=True, size=9).pack(side="left")
        self.log = ScrolledText(
            log_wrap, height=7, state="disabled", wrap="none", bg="#12141d",
            fg="#b8bdd0", insertbackground=TEXT, relief="flat",
            font=("Consolas", 9), padx=10, pady=6, borderwidth=0,
        )
        self.log.pack(fill="both", expand=True, padx=8, pady=(4, 8))
        self.log.tag_configure("error", foreground=RED)
        self.log.tag_configure("warn", foreground=YELLOW)
        self.log.tag_configure("ok", foreground=GREEN)

    def _check(self, parent, text, variable):
        return ttk.Checkbutton(parent, text=text, variable=variable, cursor="hand2")

    # ================================================================ utils
    def _log(self, text: str, tag: str | None = None):
        self.log.configure(state="normal")
        self.log.insert("end", time.strftime("[%H:%M:%S] ") + text + "\n", tag or ())
        self.log.see("end")
        self.log.configure(state="disabled")

    def _update_free_space(self):
        dest = self.dest_var.get().strip()
        if not dest:
            self.free_space_label.configure(text="")
            return
        drive = os.path.splitdrive(os.path.abspath(dest))[0]
        free = free_space(dest)
        if free >= 0:
            self.free_space_label.configure(
                text="Ruang tersedia di %s: %s" % (drive or dest, human_size(free))
            )

    def _open_dest(self):
        dest = self.dest_var.get().strip()
        if not dest:
            return
        try:
            os.makedirs(dest, exist_ok=True)
            os.startfile(dest)
        except OSError as exc:
            messagebox.showerror(APP_TITLE, "Tidak bisa membuka folder:\n%s" % exc)

    # ========================================================== elevasi UAC
    def _prompt_elevation(self):
        answer = messagebox.askyesno(
            APP_TITLE,
            "Aplikasi ini membutuhkan hak Administrator untuk membaca disk Mac\n"
            "secara langsung (melewati driver MacDrive).\n\n"
            "Luncurkan ulang sebagai Administrator sekarang?",
        )
        if answer:
            if relaunch_as_admin():
                self.destroy()
                return
            messagebox.showerror(APP_TITLE, "Gagal meminta hak Administrator.")
        self.status_var.set("Berjalan tanpa hak Administrator - drive Mac tidak bisa dibaca.")
        self._log(
            "PERINGATAN: tanpa hak Administrator, pembacaan disk mentah akan gagal.",
            "warn",
        )

    # ========================================================== deteksi drive
    def _start_scan_drives(self):
        if not is_admin():
            self._prompt_elevation()
            return
        self.current_volume = None
        self.source_entry = None
        for d in self.drives:
            try:
                d.close()
            except Exception:
                pass
        self.drives = []
        self.status_var.set("Memindai drive Mac...")
        self.rescan_btn.configure(state="disabled")
        threading.Thread(target=self._scan_drives_worker, daemon=True).start()

    def _scan_drives_worker(self):
        try:
            drives = discovery.scan_mac_drives()
            self.events.put(("drives", drives, None))
        except Exception as exc:
            self.events.put(("drives_error", str(exc), None))
        finally:
            self.events.put(("rescan_done", None, None))

    def _on_drives_found(self, drives: list[discovery.MacDrive]):
        self.drives = drives
        usable = [d for d in drives if d.is_usable]
        unusable = [d for d in drives if not d.is_usable]

        self.drive_combo["values"] = [d.label for d in usable]
        if usable:
            self._log("Ditemukan %d drive Mac yang bisa dibaca." % len(usable), "ok")
        else:
            self._log("Tidak ada drive Mac yang bisa dibaca.", "warn")
        for d in unusable:
            self._log("Tidak bisa dipakai: %s" % d.label, "warn")

        if usable:
            self.drive_combo.current(0)
            self._on_drive_selected()
        else:
            self.drive_var.set("")
            self.status_var.set(
                "Tidak ada drive Mac terdeteksi. Pastikan drive Mac terpasang, lalu klik Pindai Ulang."
            )

    def _on_drive_selected(self, _event=None):
        idx = self.drive_combo.current()
        usable = [d for d in self.drives if d.is_usable]
        if idx < 0 or idx >= len(usable):
            return
        drive = usable[idx]
        self.current_volume = None
        self.source_entry = None
        self.scan_result = None
        if drive.volume is not None and not drive.error:
            self.current_volume = drive.volume
            self.source_entry = drive.volume.root
            self._set_source_display(
                drive.volume.display_name,
                "Seluruh isi volume akan disalin ke folder tujuan",
            )
            self.browse_btn.configure(state="normal")
            self.status_var.set("Drive siap: %s" % drive.volume.display_name)
            self._log(
                "Drive dibuka: %s (%s)" % (drive.volume.display_name, drive.fs_kind)
            )
        else:
            self._set_source_display("(tidak bisa dibuka)", drive.error or "")
            self.browse_btn.configure(state="disabled")
        self.summary_var.set("Pilih folder sumber, lalu klik Pindai.")

    def _set_source_display(self, name: str, path: str):
        self.source_label.set(name)
        self.source_path_var.set(path)

    def _browse_folder(self):
        if not self.current_volume:
            return
        dlg = MacFolderBrowser(self, self.current_volume, self.source_entry)
        self.wait_window(dlg)
        if dlg.result is not None:
            self.source_entry = dlg.result
            self.scan_result = None
            if self.current_volume.is_root(dlg.result):
                self._set_source_display(
                    self.current_volume.display_name,
                    "Seluruh isi volume akan disalin ke folder tujuan",
                )
            else:
                self._set_source_display(
                    dlg.result.name,
                    "Folder %s akan muncul langsung di dalam folder tujuan" % dlg.result.name,
                )
            self._log("Folder sumber dipilih: %s" % dlg.result.name)
            self._start_scan_source()

    def _use_whole_volume(self):
        if self.current_volume:
            self.source_entry = self.current_volume.root
            self._set_source_display(
                self.current_volume.display_name,
                "Seluruh isi volume akan disalin ke folder tujuan",
            )
            self.scan_result = None
            self.summary_var.set("Sumber diubah — klik Pindai Sumber.")

    def _browse_dest(self):
        initial = self.dest_var.get()
        directory = filedialog.askdirectory(
            title="Pilih folder tujuan di Windows",
            initialdir=initial if os.path.isdir(initial) else os.path.expanduser("~"),
        )
        if directory:
            self.dest_var.set(os.path.normpath(directory))

    # ================================================================ scan
    def _make_options(self) -> engine.Options:
        return engine.Options(
            skip_system=self.opts["skip_system"].get(),
            skip_hidden=self.opts["skip_hidden"].get(),
            skip_app_bundles=self.opts["skip_app_bundles"].get(),
            skip_build_dirs=self.opts["skip_build_dirs"].get(),
            overwrite=self.overwrite_var.get(),
            verify=self.opts["verify"].get(),
            preserve_times=self.opts["preserve_times"].get(),
            symlinks=self.symlink_var.get(),
            colon_replacement=self.colon_var.get(),
            dry_run=self.opts["dry_run"].get(),
        )

    def _start_scan_source(self):
        if not self.current_volume or self.source_entry is None:
            messagebox.showwarning(APP_TITLE, "Pilih drive dan folder sumber terlebih dahulu.")
            return
        if self.worker and self.worker.is_alive():
            return
        self.scan_result = None
        self.cancel_event.clear()

        self.status_var.set("Menghitung file...")
        self.summary_var.set("Menghitung file...")
        self.scan_btn.configure(state="disabled")
        self.copy_btn.configure(state="disabled")
        self.cancel_btn.configure(state="normal")
        self.progress_var.set(0)
        self.progress_text.set("0%")

        volume = self.current_volume
        start = self.source_entry
        opts = self._make_options()

        def worker():
            try:
                scanner = engine.Scanner(
                    volume,
                    opts,
                    on_progress=lambda phase, n, total: self.events.put(
                        ("scan_progress", n, total)
                    ),
                    cancel=self.cancel_event,
                )
                result = scanner.scan(start)
                self.events.put(("scan_done", result, opts))
            except Exception as exc:
                self.events.put(("scan_error", str(exc), None))

        self.worker = threading.Thread(target=worker, daemon=True)
        self.worker.start()

    def _on_scan_done(self, result: engine.ScanResult, opts: engine.Options):
        self.scan_result = result
        self.scan_btn.configure(state="normal")
        self.cancel_btn.configure(state="disabled")
        self.copy_btn.configure(state="normal" if (result.files or result.dirs) else "disabled")
        if result.cancelled:
            self.status_var.set("Penghitungan dibatalkan.")
            self.summary_var.set("Penghitungan dibatalkan.")
            self._log("Penghitungan dibatalkan.", "warn")
            return
        self.status_var.set("Siap menyalin.")
        self.summary_var.set(
            "%d file · %d folder · %s"
            % (len(result.files), len(result.dirs), human_size(result.total_bytes))
        )
        self._log(
            "Siap: %d file, %d folder, total %s."
            % (len(result.files), len(result.dirs), human_size(result.total_bytes)),
            "ok",
        )
        if result.skipped_files or result.skipped_dirs:
            self._log(
                "Dilewati otomatis: %d file dan %d folder sistem/build."
                % (result.skipped_files, result.skipped_dirs)
            )
        for item in result.unreadable[:20]:
            self._log("Tidak bisa dibaca: %s" % item, "warn")
        if len(result.unreadable) > 20:
            self._log("... dan %d item lain tidak bisa dibaca." % (len(result.unreadable) - 20), "warn")
        free = free_space(self.dest_var.get())
        if free >= 0 and result.total_bytes > free:
            self._log(
                "PERINGATAN: ukuran data (%s) melebihi ruang tujuan (%s)."
                % (human_size(result.total_bytes), human_size(free)),
                "warn",
            )

    # ================================================================ copy
    def _start_copy(self):
        if not self.scan_result or (not self.scan_result.files and not self.scan_result.dirs):
            messagebox.showwarning(APP_TITLE, "Klik Pindai Sumber terlebih dahulu.")
            return
        dest = self.dest_var.get().strip()
        if not dest:
            messagebox.showwarning(APP_TITLE, "Pilih folder tujuan terlebih dahulu.")
            return
        try:
            os.makedirs(dest, exist_ok=True)
        except OSError as exc:
            messagebox.showerror(APP_TITLE, "Tidak bisa membuat folder tujuan:\n%s" % exc)
            return

        if self.opts["dry_run"].get():
            if not messagebox.askyesno(
                APP_TITLE, "Simulasi aktif: tidak ada file yang benar-benar ditulis.\nLanjutkan?"
            ):
                return
        elif not messagebox.askyesno(
            APP_TITLE,
            "Mulai menyalin %d file (%s) ke:\n%s\n\nLanjutkan?"
            % (
                len(self.scan_result.files),
                human_size(self.scan_result.total_bytes),
                dest,
            ),
        ):
            return

        self.cancel_event.clear()
        self._copy_bytes_done = 0
        self._copy_started = time.time()
        self._scan_total_bytes = max(self.scan_result.total_bytes, 1)
        self.progress_var.set(0)
        self.progress_text.set("0%")
        self.speed_var.set("")
        self.eta_var.set("")
        self.current_file_var.set("")
        self.status_var.set("Menyalin data...")
        self.scan_btn.configure(state="disabled")
        self.copy_btn.configure(state="disabled")
        self.cancel_btn.configure(state="normal")
        self.rescan_btn.configure(state="disabled")
        self.browse_btn.configure(state="disabled")
        self._log("Mulai menyalin ke: %s" % dest)

        volume = self.current_volume
        scan = self.scan_result
        opts = self._make_options()

        def worker():
            try:
                copier = engine.Copier(
                    volume,
                    dest,
                    opts,
                    on_file=lambda payload: self.events.put(("copy_event", payload, None)),
                    cancel=self.cancel_event,
                )
                stats = copier.run(scan)
                stamp = time.strftime("%Y%m%d-%H%M%S")
                try:
                    report_dir = os.path.join(dest, "_laporan")
                    os.makedirs(report_dir, exist_ok=True)
                    engine.write_manifest(
                        os.path.join(report_dir, "manifest-transfer-%s.csv" % stamp), stats
                    )
                    if stats.errors:
                        engine.write_error_report(
                            os.path.join(report_dir, "error-transfer-%s.csv" % stamp), stats
                        )
                except OSError:
                    pass
                self.events.put(("copy_done", stats, None))
            except Exception as exc:
                self.events.put(("copy_error", str(exc), None))

        self.worker = threading.Thread(target=worker, daemon=True)
        self.worker.start()

    def _on_copy_event(self, payload: dict):
        kind = payload.get("kind")
        if kind == "progress":
            self._copy_bytes_done += payload.get("bytes", 0)
            now = time.time()
            if now - self._last_ui_update < 0.15:
                return
            self._last_ui_update = now
            pct = min(100.0, self._copy_bytes_done * 100.0 / self._scan_total_bytes)
            self.progress_var.set(pct)
            self.progress_text.set("%.1f%%" % pct)
            elapsed = max(now - self._copy_started, 0.001)
            speed = self._copy_bytes_done / elapsed
            self.speed_var.set(human_speed(speed))
            remain = self._scan_total_bytes - self._copy_bytes_done
            self.eta_var.set("Sisa " + human_eta(remain / speed if speed > 0 else None))
            self.current_file_var.set(payload.get("rel", ""))
        elif kind == "file":
            status = payload.get("status")
            rel = payload.get("rel", "")
            if status == "ok":
                if payload.get("index", 0) % 200 == 0:
                    self._log("Tersalin: %s" % rel)
            elif status == "error":
                self._log("GAGAL: %s — %s" % (rel, payload.get("error", "")), "error")
            elif status == "verify_fail":
                self._log("VERIFIKASI GAGAL: %s" % rel, "error")
            elif status == "dry":
                self._log("(simulasi) %s" % rel)

    def _on_copy_done(self, stats: engine.CopyStats):
        self.scan_btn.configure(state="normal")
        self.copy_btn.configure(state="normal")
        self.cancel_btn.configure(state="disabled")
        self.rescan_btn.configure(state="normal")
        self.browse_btn.configure(state="normal")
        self.current_file_var.set("")
        elapsed = max(stats.ended_at - stats.started_at, 0.001)
        if stats.cancelled:
            self.status_var.set("Transfer dibatalkan.")
            self._log("Transfer dibatalkan oleh pengguna.", "warn")
            messagebox.showwarning(APP_TITLE, "Transfer dibatalkan.")
            return
        self.progress_var.set(100.0)
        self.progress_text.set("100%")
        self.speed_var.set(human_speed(stats.bytes_copied / elapsed))
        self.eta_var.set("")
        self.status_var.set("Transfer selesai.")
        summary = (
            "Selesai: %d file tersalin (%s), %d dilewati, %d gagal."
            % (
                stats.files_copied,
                human_size(stats.bytes_copied),
                stats.files_skipped,
                stats.files_failed,
            )
        )
        self.summary_var.set(summary)
        self._log(summary, "ok")
        if stats.verify_failed:
            self._log("%d file gagal verifikasi hash!" % stats.verify_failed, "error")
        for rel, err in stats.errors[:50]:
            self._log("Error: %s — %s" % (rel, err), "error")
        if len(stats.errors) > 50:
            self._log(
                "... dan %d error lain (lihat CSV error di folder tujuan)."
                % (len(stats.errors) - 50),
                "error",
            )
        messagebox.showinfo(
            APP_TITLE,
            summary + "\n\nLaporan CSV disimpan di folder tujuan.",
        )

    # =========================================================== batalkan
    def _cancel(self):
        if self.worker and self.worker.is_alive():
            self.cancel_event.set()
            self.status_var.set("Membatalkan...")
            self._log("Permintaan pembatalan dikirim...", "warn")

    # ============================================================= events
    def _poll_events(self):
        try:
            while True:
                kind, payload, extra = self.events.get_nowait()
                if kind == "drives":
                    self._on_drives_found(payload)
                elif kind == "drives_error":
                    self._log("Gagal memindai disk: %s" % payload, "error")
                    self.status_var.set("Gagal memindai disk.")
                elif kind == "rescan_done":
                    self.rescan_btn.configure(state="normal")
                elif kind == "scan_progress":
                    self.summary_var.set(
                        "Menghitung file... %d file (%s)"
                        % (payload, human_size(extra or 0))
                    )
                elif kind == "scan_done":
                    self._on_scan_done(payload, extra)
                elif kind == "scan_error":
                    self.scan_btn.configure(state="normal")
                    self.cancel_btn.configure(state="disabled")
                    self.status_var.set("Gagal menghitung file.")
                    self._log("Gagal memindai: %s" % payload, "error")
                    messagebox.showerror(APP_TITLE, "Gagal memindai sumber:\n%s" % payload)
                elif kind == "copy_event":
                    self._on_copy_event(payload)
                elif kind == "copy_done":
                    self._on_copy_done(payload)
                elif kind == "copy_error":
                    self.scan_btn.configure(state="normal")
                    self.copy_btn.configure(state="normal")
                    self.cancel_btn.configure(state="disabled")
                    self.rescan_btn.configure(state="normal")
                    self.browse_btn.configure(state="normal")
                    self.status_var.set("Transfer gagal.")
                    self._log("Transfer gagal: %s" % payload, "error")
                    messagebox.showerror(APP_TITLE, "Transfer gagal:\n%s" % payload)
        except queue.Empty:
            pass
        self.after(100, self._poll_events)

    def destroy(self):
        self.cancel_event.set()
        for d in self.drives:
            try:
                d.close()
            except Exception:
                pass
        super().destroy()


def main():
    app = App()
    app.mainloop()


if __name__ == "__main__":
    main()