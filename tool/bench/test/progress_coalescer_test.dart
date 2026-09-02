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

  test('refreshing an item protects it from oldest-event eviction', () async {
    final flushes = <List<ProgressSample>>[];
    final coalescer = ProgressCoalescer((_, samples) => flushes.add(samples));

    for (var item = 0; item < progressItemsPerFlushCap; item++) {
      coalescer.add(_sample('item-$item', item));
    }
    coalescer.add(_sample('item-0', 1000));
    coalescer.add(_sample('overflow', 1001));
    await coalescer.drain();

    final itemIds = flushes.single.map((sample) => sample.itemId);
    expect(itemIds, containsAll(['item-0', 'overflow']));
    expect(itemIds, isNot(contains('item-1')));
  });
}

ProgressSample _sample(String itemId, int transferred) => ProgressSample(
  taskId: 'task',
  itemId: itemId,
  transferred: transferred,
  total: null,
);
