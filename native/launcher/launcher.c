/*
 * launcher.c - bootstrap untuk MacDriveRescue-Portable.exe
 *
 * Perilaku:
 *  1. Verifikasi instalasi di %LOCALAPPDATA%\MacDriveRescue LENGKAP
 *     (exe + data\app.so + macfs.dll + marker versi).
 *  2. Bila tidak lengkap / versi berbeda -> ekstrak ulang payload (menimpa).
 *  3. Jalankan exe dari folder instalasi yang stabil (agar self-update jalan).
 *
 * Format paket (di akhir file):
 *   [payload ZIP][8B launcher size][8B payload size][magic "MACFSZP1"]
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlobj.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define MAGIC "MACFSZP1"
#define TRAILER_SIZE 24
#define VERSION_MARKER "version.txt"

static void launcher_fail(const wchar_t *message) {
    MessageBoxW(NULL, message, L"MacDrive Rescue", MB_ICONERROR | MB_OK);
}

static int file_exists(const wchar_t *path) {
    DWORD attributes = GetFileAttributesW(path);
    return attributes != INVALID_FILE_ATTRIBUTES &&
           !(attributes & FILE_ATTRIBUTE_DIRECTORY);
}

static int copy_payload(const wchar_t *self, uint64_t offset, uint64_t length,
                        const wchar_t *destination) {
    HANDLE source = CreateFileW(self, GENERIC_READ, FILE_SHARE_READ, NULL,
                                OPEN_EXISTING, 0, NULL);
    if (source == INVALID_HANDLE_VALUE) return 0;
    HANDLE target = CreateFileW(destination, GENERIC_WRITE, 0, NULL,
                                CREATE_ALWAYS, 0, NULL);
    if (target == INVALID_HANDLE_VALUE) {
        CloseHandle(source);
        return 0;
    }
    LARGE_INTEGER position;
    position.QuadPart = (LONGLONG)offset;
    SetFilePointerEx(source, position, NULL, FILE_BEGIN);

    char buffer[65536];
    uint64_t remaining = length;
    DWORD got = 0, wrote = 0;
    while (remaining > 0) {
        DWORD chunk = (DWORD)(remaining > sizeof(buffer) ? sizeof(buffer) : remaining);
        if (!ReadFile(source, buffer, chunk, &got, NULL) || got == 0) break;
        if (!WriteFile(target, buffer, got, &wrote, NULL) || wrote != got) break;
        remaining -= got;
    }
    CloseHandle(target);
    CloseHandle(source);
    return remaining == 0;
}

static int extract_zip(const wchar_t *zip_path, const wchar_t *destination) {
    wchar_t tar_path[MAX_PATH];
    GetSystemDirectoryW(tar_path, MAX_PATH);
    wcscat_s(tar_path, MAX_PATH, L"\\tar.exe");
    if (!file_exists(tar_path)) return 0;

    wchar_t command[32768];
    _snwprintf(command, 32768, L"\"%s\" -xf \"%s\" -C \"%s\"", tar_path,
               zip_path, destination);
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    ZeroMemory(&startup, sizeof(startup));
    ZeroMemory(&process, sizeof(process));
    startup.cb = sizeof(startup);
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, CREATE_NO_WINDOW,
                        NULL, NULL, &startup, &process)) {
        return 0;
    }
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exit_code = 1;
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    return exit_code == 0;
}

/* Instalasi dianggap lengkap bila semua file inti ada. */
static int install_is_complete(const wchar_t *install_dir,
                               const wchar_t *exe_path) {
    wchar_t probe[MAX_PATH * 2];

    if (!file_exists(exe_path)) return 0;

    _snwprintf(probe, MAX_PATH * 2, L"%s\\data\\app.so", install_dir);
    if (!file_exists(probe)) return 0;

    _snwprintf(probe, MAX_PATH * 2, L"%s\\flutter_windows.dll", install_dir);
    if (!file_exists(probe)) return 0;

    _snwprintf(probe, MAX_PATH * 2, L"%s\\macfs.dll", install_dir);
    if (!file_exists(probe)) return 0;

    _snwprintf(probe, MAX_PATH * 2, L"%s\\data\\icudtl.dat", install_dir);
    /* icudtl.dat opsional pada beberapa versi Flutter, abaikan bila tidak ada. */
    return 1;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, LPWSTR command_line,
                    int show_command) {
    (void)instance;
    (void)previous;
    (void)command_line;
    (void)show_command;

    wchar_t self[MAX_PATH];
    if (!GetModuleFileNameW(NULL, self, MAX_PATH)) {
        launcher_fail(L"Tidak bisa menentukan lokasi launcher.");
        return 1;
    }

    /* Baca trailer. */
    HANDLE package = CreateFileW(self, GENERIC_READ, FILE_SHARE_READ, NULL,
                                 OPEN_EXISTING, 0, NULL);
    if (package == INVALID_HANDLE_VALUE) {
        launcher_fail(L"Tidak bisa membuka paket.");
        return 1;
    }
    LARGE_INTEGER size;
    GetFileSizeEx(package, &size);
    if (size.QuadPart < TRAILER_SIZE) {
        CloseHandle(package);
        launcher_fail(L"Paket tidak valid (terlalu kecil).");
        return 1;
    }
    unsigned char trailer[TRAILER_SIZE];
    DWORD got = 0;
    LARGE_INTEGER trailer_position;
    trailer_position.QuadPart = size.QuadPart - TRAILER_SIZE;
    SetFilePointerEx(package, trailer_position, NULL, FILE_BEGIN);
    ReadFile(package, trailer, TRAILER_SIZE, &got, NULL);
    CloseHandle(package);
    if (got != TRAILER_SIZE || memcmp(trailer + 16, MAGIC, 8) != 0) {
        launcher_fail(L"Paket tidak valid (magic tidak cocok).");
        return 1;
    }
    uint64_t payload_offset = 0;
    uint64_t payload_size = 0;
    memcpy(&payload_offset, trailer, 8);
    memcpy(&payload_size, trailer + 8, 8);

    const wchar_t *local_app_data = _wgetenv(L"LOCALAPPDATA");
    if (local_app_data == NULL || local_app_data[0] == L'\0') {
        launcher_fail(L"LOCALAPPDATA tidak ditemukan.");
        return 1;
    }
    wchar_t install_dir[MAX_PATH * 2];
    _snwprintf(install_dir, MAX_PATH * 2, L"%s\\MacDriveRescue", local_app_data);

    wchar_t exe_path[MAX_PATH * 2];
    _snwprintf(exe_path, MAX_PATH * 2, L"%s\\macdrive_rescue.exe", install_dir);

    /* Instalasi lengkap -> langsung jalankan. */
    if (install_is_complete(install_dir, exe_path)) {
        ShellExecuteW(NULL, L"open", exe_path, NULL, install_dir, SW_SHOWNORMAL);
        return 0;
    }

    /* Tidak lengkap / rusak -> ekstrak ulang (timpa). */
    if (!CreateDirectoryW(install_dir, NULL)) {
        DWORD error = GetLastError();
        if (error != ERROR_ALREADY_EXISTS) {
            launcher_fail(L"Tidak bisa membuat folder instalasi.");
            return 1;
        }
    }

    wchar_t temp_dir[MAX_PATH];
    wchar_t zip_path[MAX_PATH];
    if (GetTempPathW(MAX_PATH, temp_dir) == 0 ||
        GetTempFileNameW(temp_dir, L"mfs", 0, zip_path) == 0) {
        launcher_fail(L"Tidak bisa membuat file sementara.");
        return 1;
    }
    if (!copy_payload(self, payload_offset, payload_size, zip_path)) {
        DeleteFileW(zip_path);
        launcher_fail(L"Gagal menulis payload.");
        return 1;
    }
    int extracted = extract_zip(zip_path, install_dir);
    DeleteFileW(zip_path);
    if (!extracted) {
        launcher_fail(L"Gagal mengekstrak paket.");
        return 1;
    }

    /* Verifikasi ulang setelah ekstrak. */
    if (!install_is_complete(install_dir, exe_path)) {
        launcher_fail(
            L"Ekstraksi tidak lengkap (data aplikasi tidak ditemukan).\n\n"
            L"Hapus folder:\n%LOCALAPPDATA%\\MacDriveRescue\nlalu jalankan "
            L"kembali file ini.");
        return 1;
    }

    ShellExecuteW(NULL, L"open", exe_path, NULL, install_dir, SW_SHOWNORMAL);
    return 0;
}