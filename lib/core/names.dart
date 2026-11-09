/// Sanitasi nama file/folder macOS untuk NTFS.
///
/// Aturan:
///  - Karakter terlarang NTFS: `< > : " / \ | ? *` dan kontrol 0-31.
///  - `:` (khas Mac) diganti `-` (dapat dikonfigurasi).
///  - Nama tidak boleh berakhir titik/spasi.
///  - Nama perangkat cadangan (CON, PRN, AUX, NUL, COM1-9, LPT1-9) diberi `_`.
///  - Panjang komponen <= 255 karakter UTF-16.
///  - Tabrakan nama ditangani ` (2)`, ` (3)`, ...
library;

const _illegal = {0x3C, 0x3E, 0x3A, 0x22, 0x2F, 0x5C, 0x7C, 0x3F, 0x2A};

const _reservedNames = {
  'CON', 'PRN', 'AUX', 'NUL',
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
};

const _maxComponent = 255;

/// Membersihkan satu komponen nama (bukan path).
String sanitizeComponent(
  String name, {
  String colonReplacement = '-',
}) {
  if (name.isEmpty) return '_';

  // Normalisasi Unicode ke NFC (HFS+ menyimpan NFD).
  var text = _normalizeNfc(name);

  final out = StringBuffer();
  for (final rune in text.runes) {
    if (rune == 0x3A) {
      out.write(colonReplacement);
    } else if (_illegal.contains(rune) || rune < 0x20) {
      out.write('_');
    } else {
      out.writeCharCode(rune);
    }
  }
  text = out.toString();

  // Buang titik/spasi di ujung.
  text = text.replaceAll(RegExp(r'[ .]+$'), '');
  if (text.isEmpty) text = '_';

  // Nama perangkat cadangan.
  final stem = text.split('.').first.toUpperCase();
  if (_reservedNames.contains(stem)) {
    text = '_$text';
  }

  // Batasi panjang, pertahankan ekstensi.
  if (text.length > _maxComponent) {
    final lastDot = text.lastIndexOf('.');
    if (lastDot > 0 && text.length - lastDot <= 17) {
      final ext = text.substring(lastDot);
      final keep = _maxComponent - ext.length;
      text = text.substring(0, keep) + ext;
    } else {
      text = text.substring(0, _maxComponent);
    }
  }
  return text;
}

/// Pastikan unik dalam satu folder (case-insensitive).
String uniqueName(String candidate, Set<String> takenLower) {
  if (takenLower.add(candidate.toLowerCase())) {
    return candidate;
  }
  final lastDot = candidate.lastIndexOf('.');
  final stem = lastDot > 0 ? candidate.substring(0, lastDot) : candidate;
  final ext = lastDot > 0 ? candidate.substring(lastDot) : '';
  var n = 2;
  while (true) {
    final suffix = ' ($n)';
    final test = '$stem$suffix$ext';
    if (takenLower.add(test.toLowerCase())) {
      return test;
    }
    n++;
  }
}

/// Normalisasi Unicode sederhana (dekomposisi + komposisi dasar).
/// Dart tidak punya akses langsung ke tabel NFC penuh, jadi kita hanya
/// menangani pola umum: menggabungkan karakter combining accent ke huruf
/// Latin yang sudah dikomposisikan bila memungkinkan.
///
/// Untuk kasus praktis (nama file sehari-hari), penggabungan ini cukup.
String _normalizeNfc(String input) {
  // Peta combining -> huruf dasar yang sudah dikomposisikan.
  const base = {
    0x0300: {
      'a': 'à', 'e': 'è', 'i': 'ì', 'o': 'ò', 'u': 'ù',
      'A': 'À', 'E': 'È', 'I': 'Ì', 'O': 'Ò', 'U': 'Ù',
    },
    0x0301: {
      'a': 'á', 'e': 'é', 'i': 'í', 'o': 'ó', 'u': 'ú',
      'A': 'Á', 'E': 'É', 'I': 'Í', 'O': 'Ó', 'U': 'Ú',
      'n': 'ń', 'N': 'Ń',
    },
    0x0302: {
      'a': 'â', 'e': 'ê', 'i': 'î', 'o': 'ô', 'u': 'û',
      'A': 'Â', 'E': 'Ê', 'I': 'Î', 'O': 'Ô', 'U': 'Û',
    },
    0x0303: {
      'a': 'ã', 'n': 'ñ', 'o': 'õ',
      'A': 'Ã', 'N': 'Ñ', 'O': 'Õ',
    },
    0x0308: {
      'a': 'ä', 'e': 'ë', 'i': 'ï', 'o': 'ö', 'u': 'ü', 'y': 'ÿ',
      'A': 'Ä', 'E': 'Ë', 'I': 'Ï', 'O': 'Ö', 'U': 'Ü',
    },
    0x030c: {
      'c': 'č', 's': 'š', 'z': 'ž',
      'C': 'Č', 'S': 'Š', 'Z': 'Ž',
    },
  };
  final runes = input.runes.toList();
  final out = <int>[];
  var i = 0;
  while (i < runes.length) {
    final current = runes[i];
    if (i + 1 < runes.length) {
      final next = runes[i + 1];
      final map = base[next];
      if (map != null && map.containsKey(String.fromCharCode(current))) {
        final composed = map[String.fromCharCode(current)]!;
        out.addAll(composed.runes);
        i += 2;
        continue;
      }
    }
    out.add(current);
    i++;
  }
  return String.fromCharCodes(out);
}
