import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/course.dart';
import 'moodle_service.dart';
import 'settings_service.dart';

class DownloadBatchResult {
  final int downloadedCount;
  final List<({String title, String error})> errors;
  final String? lastSavedDir;

  DownloadBatchResult({
    required this.downloadedCount,
    required this.errors,
    this.lastSavedDir,
  });
}

class DownloaderService {
  final MoodleService moodleService;
  final SettingsService settingsService;

  DownloaderService({
    required this.moodleService,
    required this.settingsService,
  });

  Future<DownloadBatchResult> downloadSelectedItems({
    required List<({MoodleCourse course, MoodleItem item})> queue,
    required Function(int current, int total, String currentFile, String stage) onProgress,
  }) async {
    final downloadRoot = settingsService.downloadRoot;
    if (downloadRoot.trim().isEmpty) {
      throw Exception('No hay carpeta de destino configurada.');
    }

    // Validar acceso de escritura antes de empezar el lote
    try {
      await Directory(downloadRoot).create(recursive: true);
    } on FileSystemException catch (e) {
      throw StoragePermissionException(
        'Sin permiso para escribir en "$downloadRoot". Habilita el permiso de almacenamiento o elige otra carpeta. (${e.message})',
      );
    }

    int downloadedCount = 0;
    final List<({String title, String error})> errors = [];
    final Set<MoodleCourse> touchedCourses = {};
    String? lastSavedDir;

    final history = settingsService.history;
    final downloadedIds = history['downloaded_ids'] as Map<String, dynamic>;
    final seenIds = history['seen_ids'] as Map<String, dynamic>;
    final fileSizes = history['file_sizes'] as Map<String, dynamic>;

    final total = queue.length;

    for (var i = 0; i < total; i++) {
      final entry = queue[i];
      final course = entry.course;
      final item = entry.item;

      onProgress(i + 1, total, item.title, 'Descargando');

      try {
        final data = await moodleService.downloadItemData(item);

        final courseFolder = MoodleCourse.sanitizeFileName(course.obsidianFolder);
        final courseDirPath = p.join(downloadRoot, courseFolder);

        var destDirPath = courseDirPath;
        if (course.targetSubfolder.trim().isNotEmpty) {
          destDirPath = p.join(
            destDirPath,
            MoodleCourse.sanitizeFileName(course.targetSubfolder.trim()),
          );
        }
        if (course.organizeBySection && item.section.trim().isNotEmpty) {
          destDirPath = p.join(
            destDirPath,
            MoodleCourse.sanitizeFileName(item.section.trim()),
          );
        }

        await Directory(destDirPath).create(recursive: true);
        final destFilePath = p.join(destDirPath, data.filename);
        final file = File(destFilePath);
        await file.writeAsBytes(data.bytes, flush: true);

        final nowIso = DateTime.now().toIso8601String().substring(0, 19);
        fileSizes[item.id] = data.sizeBytes;
        downloadedIds[item.id] = {
          'title': item.title,
          'section': item.section,
          'filename': data.filename,
          'course_folder': course.obsidianFolder,
          'path': destFilePath,
          'size_bytes': data.sizeBytes,
          'downloaded_at': nowIso,
        };
        seenIds[item.id] = {
          'title': item.title,
          'first_seen': nowIso,
        };

        item.isDownloaded = true;
        item.isNew = false;
        item.isSelected = false;
        item.sizeBytes = data.sizeBytes;
        item.localPath = destFilePath;

        downloadedCount++;
        lastSavedDir = destDirPath;
        touchedCourses.add(course);

        onProgress(i + 1, total, data.filename, 'Guardado');
      } on SessionExpiredException {
        rethrow;
      } on FileSystemException catch (e) {
        if ((e.osError?.errorCode ?? 0) == 13 ||
            e.message.toLowerCase().contains('permission')) {
          throw StoragePermissionException(
            'Android bloqueó la escritura en "$downloadRoot". Concede "Acceso a todos los archivos" para descargar.',
          );
        }
        errors.add((title: item.title, error: e.message));
      } catch (e) {
        errors.add((title: item.title, error: e.toString().replaceAll('Exception: ', '')));
      }
    }

    await settingsService.saveHistory();

    // Actualizar índice compartido PC <-> Android (.aula-scrapt-index.json)
    final sharedEntries = <Map<String, dynamic>>[];
    for (final entry in queue) {
      final item = entry.item;
      if (item.isDownloaded && item.localPath != null && item.localPath!.isNotEmpty) {
        sharedEntries.add({
          'item_id': item.id,
          'full_path': item.localPath!,
          'filename': p.basename(item.localPath!),
          'title': item.title,
          'course_id': item.courseId,
        });
      }
    }
    if (sharedEntries.isNotEmpty) {
      await settingsService.recordSharedIndexEntries(sharedEntries);
    }

    // Regenerar grafos Markdown (.md) de Obsidian para cada curso descargado
    for (final course in touchedCourses) {
      try {
        await _rebuildCourseGraphMarkdown(downloadRoot, course);
      } catch (_) {}
    }

    if (downloadedCount > 0 && settingsService.notifyOnDownloadDone) {
      final firstCourse = touchedCourses.isNotEmpty ? touchedCourses.first.cleanName : '';
      await settingsService.addNotification(
        title: 'Descarga completada ($downloadedCount)',
        body: downloadedCount == 1 && touchedCourses.isNotEmpty
            ? 'Material guardado en $firstCourse'
            : '$downloadedCount archivos guardados en tu carpeta local.',
        kind: 'download',
        courseName: firstCourse,
        dedupKey: 'dl_${DateTime.now().millisecondsSinceEpoch ~/ 5000}_$downloadedCount',
        triggerNative: true,
        nativeChannelId: 'aula_downloads',
      );
    }

    return DownloadBatchResult(
      downloadedCount: downloadedCount,
      errors: errors,
      lastSavedDir: lastSavedDir,
    );
  }

  Future<void> _rebuildCourseGraphMarkdown(
    String downloadRoot,
    MoodleCourse course,
  ) async {
    final courseFolder = MoodleCourse.sanitizeFileName(course.obsidianFolder);
    final courseDir = Directory(p.join(downloadRoot, courseFolder));
    var baseScanDir = course.targetSubfolder.trim().isNotEmpty
        ? Directory(p.join(
            courseDir.path,
            MoodleCourse.sanitizeFileName(course.targetSubfolder.trim()),
          ))
        : courseDir;
    if (!await baseScanDir.exists()) {
      baseScanDir = courseDir;
    }

    final history = settingsService.history;
    final downloadedIds = history['downloaded_ids'] as Map<String, dynamic>;
    final Map<String, Map<String, dynamic>> metaByPath = {};
    for (final val in downloadedIds.values) {
      if (val is Map<String, dynamic>) {
        final pathStr = (val['path'] ?? '').toString();
        if (pathStr.isNotEmpty) {
          metaByPath[p.normalize(pathStr)] = val;
        }
      }
    }

    final courseIndexName = '00 - Indice Aula - $courseFolder';
    final courseIndexFile = File(p.join(baseScanDir.path, '$courseIndexName.md'));
    final courseTag = _slugifyTag(course.obsidianFolder);
    final nowIso = DateTime.now().toString().substring(0, 16);

    final Map<String, List<File>> sectionsDict = {};
    await for (final entity in baseScanDir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        final f = p.basename(entity.path);
        if (f.startsWith('.')) continue;
        if (f.endsWith('.md') &&
            (f.startsWith('00 - Indice Aula') || f.startsWith('00 - Seccion -'))) {
          continue;
        }
        final parentRel = p.relative(entity.parent.path, from: baseScanDir.path).replaceAll('\\', '/');
        final secLabel = parentRel == '.' ? 'General' : parentRel;
        sectionsDict.putIfAbsent(secLabel, () => []).add(entity);
      }
    }

    for (final list in sectionsDict.values) {
      list.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    }

    final totalFiles = sectionsDict.values.fold(0, (acc, l) => acc + l.length);
    final sortedSections = sectionsDict.keys.toList()..sort();
    final List<({String label, String relMd})> sectionNodeLinks = [];

    // 1. Notas .md por sección
    for (final secLabel in sortedSections) {
      final fileList = sectionsDict[secLabel]!;
      if (secLabel != 'General') {
        final secDirPath = p.join(baseScanDir.path, secLabel);
        final secCleanTitle = MoodleCourse.sanitizeFileName(p.basename(secDirPath));
        final secMdName = '00 - Seccion - $secCleanTitle';
        final secMdFile = File(p.join(secDirPath, '$secMdName.md'));
        final relSecMd = p
            .withoutExtension(p.relative(secMdFile.path, from: baseScanDir.path))
            .replaceAll('\\', '/');
        sectionNodeLinks.add((label: secLabel, relMd: relSecMd));

        final sb = StringBuffer()
          ..writeln('---')
          ..writeln('type: aula-section-index')
          ..writeln('course: "${course.obsidianFolder}"')
          ..writeln('section: "$secLabel"')
          ..writeln('updated_at: "$nowIso"')
          ..writeln('file_count: ${fileList.length}')
          ..writeln('tags: [aula-usm, seccion-aula, $courseTag]')
          ..writeln('---')
          ..writeln()
          ..writeln('# Seccion: $secLabel')
          ..writeln()
          ..writeln('Indice superior: [[$courseIndexName]]')
          ..writeln()
          ..writeln('## Archivos en esta seccion')
          ..writeln();

        for (final fp in fileList) {
          final meta = metaByPath[p.normalize(fp.path)];
          final fn = p.basename(fp.path);
          final aulaTitle = meta?['title']?.toString() ?? p.basenameWithoutExtension(fn);
          final dlAt = (meta?['downloaded_at']?.toString() ?? '');
          final shortDate = dlAt.length >= 10 ? dlAt.substring(0, 10) : '';
          final relFromBase = p.relative(fp.path, from: baseScanDir.path).replaceAll('\\', '/');
          sb.writeln(
            '- [[$relFromBase|$fn]] — *$aulaTitle*${shortDate.isNotEmpty ? ' ($shortDate)' : ''}',
          );
        }

        await secMdFile.writeAsString(sb.toString());
      }
    }

    // 2. Nota maestra del ramo
    final indexSb = StringBuffer()
      ..writeln('---')
      ..writeln('type: aula-course-index')
      ..writeln('course: "${course.obsidianFolder}"')
      ..writeln('updated_at: "$nowIso"')
      ..writeln('total_files: $totalFiles')
      ..writeln('total_sections: ${sectionsDict.length}')
      ..writeln('tags: [aula-usm, indice-ia, $courseTag]')
      ..writeln('---')
      ..writeln()
      ..writeln('# Indice de Material Aula USM — ${course.obsidianFolder}')
      ..writeln()
      ..writeln(
        '> Nodo central de navegacion y contexto para busqueda por grafo e IA. Este archivo se actualiza y sobrescribe automaticamente al descargar material.',
      )
      ..writeln();

    if (sectionNodeLinks.isNotEmpty) {
      indexSb.writeln('## Nodos de Secciones');
      indexSb.writeln();
      for (final node in sectionNodeLinks) {
        indexSb.writeln('- [[${node.relMd}|${node.label}]]');
      }
      indexSb.writeln();
    }

    indexSb.writeln('## Mapa de Archivos por Seccion');
    indexSb.writeln();

    for (final secLabel in sortedSections) {
      indexSb.writeln('### $secLabel');
      indexSb.writeln();
      indexSb.writeln('| Recurso en Aula | Archivo Vinculado (Grafo) | Tamaño | Ruta Relativa | Fecha |');
      indexSb.writeln('| :--- | :--- | :--- | :--- | :--- |');
      for (final fp in sectionsDict[secLabel]!) {
        final meta = metaByPath[p.normalize(fp.path)];
        final fn = p.basename(fp.path);
        final aulaTitle = (meta?['title']?.toString() ?? p.basenameWithoutExtension(fn))
            .replaceAll('|', '-');
        final dlAt = meta?['downloaded_at']?.toString() ?? nowIso;
        final shortDate = dlAt.length >= 10 ? dlAt.substring(0, 10) : nowIso.substring(0, 10);
        int szBytes = 0;
        try {
          szBytes = await fp.length();
        } catch (_) {}
        final szHuman = MoodleItem.formatFileSize(szBytes);
        final relFromBase = p.relative(fp.path, from: baseScanDir.path).replaceAll('\\', '/');
        indexSb.writeln(
          '| $aulaTitle | [[$relFromBase\\|$fn]] | ${szHuman.isEmpty ? '-' : szHuman} | `$relFromBase` | $shortDate |',
        );
      }
      indexSb.writeln();
    }

    if (settingsService.autoExportLinksToObsidian) {
      final linkItems =
          course.items.where((i) => i.type == 'link' && i.url.isNotEmpty).toList();
      if (linkItems.isNotEmpty) {
        indexSb.writeln('## Enlaces y Clases (URL)');
        indexSb.writeln();
        for (final li in linkItems) {
          indexSb.writeln('- [${li.title}](${li.url}) — *${li.section}*');
        }
        indexSb.writeln();
      }
    }

    if (settingsService.autoExportForumsToObsidian) {
      final forumItems =
          course.items.where((i) => i.type == 'forum' && i.url.isNotEmpty).toList();
      if (forumItems.isNotEmpty) {
        indexSb.writeln('## Foros y Anuncios');
        indexSb.writeln();
        for (final fi in forumItems) {
          indexSb.writeln('- [${fi.title}](${fi.url}) — *${fi.section}*');
        }
        indexSb.writeln();
      }
    }

    final deadlineItems = course.items
        .where((i) => i.type == 'assignment' || i.type == 'quiz')
        .toList();
    if (deadlineItems.isNotEmpty) {
      indexSb.writeln('## Entregas y Evaluaciones');
      indexSb.writeln();
      for (final di in deadlineItems) {
        final dueSuffix = di.dueText.isNotEmpty ? ' · Cierra: ${di.dueText}' : '';
        indexSb.writeln(
          '- [${di.title}](${di.url}) — *${di.typeLabel}* (${di.section})$dueSuffix',
        );
      }
      indexSb.writeln();
    }

    await courseIndexFile.writeAsString(indexSb.toString());
  }

  /// Exporta o regenera explícitamente los índices Obsidian (.md) de un ramo
  Future<void> syncCourseObsidianIndex(MoodleCourse course) async {
    await _rebuildCourseGraphMarkdown(settingsService.downloadRoot, course);
  }

  String _slugifyTag(String text) {
    final slug = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-zA-Z0-9áéíóúñÁÉÍÓÚÑ]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'curso' : slug;
  }
}
