/*
 * launcher.c - bootstrap kecil untuk MacDriveRescue-Portable.exe
 *
 * Perilaku:
 *  1. Jika %LOCALAPPDATA%\MacDriveRescue\macdrive_rescue.exe sudah ada,
 *     langsung jalankan (tanpa ekstrak ulang) -> lokasi instalasi stabil
 *     sehingga self-update berfungsi.
 *  2. Jika belum ada, ekstrak payload ZIP yang ditempelkan di akhir file ini
 *     ke folder instalasi, lalu jalankan.
 *
 * Format paket (di akhir file):
 *   [8 byte payload offset][8 byte payload size][magic "MACFSZP1" 8 byte]
 *   Payload = arsip ZIP (dibuat oleh make_portable.ps1).
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define MAGIC "MACFSZP1"
#define TRAILER_SIZE 24

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
    if (source == INVALID_HANDLE_VALUE) {
        return 0;
    }
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
    DWORD got = 0;
    DWORD wrote = 0;
    while (remaining > 0) {
        DWORD chunk = (DWORD)(remaining > sizeof(buffer) ? sizeof(buffer) : remaining);
        if (!ReadFile(source, buffer, chunk, &got, NULL) || got == 0) {
            break;
        }
        if (!WriteFile(target, buffer, got, &wrote, NULL) || wrote != got) {
            break;
        }
        remaining -= got;
    }
    CloseHandle(target);
    CloseHandle(source);
    return remaining == 0;
}

static int extract_zip(const wchar_t *zip_path, const wchar_t *destination) {
    /* Windows 10 1803+ menyertakan bsdtar yang bisa mengekstrak zip. */
    wchar_t tar_path[MAX_PATH];
    GetSystemDirectoryW(tar_path, MAX_PATH);
    wcscat_s(tar_path, MAX_PATH, L"\\tar.exe");
    if (!file_exists(tar_path)) {
        return 0;
    }
    wchar_t command[32768];
    _snwprintf(command, 32768, L"\"%s\" -xf \"%s\" -C \"%s\"", tar_path, zip_path,
               destination);
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    ZeroMemory(&startup, sizeof(startup));
    ZeroMemory(&process, sizeof(process));
    startup.cb = sizeof(startup);
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL,
                        NULL, &startup, &process)) {
        return 0;
    }
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exit_code = 1;
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    return exit_code == 0;
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

    /* Baca trailer di akhir file. */
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

    /* Lokasi instalasi stabil. */
    const wchar_t *local_app_data = _wgetenv(L"LOCALAPPDATA");
    if (local_app_data == NULL || local_app_data[0] == L'\0') {
        launcher_fail(L"LOCALAPPDATA tidak ditemukan.");
        return 1;
    }
    wchar_t install_dir[MAX_PATH * 2];
    _snwprintf(install_dir, MAX_PATH * 2, L"%s\\MacDriveRescue", local_app_data);

    wchar_t exe_path[MAX_PATH * 2];
    _snwprintf(exe_path, MAX_PATH * 2, L"%s\\macdrive_rescue.exe", install_dir);

    /* Sudah terpasang? Langsung jalankan. */
    if (file_exists(exe_path)) {
        ShellExecuteW(NULL, L"open", exe_path, NULL, install_dir, SW_SHOWNORMAL);
        return 0;
    }

    /* Ekstrak payload. */
    SHCreateDirectoryExW(NULL, install_dir, NULL);

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
    if (!file_exists(exe_path)) {
        launcher_fail(L"Ekstraksi tidak lengkap (exe tidak ditemukan).");
        return 1;
    }
    ShellExecuteW(NULL, L"open", exe_path, NULL, install_dir, SW_SHOWNORMAL);
    return 0;
}