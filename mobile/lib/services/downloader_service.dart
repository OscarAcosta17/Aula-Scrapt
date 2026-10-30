import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/course.dart';
import 'moodle_service.dart';

class DownloaderService {
  final MoodleService moodleService;

  DownloaderService(this.moodleService);

  Future<String> getRootDownloadPath() async {
    // Intenta usar la carpeta de Documentos en Android
    Directory? dir;
    if (Platform.isAndroid) {
      dir = Directory('/storage/emulated/0/Documents/Obsidian');
      if (!await dir.exists()) {
        try {
          await dir.create(recursive: true);
        } catch (_) {
          dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
        }
      }
    } else {
      dir = await getApplicationDocumentsDirectory();
    }
    return dir.path;
  }

  Future<void> downloadSelectedFiles({
    required MoodleCourse course,
    required List<MoodleModule> items,
    required Function(int current, int total, String currentFile) onProgress,
  }) async {
    final rootPath = await getRootDownloadPath();
    final courseFolder = p.join(rootPath, course.cleanName, 'Aula');
    await Directory(courseFolder).create(recursive: true);

    final total = items.length;
    final Map<String, List<Map<String, String>>> filesBySection = {};

    for (var i = 0; i < total; i++) {
      final item = items[i];
      onProgress(i + 1, total, item.fileName);

      // Determinar la sección a la que pertenece
      String sectionName = 'General';
      for (final sec in course.sections) {
        if (sec.modules.any((m) => m.id == item.id)) {
          sectionName = sec.name;
          break;
        }
      }

      final sectionFolder = p.join(courseFolder, _sanitize(sectionName));
      await Directory(sectionFolder).create(recursive: true);

      final filePath = p.join(sectionFolder, _sanitize(item.fileName));
      final bytes = await moodleService.downloadFileBytes(item.fileUrl);
      final file = File(filePath);
      await file.writeAsBytes(bytes);

      item.isDownloaded = true;

      // Registrar para el grafo .md
      filesBySection.putIfAbsent(sectionName, () => []).add({
        'name': item.name,
        'filename': item.fileName,
        'size': item.formattedSize,
        'path': filePath,
      });
    }

    // Generar o reconstruir los archivos Markdown de grafo para Obsidian
    await _generateMarkdownGraph(course, courseFolder, filesBySection);
  }

  Future<void> _generateMarkdownGraph(
    MoodleCourse course,
    String courseFolder,
    Map<String, List<Map<String, String>>> filesBySection,
  ) async {
    final now = DateTime.now().toString().substring(0, 16);
    final totalFiles = filesBySection.values.fold(0, (acc, list) => acc + list.length);

    // 1. Nota Principal de Curso
    final indexFile = File(p.join(courseFolder, '00 - Indice Aula - ${course.cleanName}.md'));
    final indexSb = StringBuffer();
    indexSb.writeln('---');
    indexSb.writeln('type: aula-course-index');
    indexSb.writeln('course: "${course.cleanName}"');
    indexSb.writeln('updated_at: "$now"');
    indexSb.writeln('total_files: $totalFiles');
    indexSb.writeln('tags: [aula-usm, indice-ia, ${_normalizeTag(course.cleanName)}]');
    indexSb.writeln('---');
    indexSb.writeln();
    indexSb.writeln('# 📚 Material de Aula — ${course.cleanName}');
    indexSb.writeln('> Índice y grafo de conocimientos generado automáticamente por Aula-Scrapt Mobile.');
    indexSb.writeln();
    indexSb.writeln('## 📂 Carpetas y Unidades');

    for (final entry in filesBySection.entries) {
      final secName = entry.key;
      final secItems = entry.value;
      indexSb.writeln('- [[00 - Seccion - $secName]] (${secItems.length} archivos)');
    }

    indexSb.writeln();
    indexSb.writeln('## 📑 Inventario Completo de Recursos');
    indexSb.writeln('| Recurso | Archivo | Tamaño | Sección |');
    indexSb.writeln('| :--- | :--- | :--- | :--- |');

    for (final entry in filesBySection.entries) {
      final secName = entry.key;
      for (final f in entry.value) {
        indexSb.writeln('| ${f['name']} | [[${f['filename']}]] | ${f['size']} | [[00 - Seccion - $secName\\|$secName]] |');
      }
    }

    await indexFile.writeAsString(indexSb.toString());

    // 2. Notas por Sección
    for (final entry in filesBySection.entries) {
      final secName = entry.key;
      final secItems = entry.value;
      final secFolder = p.join(courseFolder, _sanitize(secName));
      final secFile = File(p.join(secFolder, '00 - Seccion - $secName.md'));

      final secSb = StringBuffer();
      secSb.writeln('---');
      secSb.writeln('type: aula-section-index');
      secSb.writeln('course: "${course.cleanName}"');
      secSb.writeln('section: "$secName"');
      secSb.writeln('updated_at: "$now"');
      secSb.writeln('total_files: ${secItems.length}');
      secSb.writeln('---');
      secSb.writeln();
      secSb.writeln('# 📁 $secName — ${course.cleanName}');
      secSb.writeln('⬅️ [[00 - Indice Aula - ${course.cleanName}|Volver al índice del curso]]');
      secSb.writeln();
      secSb.writeln('## Documentos en esta sección');

      for (final f in secItems) {
        secSb.writeln('- [[${f['filename']}]] — *${f['name']}* (${f['size']})');
      }

      await secFile.writeAsString(secSb.toString());
    }
  }

  String _sanitize(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
  }

  String _normalizeTag(String text) {
    return text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').trim();
  }
}
