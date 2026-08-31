import 'package:poltergeist_m0_bench/progress_coalescer.dart';
import 'package:test/test.dart';

void main() {
  test('coalesces a flood and hard-caps the flush', () async {
    final flushes = <List<ProgressSample>>[];
    final coalescer = ProgressCoalescer((_, samples) => flushes.add(samples));

    for (var event = 0; event < 10_000; event++) {
      coalescer.add(
        ProgressSample(
          taskId: 'task',
          itemId: 'item-${event % 100}',
          transferred: event,
          total: 10_000,
        ),
      );
    }
    await coalescer.drain();

    expect(flushes, hasLength(1));
    expect(flushes.single, hasLength(progressItemsPerFlushCap));
    expect(flushes.single.last.transferred, 9999);
  });
}
