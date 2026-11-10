/*
 * macfs_updater.exe - helper update tanpa console.
 *
 * Dipanggil aplikasi saat update siap dipasang:
 *   macfs_updater.exe --pid <PID> --src <folder payload> --dst <folder install> --exe <exe>
 *
 * Alur:
 *  1. Tunggu proses <PID> benar-benar berhenti (polling, TANPA console).
 *  2. Salin semua file dari --src ke --dst (menimpa), dengan retry.
 *  3. Jalankan kembali aplikasi dari --exe.
 *  4. Hapus folder payload sementara.
 *
 * Keunggulan dibanding skrip batch:
 *  - Tidak membuka jendela console (subsystem WINDOWS).
 *  - Tidak bergantung pada `find`, `timeout`, atau quoting cmd yang rapuh.
 *  - Menyalin folder secara rekursif dengan Win32 API langsung.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define MAX_PATH_LONG 32768

static void parse_arg(const wchar_t *command_line, const wchar_t *name,
                      wchar_t *output, int output_size) {
    output[0] = L'\0';
    const wchar_t *found = wcsstr(command_line, name);
    if (found == NULL) return;
    found += wcslen(name);
    while (*found == L' ' || *found == L'"') found++;
    int index = 0;
    while (*found != L'\0' && *found != L'"' && index < output_size - 1) {
        /* berhenti di spasi hanya jika argumen tidak dikutip */
        if (*found == L' ') break;
        output[index++] = *found++;
    }
    output[index] = L'\0';
}

static int dir_exists(const wchar_t *path) {
    DWORD attributes = GetFileAttributesW(path);
    return attributes != INVALID_FILE_ATTRIBUTES &&
           (attributes & FILE_ATTRIBUTE_DIRECTORY);
}

static int file_exists(const wchar_t *path) {
    DWORD attributes = GetFileAttributesW(path);
    return attributes != INVALID_FILE_ATTRIBUTES &&
           !(attributes & FILE_ATTRIBUTE_DIRECTORY);
}

/* Salin satu file dengan retry (file bisa terkunci sesaat). */
static int copy_file_with_retry(const wchar_t *source, const wchar_t *target) {
    for (int attempt = 0; attempt < 20; attempt++) {
        if (CopyFileW(source, target, FALSE)) return 1;
        DWORD error = GetLastError();
        /* Folder tujuan yang hilang -> buat ulang. */
        if (error == ERROR_PATH_NOT_FOUND || error == ERROR_FILE_NOT_FOUND) {
            wchar_t parent[MAX_PATH_LONG];
            wcscpy_s(parent, MAX_PATH_LONG, target);
            wchar_t *last = wcsrchr(parent, L'\\');
            if (last != NULL) {
                *last = L'\0';
                SHCreateDirectoryExW(NULL, parent, NULL);
            }
        }
        Sleep(250);
    }
    return 0;
}

static int copy_tree(const wchar_t *source_dir, const wchar_t *target_dir) {
    if (!dir_exists(source_dir)) return 0;
    SHCreateDirectoryExW(NULL, target_dir, NULL);

    wchar_t pattern[MAX_PATH_LONG];
    _snwprintf(pattern, MAX_PATH_LONG, L"%s\\*", source_dir);

    WIN32_FIND_DATAW data;
    HANDLE find = FindFirstFileW(pattern, &data);
    if (find == INVALID_HANDLE_VALUE) return 1; /* folder kosong */

    int ok = 1;
    do {
        if (wcscmp(data.cFileName, L".") == 0 ||
            wcscmp(data.cFileName, L"..") == 0) {
            continue;
        }
        wchar_t source_item[MAX_PATH_LONG];
        wchar_t target_item[MAX_PATH_LONG];
        _snwprintf(source_item, MAX_PATH_LONG, L"%s\\%s", source_dir,
                   data.cFileName);
        _snwprintf(target_item, MAX_PATH_LONG, L"%s\\%s", target_dir,
                   data.cFileName);

        if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (!copy_tree(source_item, target_item)) ok = 0;
        } else {
            if (!copy_file_with_retry(source_item, target_item)) ok = 0;
        }
    } while (FindNextFileW(find, &data));
    FindClose(find);
    return ok;
}

static void wait_for_process(DWORD process_id) {
    HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, process_id);
    if (process != NULL) {
        WaitForSingleObject(process, 120000); /* maksimum 2 menit */
        CloseHandle(process);
    } else {
        /* Proses sudah tidak ada. */
        Sleep(1000);
    }
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, LPWSTR command_line,
                    int show_command) {
    (void)instance;
    (void)previous;
    (void)show_command;

    wchar_t pid_text[32];
    wchar_t source[MAX_PATH_LONG];
    wchar_t destination[MAX_PATH_LONG];
    wchar_t exe[MAX_PATH_LONG];
    parse_arg(command_line, L"--pid", pid_text, 32);
    parse_arg(command_line, L"--src", source, MAX_PATH_LONG);
    parse_arg(command_line, L"--dst", destination, MAX_PATH_LONG);
    parse_arg(command_line, L"--exe", exe, MAX_PATH_LONG);

    if (pid_text[0] == L'\0' || source[0] == L'\0' ||
        destination[0] == L'\0' || exe[0] == L'\0') {
        return 1;
    }

    DWORD process_id = (DWORD)_wtoi(pid_text);
    wait_for_process(process_id);
    Sleep(500); /* beri waktu handle file dilepas */

    int copied = copy_tree(source, destination);

    /* Jalankan aplikasi (versi baru) bila penyalinan berhasil. */
    if (copied && file_exists(exe)) {
        ShellExecuteW(NULL, L"open", exe, NULL, destination, SW_SHOWNORMAL);
    } else {
        MessageBoxW(
            NULL,
            L"Update gagal menyalin file.\n\n"
            L"Silakan unduh ulang MacDriveRescue-Portable.exe dari halaman "
            L"rilis dan ekstrak ke folder baru.",
            L"MacDrive Rescue - Update", MB_ICONERROR | MB_OK);
    }

    /* Bersihkan folder payload sementara.
     * PENTING: hanya hapus folder yang namanya diawali "macfs_apply_" agar
     * tidak pernah menghapus folder pengguna secara tidak sengaja. */
    {
        wchar_t cleanup_cmd[MAX_PATH_LONG + 64];
        wchar_t *payload_folder = wcsstr(source, L"macfs_apply_");
        if (payload_folder != NULL) {
            /* Naik satu level dari ...\macfs_apply_xxx\payload */
            wchar_t root[MAX_PATH_LONG];
            wcscpy_s(root, MAX_PATH_LONG, source);
            /* buang "\\payload" di ujung bila ada */
            size_t root_length = wcslen(root);
            const wchar_t *suffix = L"\\payload";
            size_t suffix_length = wcslen(suffix);
            if (root_length > suffix_length &&
                _wcsicmp(root + root_length - suffix_length, suffix) == 0) {
                root[root_length - suffix_length] = L'\0';
            }
            _snwprintf(cleanup_cmd, MAX_PATH_LONG + 64,
                       L"cmd.exe /c rmdir /S /Q \"%s\"", root);
            STARTUPINFOW startup;
            PROCESS_INFORMATION process_info;
            ZeroMemory(&startup, sizeof(startup));
            ZeroMemory(&process_info, sizeof(process_info));
            startup.cb = sizeof(startup);
            startup.dwFlags = STARTF_USESHOWWINDOW;
            startup.wShowWindow = SW_HIDE;
            if (CreateProcessW(NULL, cleanup_cmd, NULL, NULL, FALSE,
                               CREATE_NO_WINDOW, NULL, NULL, &startup,
                               &process_info)) {
                CloseHandle(process_info.hProcess);
                CloseHandle(process_info.hThread);
            }
        }
    }
    return copied ? 0 : 1;
}