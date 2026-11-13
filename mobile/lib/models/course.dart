class MoodleItem {
  final String id;
  final int courseId;
  final String title;
  final String section;
  final String type; // 'file', 'assignment', 'quiz', 'forum', 'link', 'page'
  final String url;
  final String fileName;
  final String fileExt;
  final bool downloadable;
  int sizeBytes;
  bool isDownloaded;
  bool isNew;
  String? localPath;
  bool isSelected;
  int? dueTimestamp;
  String dueText;

  MoodleItem({
    required this.id,
    required this.courseId,
    required this.title,
    required this.section,
    required this.type,
    required this.url,
    required this.fileName,
    this.fileExt = '',
    required this.downloadable,
    this.sizeBytes = 0,
    this.isDownloaded = false,
    this.isNew = true,
    this.localPath,
    this.isSelected = false,
    this.dueTimestamp,
    this.dueText = '',
  });

  String get effectiveExt {
    if (fileExt.isNotEmpty) return fileExt.toLowerCase();
    final candidate = fileName.contains('.') ? fileName : title;
    final dot = candidate.lastIndexOf('.');
    if (dot != -1 && dot < candidate.length - 1) {
      final ext = candidate.substring(dot + 1).toLowerCase().trim();
      if (ext.length <= 6 && !ext.contains(' ')) return ext;
    }
    return '';
  }

  bool get hasDeadline => (dueTimestamp ?? 0) > 0 || dueText.isNotEmpty;

  bool get isUrgentDeadline {
    if ((dueTimestamp ?? 0) <= 0) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final diff = dueTimestamp! - nowSec;
    return diff > 0 && diff <= 48 * 3600;
  }

  bool get isPastDeadline {
    if ((dueTimestamp ?? 0) <= 0) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return dueTimestamp! < nowSec;
  }

  String get formattedSize => formatFileSize(sizeBytes);

  String get typeLabel {
    switch (type) {
      case 'file':
        return 'Archivo';
      case 'assignment':
        return 'Tarea';
      case 'quiz':
        return 'Cuestionario';
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'course_id': courseId,
        'title': title,
        'section': section,
        'type': type,
        'url': url,
        'file_name': fileName,
        'file_ext': effectiveExt,
        'downloadable': downloadable,
        'size_bytes': sizeBytes,
        'is_downloaded': isDownloaded,
        'is_new': isNew,
        'local_path': localPath,
        'due_timestamp': dueTimestamp,
        'due_text': dueText,
      };

  factory MoodleItem.fromJson(Map<String, dynamic> json) => MoodleItem(
        id: json['id']?.toString() ?? '',
        courseId: (json['course_id'] as num?)?.toInt() ?? 0,
        title: json['title']?.toString() ?? '',
        section: json['section']?.toString() ?? 'General',
        type: json['type']?.toString() ?? 'file',
        url: json['url']?.toString() ?? '',
        fileName: json['file_name']?.toString() ?? '',
        fileExt: json['file_ext']?.toString() ?? '',
        downloadable: json['downloadable'] == true,
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        isDownloaded: json['is_downloaded'] == true,
        isNew: json['is_new'] != false,
        localPath: json['local_path']?.toString(),
        dueTimestamp: (json['due_timestamp'] as num?)?.toInt(),
        dueText: json['due_text']?.toString() ?? '',
      );

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
  bool isHidden;

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
    this.isHidden = false,
  }) : items = items ?? [];

  int get deadlinesCount => items.where((i) => i.hasDeadline).length;

  int get urgentDeadlinesCount => items.where((i) => i.isUrgentDeadline).length;

  Map<String, dynamic> toJson() => {
        'id': id,
        'fullname': fullname,
        'clean_name': cleanName,
        'shortname': shortname,
        'url': url,
        'obsidian_folder': obsidianFolder,
        'target_subfolder': targetSubfolder,
        'organize_by_section': organizeBySection,
        'is_hidden': isHidden,
        'items': items.map((e) => e.toJson()).toList(),
      };

  factory MoodleCourse.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final parsedItems = rawItems is List
        ? rawItems
            .whereType<Map>()
            .map((m) => MoodleItem.fromJson(Map<String, dynamic>.from(m)))
            .toList()
        : <MoodleItem>[];
    return MoodleCourse(
      id: (json['id'] as num?)?.toInt() ?? 0,
      fullname: json['fullname']?.toString() ?? '',
      cleanName: json['clean_name']?.toString() ??
          cleanCourseName(json['fullname']?.toString() ?? ''),
      shortname: json['shortname']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      obsidianFolder: json['obsidian_folder']?.toString() ?? '',
      targetSubfolder: json['target_subfolder']?.toString() ?? 'Aula',
      organizeBySection: json['organize_by_section'] != false,
      items: parsedItems,
      isHidden: json['is_hidden'] == true,
    );
  }

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
