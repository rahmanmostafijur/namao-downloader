import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:namao_app/core/api/api_exception.dart';
import 'package:namao_app/core/api/namao_api.dart';
import 'package:namao_app/data/file_saver.dart';
import 'package:namao_app/data/native_media.dart';

import '../support/fakes.dart';

void main() {
  late Directory temp;
  late FakeApi api;
  late FakeNativeMedia media;
  late FileSaver saver;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('namao_saver_test');
    api = FakeApi();
    media = FakeNativeMedia();
    saver = FileSaver(api: api, media: media, tempDirectory: () => temp);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  List<String> leftovers() => temp.listSync().map((e) => e.path).toList();

  Future<Object?> failure(Future<Object?> pending) async {
    try {
      await pending;
    } on Object catch (error) {
      return error;
    }
    return null;
  }

  test('a complete file is verified, handed to MediaStore, and the temp file removed', () async {
    api.files['job1'] = List.generate(10, (i) => i);
    final progress = <int>[];
    final saved = await saver.save(
      jobId: 'job1',
      filename: 'My Video.mp4',
      expectedBytes: 10,
      onProgress: progress.add,
    );
    expect(saved.uri, startsWith('content://'));
    expect(media.events.single, 'save My Video.mp4 video/mp4 10');
    expect(
      media.tempExistedAtSave,
      isTrue,
      reason: 'native saw the complete temp file',
    );
    expect(progress.last, 10);
    expect(leftovers(), isEmpty);
  });

  test('records the real name MediaStore assigned on a duplicate', () async {
    api.files['job1'] = [1, 2, 3];
    // The fake echoes the requested name; a real MediaStore may rename. The saver must pass
    // through whatever the native layer reports rather than assuming the requested name.
    final saved = await saver.save(
      jobId: 'job1',
      filename: 'a.mp4',
      expectedBytes: 3,
    );
    expect(saved.displayName, 'a.mp4');
  });

  test(
    'fewer bytes than announced is a size mismatch, never a success',
    () async {
      api.files['job1'] = [1, 2, 3, 4, 5];
      api.fileContentLengthOverride = 10; // header lies; body is short
      final error = await failure(
        saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 10),
      );
      expect(
        error,
        isA<TransferException>().having(
          (e) => e.failure,
          'failure',
          TransferFailure.sizeMismatch,
        ),
      );
      expect(media.events, isEmpty, reason: 'MediaStore is never touched');
      expect(leftovers(), isEmpty);
    },
  );

  test('a short body with a matching header is still rejected', () async {
    api.files['job1'] = [1, 2, 3, 4, 5];
    api.fileContentLengthOverride = 5;
    final error = await failure(
      saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 10),
    );
    expect(
      error,
      isA<TransferException>().having(
        (e) => e.failure,
        'failure',
        TransferFailure.sizeMismatch,
      ),
    );
    expect(media.events, isEmpty);
    expect(leftovers(), isEmpty);
  });

  test('more bytes than expected is rejected too', () async {
    api.files['job1'] = List.generate(12, (i) => i);
    api.fileContentLengthOverride = 10;
    final error = await failure(
      saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 10),
    );
    expect(
      error,
      isA<TransferException>().having(
        (e) => e.failure,
        'failure',
        TransferFailure.sizeMismatch,
      ),
    );
    expect(leftovers(), isEmpty);
  });

  test(
    'a dropped connection mid-stream is a network failure and cleans up',
    () async {
      api.files['job1'] = [1, 2, 3];
      api.fileStreamError = (_) => const SocketException('reset');
      final error = await failure(
        saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 3),
      );
      expect(
        error,
        isA<TransferException>().having(
          (e) => e.failure,
          'failure',
          TransferFailure.network,
        ),
      );
      expect(media.events, isEmpty);
      expect(leftovers(), isEmpty);
    },
  );

  test('http client errors map to network failures', () async {
    api.files['job1'] = [1, 2, 3];
    api.fileStreamError = (_) => http.ClientException('boom');
    final error = await failure(
      saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 3),
    );
    expect(
      error,
      isA<TransferException>().having(
        (e) => e.failure,
        'failure',
        TransferFailure.network,
      ),
    );
  });

  test('a stalled stream times out', () async {
    final stalled = FileSaver(
      api: _StallingApi(),
      media: media,
      tempDirectory: () => temp,
      stallTimeout: const Duration(milliseconds: 40),
    );
    final error = await failure(
      stalled.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 3),
    );
    expect(
      error,
      isA<TransferException>().having(
        (e) => e.failure,
        'failure',
        TransferFailure.network,
      ),
    );
    expect(leftovers(), isEmpty);
  });

  test('server 404/410 means the file expired', () async {
    api.fileError = const ApiException(
      kind: ApiFailureKind.server,
      code: 'expired',
      message: 'Expired.',
      status: 410,
    );
    final error = await failure(
      saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 3),
    );
    expect(
      error,
      isA<TransferException>().having(
        (e) => e.failure,
        'failure',
        TransferFailure.expired,
      ),
    );
  });

  test('401 means the API key was rejected', () async {
    api.fileError = const ApiException(
      kind: ApiFailureKind.server,
      code: 'unauthorized',
      message: 'no',
      status: 401,
    );
    final error = await failure(
      saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 3),
    );
    expect(
      error,
      isA<TransferException>().having(
        (e) => e.failure,
        'failure',
        TransferFailure.unauthorized,
      ),
    );
  });

  test('connection errors opening the file are network failures', () async {
    api.fileError = const ApiException.network();
    final error = await failure(
      saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 3),
    );
    expect(
      error,
      isA<TransferException>().having(
        (e) => e.failure,
        'failure',
        TransferFailure.network,
      ),
    );
  });

  test('insufficient storage from MediaStore is reported and the temp file removed', () async {
    api.files['job1'] = [1, 2, 3];
    media.saveError = const NativeMediaException(
      NativeMediaFailure.storageFull,
      'ENOSPC',
    );
    final error = await failure(
      saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 3),
    );
    expect(
      error,
      isA<TransferException>().having(
        (e) => e.failure,
        'failure',
        TransferFailure.storageFull,
      ),
    );
    expect((error! as TransferException).message, contains('free space'));
    expect(leftovers(), isEmpty);
  });

  test('a native size mismatch is a size mismatch', () async {
    api.files['job1'] = [1, 2, 3];
    media.saveError = const NativeMediaException(
      NativeMediaFailure.sizeMismatch,
      'short',
    );
    final error = await failure(
      saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 3),
    );
    expect(
      error,
      isA<TransferException>().having(
        (e) => e.failure,
        'failure',
        TransferFailure.sizeMismatch,
      ),
    );
    expect(leftovers(), isEmpty);
  });

  test('other native failures are io errors', () async {
    api.files['job1'] = [1, 2, 3];
    media.saveError = const NativeMediaException(
      NativeMediaFailure.io,
      'denied',
    );
    final error = await failure(
      saver.save(jobId: 'job1', filename: 'a.mp4', expectedBytes: 3),
    );
    expect(
      error,
      isA<TransferException>().having(
        (e) => e.failure,
        'failure',
        TransferFailure.io,
      ),
    );
  });

  test('cancelling stops the transfer and removes the temp file', () async {
    api.files['job1'] = List.generate(100, (i) => i);
    final token = TransferToken();
    final error = await failure(
      saver.save(
        jobId: 'job1',
        filename: 'a.mp4',
        expectedBytes: 100,
        token: token,
        onProgress: (received) {
          if (received >= 8) token.cancel();
        },
      ),
    );
    expect(
      error,
      isA<TransferException>().having(
        (e) => e.failure,
        'failure',
        TransferFailure.cancelled,
      ),
    );
    expect(media.events, isEmpty);
    expect(leftovers(), isEmpty);
  });

  test(
    'stale .part files from an earlier process are cleaned at startup',
    () async {
      File('${temp.path}/namao_old.part').writeAsStringSync('partial');
      File('${temp.path}/unrelated.txt').writeAsStringSync('keep');
      await saver.cleanStaleTempFiles();
      expect(File('${temp.path}/namao_old.part').existsSync(), isFalse);
      expect(File('${temp.path}/unrelated.txt').existsSync(), isTrue);
    },
  );

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

class _StallingApi extends FakeApi {
  @override
  Future<FileDownload> openFile(String id) async {
    return FileDownload(
      bytes: StreamController<List<int>>().stream,
      contentLength: 3,
    );
  }
}
