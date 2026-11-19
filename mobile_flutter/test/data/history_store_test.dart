import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/models/job_status.dart';
import 'package:namao_app/data/history_entry.dart';
import 'package:namao_app/data/history_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

HistoryEntry entry(
  String id, {
  JobStatus status = JobStatus.queued,
  SaveState save = SaveState.none,
  bool gone = false,
}) => HistoryEntry(
  jobId: id,
  sourceUrl: 'https://youtu.be/$id',
  title: 'Title $id',
  thumbnail: 'https://img/$id.jpg',
  qualityId: '720',
  qualityLabel: '720p',
  platform: 'youtube',
  createdAt: DateTime.utc(2026, 1, 1),
  job: makeJob(
    id: id,
    status: status,
    result: status == JobStatus.completed ? makeResult() : null,
  ),
  saveState: save,
  jobGone: gone,
);

Future<HistoryStore> storeWith([Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(initial);
  return HistoryStore(await SharedPreferences.getInstance());
}

void main() {
  test('empty store loads nothing', () async {
    expect((await storeWith()).load(), isEmpty);
  });

  test('persists and restores every field', () async {
    final store = await storeWith();
    final original =
        entry('a', status: JobStatus.completed, save: SaveState.saved).copyWith(
          savedUri: 'content://media/1',
          savedName: 'Video (1).mp4',
          savedBytes: 10,
        );
    await store.save([original, entry('b', status: JobStatus.downloading)]);
    final restored = store.load();
    expect(restored.map((e) => e.jobId), ['a', 'b']);
    final a = restored.first;
    expect(a.title, 'Title a');
    expect(a.thumbnail, 'https://img/a.jpg');
    expect(a.qualityLabel, '720p');
    expect(a.sourceUrl, 'https://youtu.be/a');
    expect(a.createdAt, DateTime.utc(2026, 1, 1));
    expect(a.saveState, SaveState.saved);
    expect(a.savedUri, 'content://media/1');
    expect(a.savedName, 'Video (1).mp4');
    expect(a.job!.result!.sizeBytes, 10);
    expect(restored.last.status, JobStatus.downloading);
  });

  test('dedupes records with the same job id', () async {
    final store = await storeWith();
    await store.save([entry('a'), entry('a'), entry('b')]);
    expect(store.load().map((e) => e.jobId), ['a', 'b']);
  });

  test('corrupt JSON loads as empty instead of crashing', () async {
    final store = await storeWith({'history.v1': '{not json'});
    expect(store.load(), isEmpty);
  });

  test('non-list JSON loads as empty', () async {
    expect((await storeWith({'history.v1': '{"a":1}'})).load(), isEmpty);
  });

  test('skips malformed items but keeps the good ones', () async {
    final good = entry('ok').toJson();
    final store = await storeWith({
      'history.v1':
          '[42, {"job_id": ""}, ${jsonEncode(good)}, {"job_id":"x","save_state":"weird","job":{"id":"x","status":"nope"}}]',
    });
    final loaded = store.load();
    expect(loaded.map((e) => e.jobId), ['ok', 'x']);
    expect(
      loaded.last.saveState,
      SaveState.none,
      reason: 'unknown enum falls back',
    );
    expect(
      loaded.last.job,
      isNull,
      reason: 'unknown job status is dropped, not guessed',
    );
  });

  test('caps the stored history, keeping the newest', () async {
    final store = await storeWith();
    await store.save([
      for (var i = 0; i < maxHistoryEntries + 20; i++) entry('j$i'),
    ]);
    final loaded = store.load();
    expect(loaded.length, maxHistoryEntries);
    expect(loaded.first.jobId, 'j0');
  });

  test('clear removes everything', () async {
    final store = await storeWith();
    await store.save([entry('a')]);
    await store.clear();
    expect(store.load(), isEmpty);
  });

  group('tab classification', () {
    test('non-terminal jobs are Active', () {
      expect(
        entry('a', status: JobStatus.downloading).tab,
        DownloadsTab.active,
      );
      expect(entry('a', status: JobStatus.merging).isActive, isTrue);
    });

    test(
      'completed but not yet saved stays Active; saved moves to Completed',
      () {
        expect(
          entry('a', status: JobStatus.completed).tab,
          DownloadsTab.active,
        );
        expect(
          entry(
            'a',
            status: JobStatus.completed,
            save: SaveState.transferring,
          ).tab,
          DownloadsTab.active,
        );
        final saved = entry(
          'a',
          status: JobStatus.completed,
          save: SaveState.saved,
        ).copyWith(savedUri: 'content://x');
        expect(saved.tab, DownloadsTab.completed);
      },
    );

    test('a failed device save lands in Completed with Retry save', () {
      final failed = entry(
        'a',
        status: JobStatus.completed,
        save: SaveState.failed,
      );
      expect(failed.tab, DownloadsTab.completed);
      expect(failed.needsSave, isTrue);
    });

    test('failed, cancelled, interrupted and expired are Failed', () {
      for (final status in [
        JobStatus.failed,
        JobStatus.cancelled,
        JobStatus.interrupted,
      ]) {
        expect(
          entry('a', status: status).tab,
          DownloadsTab.failed,
          reason: status.wire,
        );
      }
      expect(
        entry('a', status: JobStatus.downloading, gone: true).tab,
        DownloadsTab.failed,
      );
    });

    test('saved wins even if the server later forgot the job', () {
      final saved = entry(
        'a',
        status: JobStatus.completed,
        save: SaveState.saved,
        gone: true,
      ).copyWith(savedUri: 'content://x');
      expect(saved.tab, DownloadsTab.completed);
    });
  });
}
