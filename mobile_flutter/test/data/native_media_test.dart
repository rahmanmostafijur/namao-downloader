import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/api/api_exception.dart';
import 'package:namao_app/core/uuid.dart';
import 'package:namao_app/data/native_media.dart';
import 'package:namao_app/features/downloads/action_errors.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.namao.flutter/media');
  const media = MethodChannelNativeMedia();
  final calls = <MethodCall>[];

  void handle(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          calls.add(call);
          return handler(call);
        });
  }

  setUp(calls.clear);
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test(
    'saveToDownloads sends the contract arguments and parses the real name',
    () async {
      handle(
        (call) async => {
          'uri': 'content://media/external/downloads/7',
          'displayName': 'Video (1).mp4',
          'sizeBytes': 1234,
        },
      );
      final saved = await media.saveToDownloads(
        tempPath: '/cache/x.part',
        displayName: 'Video.mp4',
        mimeType: 'video/mp4',
        expectedBytes: 1234,
      );
      expect(calls.single.method, 'saveToDownloads');
      expect(calls.single.arguments, {
        'tempPath': '/cache/x.part',
        'displayName': 'Video.mp4',
        'mimeType': 'video/mp4',
        'expectedBytes': 1234,
      });
      expect(
        saved.displayName,
        'Video (1).mp4',
        reason: 'the renamed duplicate is what gets recorded',
      );
      expect(saved.uri, 'content://media/external/downloads/7');
      expect(saved.sizeBytes, 1234);
    },
  );

  test('platform error codes map to typed failures', () async {
    for (final (code, failure) in [
      ('storage_full', NativeMediaFailure.storageFull),
      ('size_mismatch', NativeMediaFailure.sizeMismatch),
      ('no_app', NativeMediaFailure.noAppToOpen),
      ('not_found', NativeMediaFailure.notFound),
      ('io', NativeMediaFailure.io),
    ]) {
      handle((call) async => throw PlatformException(code: code, message: 'm'));
      await expectLater(
        media.open('content://x', 'video/mp4'),
        throwsA(
          isA<NativeMediaException>().having(
            (e) => e.failure,
            'failure',
            failure,
          ),
        ),
        reason: code,
      );
    }
  });

  test('a malformed save result is an io failure, not a crash', () async {
    handle((call) async => {'uri': 5});
    await expectLater(
      media.saveToDownloads(
        tempPath: 'p',
        displayName: 'n',
        mimeType: 'm',
        expectedBytes: 1,
      ),
      throwsA(isA<NativeMediaException>()),
    );
  });

  test('a missing native implementation is reported, not thrown raw', () async {
    await expectLater(media.appVersion(), throwsA(isA<NativeMediaException>()));
  });

  test('simple calls pass their arguments', () async {
    handle((call) async => call.method == 'appVersion' ? '1.2.3 (4)' : true);
    expect(await media.exists('content://x'), isTrue);
    await media.share('content://x', 'video/mp4', 'T');
    await media.startTransfer('Saving');
    await media.updateTransfer(40, 'Saving 40%');
    await media.stopTransfer();
    expect(await media.requestNotificationPermission(), isTrue);
    expect(await media.appVersion(), '1.2.3 (4)');
    expect(calls.map((c) => c.method), [
      'exists',
      'share',
      'startTransfer',
      'updateTransfer',
      'stopTransfer',
      'requestNotificationPermission',
      'appVersion',
    ]);
    expect(calls[3].arguments, {'percent': 40, 'text': 'Saving 40%'});
  });

  group('newUuid', () {
    test('is a version-4 UUID', () {
      final id = newUuid(Random(1));
      expect(
        id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test('is unique per call with the secure generator', () {
      expect({for (var i = 0; i < 500; i++) newUuid()}.length, 500);
    });
  });

  test('action errors say something useful', () {
    expect(
      describeActionError(const ApiException.network()),
      contains('reach'),
    );
    expect(
      describeActionError(StateError('x')),
      "Couldn't complete that action.",
    );
  });
}
