import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/data/engine/progress_tracker.dart';

StreamProgress s(int downloaded, int total, {bool done = false}) =>
    StreamProgress(downloaded: downloaded, total: total, done: done);

void main() {
  test('a single stream reports its own percentage', () {
    final tracker = ProgressTracker(expectedStreams: 1);

    final snapshot = tracker.update([s(25, 100)]);

    expect(snapshot.percent, closeTo(25, 1e-9));
    expect(snapshot.downloadedBytes, 25);
    expect(snapshot.totalBytes, 100);
  });

  test('video then audio never jumps back to 0 between the two transfers', () {
    // The announced size is 1000: 900 of video plus 100 of audio.
    final tracker = ProgressTracker(
      expectedStreams: 2,
      estimatedTotalBytes: 1000,
    );

    final midVideo = tracker.update([s(450, 900)]).percent;
    final videoDone = tracker.update([s(900, 900, done: true)]).percent;
    final audioStarts = tracker.update([
      s(900, 900, done: true),
      s(0, 100),
    ]).percent;
    final audioHalf = tracker.update([
      s(900, 900, done: true),
      s(50, 100),
    ]).percent;

    expect(midVideo, closeTo(45, 1e-9));
    expect(
      videoDone,
      closeTo(90, 1e-9),
      reason: 'not 100: the audio is still to come',
    );
    expect(audioStarts, greaterThanOrEqualTo(videoDone));
    expect(audioHalf, closeTo(95, 1e-9));
  });

  test('uses the real totals once every stream has started', () {
    final tracker = ProgressTracker(
      expectedStreams: 2,
      estimatedTotalBytes: 5000,
    );

    final snapshot = tracker.update([s(800, 800, done: true), s(100, 200)]);

    expect(
      snapshot.totalBytes,
      1000,
      reason: 'real sizes replace the estimate',
    );
    expect(snapshot.percent, closeTo(90, 1e-9));
  });

  test('is held at 99% until the file is finished', () {
    final tracker = ProgressTracker(expectedStreams: 1);

    final snapshot = tracker.update([s(100, 100, done: true)]);

    expect(snapshot.percent, 99);
  });

  test('without any size estimate, each expected stream is an equal share', () {
    final tracker = ProgressTracker(expectedStreams: 2);

    final firstDone = tracker.update([s(10, 10, done: true)]).percent;
    final secondHalf = tracker.update([
      s(10, 10, done: true),
      s(5, 10),
    ]).percent;

    expect(firstDone, closeTo(50, 1e-9));
    expect(secondHalf, closeTo(75, 1e-9));
  });

  test(
    'a stream of unknown size counts for nothing until its size is known',
    () {
      final tracker = ProgressTracker(expectedStreams: 1);

      expect(tracker.update([s(5000, 0)]).percent, 0);
    },
  );

  test('never moves backwards, even when the estimate turns out too small', () {
    final tracker = ProgressTracker(
      expectedStreams: 2,
      estimatedTotalBytes: 1000,
    );

    final before = tracker.update([
      s(600, 600, done: true),
      s(300, 400),
    ]).percent;
    // A new stream total larger than expected raises the denominator.
    final after = tracker.update([
      s(600, 600, done: true),
      s(310, 900),
    ]).percent;

    expect(after, greaterThanOrEqualTo(before));
  });

  test(
    'with an unknown stream count, a one-stream download is not held at 50%',
    () {
      final tracker = ProgressTracker();

      final half = tracker.update([s(50, 100)]).percent;
      final done = tracker.update([s(100, 100, done: true)]).percent;

      expect(half, closeTo(50, 1e-9));
      expect(
        done,
        99,
        reason: 'finished, held at 99% only until the file is complete',
      );
    },
  );

  test('with an unknown stream count, a second stream appearing never moves progress backwards', () {
    final tracker = ProgressTracker();

    final first = tracker.update([s(100, 100, done: true)]).percent;
    final next = tracker.update([s(100, 100, done: true), s(10, 100)]).percent;

    expect(next, greaterThanOrEqualTo(first));
  });

  test('no streams yet is 0%', () {
    final snapshot = ProgressTracker(
      expectedStreams: 2,
      estimatedTotalBytes: 100,
    ).update([]);

    expect(snapshot.percent, 0);
    expect(snapshot.downloadedBytes, 0);
  });

  test('StreamProgress reads the native map', () {
    final stream = StreamProgress.fromMap({
      'downloaded': 12,
      'total': 34,
      'done': true,
    });

    expect(stream.downloaded, 12);
    expect(stream.total, 34);
    expect(stream.done, isTrue);
    expect(StreamProgress.fromMap({}).total, 0);
  });
}
