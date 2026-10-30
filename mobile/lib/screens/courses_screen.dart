import 'package:flutter/material.dart';
import '../models/course.dart';
import '../services/moodle_service.dart';
import '../services/downloader_service.dart';
import 'login_screen.dart';

class CoursesScreen extends StatefulWidget {
  final MoodleService moodleService;

  const CoursesScreen({super.key, required this.moodleService});

  @override
  State<CoursesScreen> createState() => _CoursesScreenState();
}

class _CoursesScreenState extends State<CoursesScreen> {
  late final DownloaderService _downloaderService;
  List<MoodleCourse> _courses = [];
  bool _isLoading = true;
  String? _error;

  // Estado de descarga
  bool _isDownloading = false;
  int _downloadCurrent = 0;
  int _downloadTotal = 0;
  String _downloadingFile = '';

  @override
  void initState() {
    super.initState();
    _downloaderService = DownloaderService(widget.moodleService);
    _loadCourses();
  }

  Future<void> _loadCourses() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final courses = await widget.moodleService.getCourses();
      setState(() {
        _courses = courses;
        _isLoading = false;
      });
      // Cargar contenidos de cursos en segundo plano
      for (final c in _courses) {
        _loadCourseContents(c);
      }
    } catch (e) {
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  Future<void> _loadCourseContents(MoodleCourse course) async {
    try {
      final sections = await widget.moodleService.getCourseContents(course.id);
      if (mounted) {
        setState(() {
          course.sections = sections;
        });
      }
    } catch (_) {}
  }

  void _toggleCourseSelection(MoodleCourse course, bool selectAll) {
    setState(() {
      for (final sec in course.sections) {
        for (final mod in sec.modules) {
          mod.isSelected = selectAll;
        }
      }
    });
  }

  int get _selectedFilesCount {
    int count = 0;
    for (final c in _courses) {
      for (final s in c.sections) {
        for (final m in s.modules) {
          if (m.isSelected) count++;
        }
      }
    }
    return count;
  }

  int get _selectedFilesTotalBytes {
    int bytes = 0;
    for (final c in _courses) {
      for (final s in c.sections) {
        for (final m in s.modules) {
          if (m.isSelected) bytes += m.fileSize;
        }
      }
    }
    return bytes;
  }

  String get _formattedTotalBytes {
    final b = _selectedFilesTotalBytes;
    if (b <= 0) return '';
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _startDownload() async {
    final selectedModules = <MoodleCourse, List<MoodleModule>>{};
    for (final c in _courses) {
      final items = <MoodleModule>[];
      for (final s in c.sections) {
        for (final m in s.modules) {
          if (m.isSelected) items.add(m);
        }
      }
      if (items.isNotEmpty) selectedModules[c] = items;
    }

    if (selectedModules.isEmpty) return;

    setState(() {
      _isDownloading = true;
      _downloadCurrent = 0;
      _downloadTotal = _selectedFilesCount;
    });

    try {
      int overallIndex = 0;
      for (final entry in selectedModules.entries) {
        final course = entry.key;
        final items = entry.value;

        await _downloaderService.downloadSelectedFiles(
          course: course,
          items: items,
          onProgress: (cur, tot, file) {
            setState(() {
              _downloadCurrent = overallIndex + cur;
              _downloadingFile = file;
            });
          },
        );
        overallIndex += items.length;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Descarga completada y grafo .md actualizado'),
            backgroundColor: Color(0xFF238636),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al descargar: $e'),
            backgroundColor: const Color(0xFFF85149),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadingFile = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset('assets/logo.png', width: 24, height: 24, errorBuilder: (_, __, ___) => const Icon(Icons.school, size: 20, color: Color(0xFF38BDF8))),
            ),
            const SizedBox(width: 10),
            const Text('Aula-Scrapt', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20, color: Color(0xFF8B949E)),
            onPressed: _isLoading ? null : _loadCourses,
            tooltip: 'Recargar cursos',
          ),
          IconButton(
            icon: const Icon(Icons.logout, size: 20, color: Color(0xFFF85149)),
            onPressed: () async {
              await widget.moodleService.logout();
              if (mounted) {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => LoginScreen(moodleService: widget.moodleService)),
                );
              }
            },
            tooltip: 'Cerrar sesión',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Color(0xFF38BDF8)),
                  SizedBox(height: 16),
                  Text('Consultando cursos en Aula USM...', style: TextStyle(color: Color(0xFF8B949E), fontSize: 14)),
                ],
              ),
            )
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline, color: Color(0xFFF85149), size: 48),
                        const SizedBox(height: 16),
                        Text(_error!, style: const TextStyle(color: Color(0xFFC9D1D9), fontSize: 14), textAlign: TextAlign.center),
                        const SizedBox(height: 20),
                        ElevatedButton(
                          onPressed: _loadCourses,
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF238636)),
                          child: const Text('Reintentar'),
                        ),
                      ],
                    ),
                  ),
                )
              : _courses.isEmpty
                  ? const Center(
                      child: Text('No se encontraron cursos activos.', style: TextStyle(color: Color(0xFF8B949E))),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
                      itemCount: _courses.length,
                      itemBuilder: (context, index) {
                        final course = _courses[index];
                        final hasContents = course.sections.isNotEmpty;
                        final totalModules = course.sections.fold(0, (sum, sec) => sum + sec.modules.length);

                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF161B22),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFF30363D)),
                          ),
                          child: Theme(
                            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                            child: ExpansionTile(
                              initiallyExpanded: false,
                              leading: const Icon(Icons.folder_outlined, color: Color(0xFF58A6FF), size: 22),
                              title: Text(
                                course.cleanName,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                              ),
                              subtitle: Text(
                                hasContents ? '$totalModules archivos en ${course.sections.length} secciones' : 'Cargando recursos...',
                                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12),
                              ),
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      TextButton.icon(
                                        onPressed: () => _toggleCourseSelection(course, true),
                                        icon: const Icon(Icons.select_all, size: 16, color: Color(0xFF58A6FF)),
                                        label: const Text('Marcar ramo', style: TextStyle(fontSize: 12, color: Color(0xFF58A6FF))),
                                      ),
                                      TextButton(
                                        onPressed: () => _toggleCourseSelection(course, false),
                                        child: const Text('Desmarcar', style: TextStyle(fontSize: 12, color: Color(0xFF8B949E))),
                                      ),
                                    ],
                                  ),
                                ),
                                const Divider(color: Color(0xFF30363D), height: 1),
                                ...course.sections.map((section) {
                                  return Container(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                                          child: Text(
                                            section.name.toUpperCase(),
                                            style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                                          ),
                                        ),
                                        ...section.modules.map((mod) {
                                          return CheckboxListTile(
                                            value: mod.isSelected,
                                            activeColor: const Color(0xFF238636),
                                            checkColor: Colors.white,
                                            dense: true,
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                                            title: Text(
                                              mod.fileName,
                                              style: TextStyle(
                                                color: mod.isDownloaded ? const Color(0xFF58A6FF) : const Color(0xFFC9D1D9),
                                                fontSize: 13,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            subtitle: mod.formattedSize.isNotEmpty
                                                ? Text(mod.formattedSize, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11))
                                                : null,
                                            secondary: Icon(
                                              mod.isDownloaded ? Icons.check_circle_outline : Icons.insert_drive_file_outlined,
                                              size: 18,
                                              color: mod.isDownloaded ? const Color(0xFF238636) : const Color(0xFF8B949E),
                                            ),
                                            onChanged: (val) {
                                              setState(() {
                                                mod.isSelected = val ?? false;
                                              });
                                            },
                                          );
                                        }),
                                      ],
                                    ),
                                  );
                                }),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
      bottomSheet: _selectedFilesCount > 0 || _isDownloading
          ? Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Color(0xFF161B22),
                border: Border(top: BorderSide(color: Color(0xFF30363D))),
              ),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isDownloading) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              'Descargando: $_downloadingFile',
                              style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text('$_downloadCurrent / $_downloadTotal', style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: _downloadTotal > 0 ? _downloadCurrent / _downloadTotal : 0,
                        backgroundColor: const Color(0xFF0D1117),
                        color: const Color(0xFF238636),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '$_selectedFilesCount archivos seleccionados',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            if (_formattedTotalBytes.isNotEmpty)
                              Text(
                                _formattedTotalBytes,
                                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12),
                              ),
                          ],
                        ),
                        ElevatedButton.icon(
                          onPressed: _isDownloading ? null : _startDownload,
                          icon: const Icon(Icons.download, size: 16),
                          label: Text(_isDownloading ? 'Descargando...' : 'Descargar'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF238636),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}
