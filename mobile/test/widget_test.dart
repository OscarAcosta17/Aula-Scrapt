import 'package:flutter_test/flutter_test.dart';
import 'package:aula_scrapt/models/course.dart';

void main() {
  test('Clean course name smoke test', () {
    const raw = '(202602)(INF266) SISTEMAS DE GESTIÓN|Paralelos:200/201';
    final clean = MoodleCourse.cleanCourseName(raw);
    expect(clean, 'Sistemas de Gestión');
  });
}
