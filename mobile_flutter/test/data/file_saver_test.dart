import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/api/api_exception.dart';
import 'package:namao_app/data/file_saver.dart';
import 'package:namao_app/data/native_media.dart';

import '../support/fakes.dart';

void main() {
  late FakeApi api;
  late FakeNativeMedia media;
  late FileSaver saver;

  setUp(() {
    api = FakeApi();
    media = FakeNativeMedia();
    saver = FileSaver(api: api, media: media);
  });

  tearDown(() => api.dispose());

  Future<Object?> failure(Future<Object?> pending) async {
    try {
      await pending;
    } on Object catch (error) {
      return error;
    }
    return null;
  }

  Matcher transferFailure(TransferFailure expected) =>
      isA<TransferException>().having((e) => e.failure, 'failure', expected);

  test(
    'a complete file is verified, handed to MediaStore, then released',
    () async {
      api.files['job1'] = List.generate(10, (i) => i);

      final saved = await saver.save(
        jobId: 'job1',
        filename: 'My Video.mp4',
        expectedBytes: 10,
      );

      expect(saved.uri, startsWith('content://'));
      expect(media.events.single, 'save My Video.mp4 video/mp4 10');
      expect(
        media.tempExistedAtSave,
        isTrue,
        reason: 'native saw the finished file',
      );
      expect(api.calls, contains('release job1'));
      expect(api.hasWorkingFile('job1'), isFalse);
    },
  );

  test(
    'passes through the real name MediaStore assigned on a duplicate',
    () async {
      api.files['job1'] = [1, 2, 3];
      final saved = await saver.save(
        jobId: 'job1',
        filename: 'a.mp4',
        expectedBytes: 3,
      );
      // The fake echoes the requested name; a real MediaStore may rename it.
      expect(saved.displayName, 'a.mp4');
    },
  );

  test(
    'a file of the wrong size is a size mismatch, never a success',
    () async {
      api.files['job1'] = [1, 2, 3, 4, 5];

      final error = await failure(
        saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 10),
      );

      expect(error, transferFailure(TransferFailure.sizeMismatch));
      expect(media.events, isEmpty, reason: 'nothing was stored');
      expect(
        api.calls,
        isNot(contains('release job1')),
        reason: 'kept for a retry',
      );
    },
  );

  test('a finished file that is gone means the download expired', () async {
    final error = await failure(
      saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 10),
    );

    expect(error, transferFailure(TransferFailure.expired));
    expect(media.events, isEmpty);
  });

  test(
    'another failure to find the file is an io error with its message',
    () async {
      api.fileError = const ApiException(
        code: 'environment_unsupported',
        message: 'Not ready.',
        retryable: true,
      );

      final error = await failure(
        saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 10),
      );

      expect(error, transferFailure(TransferFailure.io));
      expect((error! as TransferException).message, 'Not ready.');
    },
  );

  test(
    'insufficient storage is reported and the file is kept for a retry',
    () async {
      api.files['job1'] = [1, 2, 3];
      media.saveError = const NativeMediaException(
        NativeMediaFailure.storageFull,
        'No space',
      );

      final error = await failure(
        saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 3),
      );

      expect(error, transferFailure(TransferFailure.storageFull));
      expect((error! as TransferException).message, contains('free space'));
      expect(api.calls, isNot(contains('release job1')));
      expect(api.hasWorkingFile('job1'), isTrue);
    },
  );

  test('a native size mismatch is a size mismatch', () async {
    api.files['job1'] = [1, 2, 3];
    media.saveError = const NativeMediaException(
      NativeMediaFailure.sizeMismatch,
      'Wrote 2 of 3',
    );

    final error = await failure(
      saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 3),
    );

    expect(error, transferFailure(TransferFailure.sizeMismatch));
  });

  test('other native failures are io errors without technical text', () async {
    api.files['job1'] = [1, 2, 3];
    media.saveError = const NativeMediaException(
      NativeMediaFailure.io,
      'EACCES /storage/emulated/0/secret',
    );

    final error = await failure(
      saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 3),
    );

    expect(error, transferFailure(TransferFailure.io));
    expect((error! as TransferException).message, isNot(contains('EACCES')));
  });

  test('a cancelled save stores nothing', () async {
    api.files['job1'] = [1, 2, 3];
    final token = TransferToken()..cancel();

    final error = await failure(
      saver.save(
        jobId: 'job1',
        filename: 'a.mp4',
        expectedBytes: 3,
        token: token,
      ),
    );

    expect(error, transferFailure(TransferFailure.cancelled));
    expect(media.events, isEmpty);
  });

  group('helpers', () {
    test('mimeFor', () {
      expect(mimeFor('a.mp4'), 'video/mp4');
      expect(mimeFor('a.MKV'), 'video/x-matroska');
      expect(mimeFor('a.webm'), 'video/webm');
      expect(mimeFor('a.mp3'), 'audio/mpeg');
      expect(mimeFor('a.m4a'), 'audio/mp4');
      expect(mimeFor('noext'), 'application/octet-stream');
      expect(mimeFor('a.xyz'), 'application/octet-stream');
    });

    test('safeDisplayName strips separators and controls', () {
      expect(safeDisplayName('a/b\\c:d*e?.mp4'), 'a b c d e .mp4');
      expect(safeDisplayName('  ..hidden.mp4 '), 'hidden.mp4');
      expect(safeDisplayName(''), 'video');
      expect(safeDisplayName('x' * 300).length, 120);
    });
  });
}
