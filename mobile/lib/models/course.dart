class MoodleItem {
  final String id;
  final int courseId;
  final String title;
  final String section;
  final String type; // 'file', 'assignment', 'forum', 'link', 'page'
  final String url;
  final String fileName;
  final bool downloadable;
  int sizeBytes;
  bool isDownloaded;
  bool isNew;
  String? localPath;
  bool isSelected;

  MoodleItem({
    required this.id,
    required this.courseId,
    required this.title,
    required this.section,
    required this.type,
    required this.url,
    required this.fileName,
    required this.downloadable,
    this.sizeBytes = 0,
    this.isDownloaded = false,
    this.isNew = true,
    this.localPath,
    this.isSelected = false,
  });

  String get formattedSize => formatFileSize(sizeBytes);

  String get typeLabel {
    switch (type) {
      case 'file':
        return 'Archivo';
      case 'assignment':
        return 'Tarea';
      case 'forum':
        return 'Foro';
      case 'link':
        return 'Enlace';
      case 'page':
        return 'Página';
      default:
        return 'Recurso';
    }
  }

  static String formatFileSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class MoodleCourse {
  final int id;
  final String fullname;
  final String cleanName;
  final String shortname;
  final String url;
  String obsidianFolder;
  String targetSubfolder;
  bool organizeBySection;
  List<MoodleItem> items;
  bool isLoadingContents;
  String? scanError;

  MoodleCourse({
    required this.id,
    required this.fullname,
    required this.cleanName,
    required this.shortname,
    required this.url,
    required this.obsidianFolder,
    this.targetSubfolder = 'Aula',
    this.organizeBySection = true,
    List<MoodleItem>? items,
    this.isLoadingContents = false,
    this.scanError,
  }) : items = items ?? [];

  int get downloadableCount => items.where((i) => i.downloadable).length;

  int get newFilesCount =>
      items.where((i) => i.downloadable && !i.isDownloaded).length;

  static String cleanCourseName(String raw) {
    var s = raw.trim();
    // 1. Remover prefijos de año/semestre: (202602), [2026-2]
    s = s.replaceAll(RegExp(r'^\s*[\(\[]\s*\d{4,6}[A-Za-z0-9\-_]*\s*[\)\]]'), '');
    // 2. Remover códigos/siglas: (INF266), (INF-266)
    s = s.replaceAll(
      RegExp(r'^\s*[\(\[]\s*[A-Za-z]{2,5}\s*-?\s*\d{2,4}[A-Za-z0-9]*\s*[\)\]]'),
      '',
    );
    // 3. Remover paralelos: |Paralelos:200/201, - Paralelo 1
    s = s.replaceAll(
      RegExp(
        r'[\s\|\-_]+(?:Paralelos?|paralelos?|PARALELOS?)\s*[:_\-]?\s*[\d\/\-_A-Za-z]+.*$',
      ),
      '',
    );
    s = s.replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'^[\s\|\-_]+|[\s\|\-_]+$'), '');

    if (s.isEmpty) return raw.trim();

    if (s == s.toUpperCase()) {
      final words = s.toLowerCase().split(' ');
      const lowerWords = {
        'de',
        'del',
        'y',
        'e',
        'en',
        'el',
        'la',
        'los',
        'las',
        'un',
        'una',
        'por',
        'para',
        'al',
        'con',
      };
      final res = words.asMap().entries.map((entry) {
        final w = entry.value;
        if (w.isEmpty) return '';
        if (entry.key == 0 || !lowerWords.contains(w)) {
          return '${w[0].toUpperCase()}${w.substring(1)}';
        }
        return w;
      }).join(' ');
      return res.isNotEmpty ? res : raw;
    }
    return s;
  }

  static String sanitizeFileName(String name) {
    var clean = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    clean = clean.replaceAll(RegExp(r'\s+'), ' ').trim();
    while (clean.endsWith('.')) {
      clean = clean.substring(0, clean.length - 1).trim();
    }
    return clean.isEmpty ? 'Archivo_Aula' : clean;
  }

  static String normalizeForMatch(String input) {
    const map = {
      'á': 'a',
      'à': 'a',
      'ä': 'a',
      'â': 'a',
      'é': 'e',
      'è': 'e',
      'ë': 'e',
      'ê': 'e',
      'í': 'i',
      'ì': 'i',
      'ï': 'i',
      'î': 'i',
      'ó': 'o',
      'ò': 'o',
      'ö': 'o',
      'ô': 'o',
      'ú': 'u',
      'ù': 'u',
      'ü': 'u',
      'û': 'u',
      'ñ': 'n',
    };
    final lower = input.toLowerCase();
    final sb = StringBuffer();
    for (var i = 0; i < lower.length; i++) {
      final ch = lower[i];
      sb.write(map[ch] ?? ch);
    }
    return sb.toString();
  }
}
