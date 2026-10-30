class MoodleCourse {
  final int id;
  final String fullname;
  final String cleanName;
  final String shortname;
  List<MoodleSection> sections;
  bool isExpanded;

  MoodleCourse({
    required this.id,
    required this.fullname,
    required this.cleanName,
    required this.shortname,
    this.sections = const [],
    this.isExpanded = false,
  });

  static String cleanCourseName(String raw) {
    String s = raw.trim();
    // Remover (202602), [2026-2]
    s = s.replaceAll(RegExp(r'^\s*[\(\[]\s*\d{4,6}[A-Za-z0-9\-_]*\s*[\)\]]'), '');
    // Remover (INF266)
    s = s.replaceAll(RegExp(r'^\s*[\(\[]\s*[A-Za-z]{2,5}\s*-?\s*\d{2,4}[A-Za-z0-9]*\s*[\)\]]'), '');
    // Remover paralelos
    s = s.replaceAll(RegExp(r'[\s\|\-_]+(?:Paralelos?|paralelos?|PARALELOS?)\s*[:_\-]?\s*[\d\/\-_A-Za-z]+.*$'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    
    // Capitalización limpia si está en mayúsculas
    if (s.isNotEmpty && s == s.toUpperCase()) {
      final words = s.toLowerCase().split(' ');
      const lowerWords = {'de', 'del', 'y', 'e', 'en', 'el', 'la', 'los', 'las', 'un', 'una', 'por', 'para', 'al', 'con'};
      final res = words.asMap().entries.map((entry) {
        final w = entry.value;
        if (entry.key == 0 || !lowerWords.contains(w)) {
          return w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : '';
        }
        return w;
      }).join(' ');
      return res.isNotEmpty ? res : raw;
    }
    return s.isNotEmpty ? s : raw;
  }
}

class MoodleSection {
  final int id;
  final String name;
  final List<MoodleModule> modules;
  bool isExpanded;

  MoodleSection({
    required this.id,
    required this.name,
    required this.modules,
    this.isExpanded = true,
  });
}

class MoodleModule {
  final int id;
  final String name;
  final String modname; // 'resource', 'folder', etc.
  final String fileUrl;
  final String fileName;
  final int fileSize; // bytes
  bool isSelected;
  bool isDownloaded;

  MoodleModule({
    required this.id,
    required this.name,
    required this.modname,
    required this.fileUrl,
    required this.fileName,
    required this.fileSize,
    this.isSelected = false,
    this.isDownloaded = false,
  });

  String get formattedSize {
    if (fileSize <= 0) return '';
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
