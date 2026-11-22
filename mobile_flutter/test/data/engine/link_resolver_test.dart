import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/data/engine/link_resolver.dart';

/// Answers each request from a script: url -> Location (or null for "not a redirect").
class ScriptedFetcher implements RedirectFetcher {
  ScriptedFetcher(this.script, {this.error});

  final Map<String, String?> script;
  final Object? error;
  final List<String> requested = [];

  @override
  Future<String?> locationOf(Uri url) async {
    requested.add(url.toString());
    final failure = error;
    if (failure != null) throw failure;
    return script[url.toString()];
  }
}

Future<LinkResolveException> failureOf(
  LinkResolver resolver,
  String url,
) async {
  try {
    await resolver.resolve(url);
  } on LinkResolveException catch (e) {
    return e;
  }
  fail('expected $url to fail');
}

void main() {
  test('canonical links are returned untouched without any request', () async {
    final fetcher = ScriptedFetcher({});
    final resolver = LinkResolver(fetcher: fetcher);
    const url = 'https://www.facebook.com/watch/?v=1&t=5';
    expect(await resolver.resolve(url), url);
    expect(
      await resolver.resolve('https://youtu.be/abc'),
      'https://youtu.be/abc',
    );
    expect(fetcher.requested, isEmpty);
  });

  test(
    'fb.watch follows its redirect to the video, keeping the query',
    () async {
      final fetcher = ScriptedFetcher({
        'https://fb.watch/abc/':
            'https://www.facebook.com/watch/?v=740370353488040&mibextid=x',
      });
      final resolver = LinkResolver(fetcher: fetcher);
      expect(
        await resolver.resolve('https://fb.watch/abc/'),
        'https://www.facebook.com/watch/?v=740370353488040&mibextid=x',
      );
    },
  );

  test(
    'a share link goes through several hops and /reels/ is normalised',
    () async {
      final fetcher = ScriptedFetcher({
        'https://www.facebook.com/share/r/1Ab/':
            'https://m.facebook.com/share/r/1Ab/?wtsid=rdr_x',
        'https://m.facebook.com/share/r/1Ab/?wtsid=rdr_x':
            '/reels/123456789?s=yWDuG2',
      });
      final resolver = LinkResolver(fetcher: fetcher);
      expect(
        await resolver.resolve('https://www.facebook.com/share/r/1Ab/'),
        'https://m.facebook.com/reel/123456789?s=yWDuG2',
      );
      expect(fetcher.requested, hasLength(2));
    },
  );

  test('an Instagram share link resolves to the reel', () async {
    final resolver = LinkResolver(
      fetcher: ScriptedFetcher({
        'https://www.instagram.com/share/reel/Bx/':
            'https://www.instagram.com/reel/CxAbCdEfGhI/?igsh=1',
      }),
    );
    expect(
      await resolver.resolve('https://www.instagram.com/share/reel/Bx/'),
      'https://www.instagram.com/reel/CxAbCdEfGhI/?igsh=1',
    );
  });

  test('a plain-http hop is upgraded to https', () async {
    final resolver = LinkResolver(
      fetcher: ScriptedFetcher({
        'https://fb.watch/abc/': 'http://www.facebook.com/watch/?v=1',
      }),
    );
    expect(
      await resolver.resolve('https://fb.watch/abc/'),
      'https://www.facebook.com/watch/?v=1',
    );
  });

  test(
    'a redirect off the platform is refused, however it is disguised',
    () async {
      const refused = [
        'https://evil.example/watch/?v=1',
        'https://www.facebook.com.evil.example/watch/?v=1',
        'https://www.facebook.com@evil.example/watch/?v=1',
        'https://user:pw@www.facebook.com/watch/?v=1',
        'https://www.facebook.com:8443/watch/?v=1',
        'https://www.instagram.com/reel/Cx/',
        'ftp://www.facebook.com/watch/?v=1',
      ];
      for (final target in refused) {
        final resolver = LinkResolver(
          fetcher: ScriptedFetcher({'https://fb.watch/abc/': target}),
        );
        final error = await failureOf(resolver, 'https://fb.watch/abc/');
        expect(error.code, 'link_unresolved', reason: target);
      }
    },
  );

  test('a hop to a login page is reported as login-required', () async {
    final resolver = LinkResolver(
      fetcher: ScriptedFetcher({
        'https://www.facebook.com/share/v/1Ab/': 'https://www.facebook.com/login/?next=https%3A%2F%2Fwww.facebook.com%2Fwatch',
      }),
    );
    expect(
      (await failureOf(resolver, 'https://www.facebook.com/share/v/1Ab/')).code,
      'auth_required',
    );
  });

  test('a link that never reaches a video, or loops, is unresolved', () async {
    final noRedirect = LinkResolver(fetcher: ScriptedFetcher({}));
    expect(
      (await failureOf(noRedirect, 'https://fb.watch/abc/')).code,
      'link_unresolved',
    );

    final loop = LinkResolver(
      fetcher: ScriptedFetcher({
        'https://fb.watch/a/': 'https://fb.watch/b/',
        'https://fb.watch/b/': 'https://fb.watch/a/',
      }),
      maxHops: 4,
    );
    expect(
      (await failureOf(loop, 'https://fb.watch/a/')).code,
      'link_unresolved',
    );
  });

  test('network trouble is retryable connectivity, not a bad link', () async {
    for (final problem in [
      const SocketException('offline'),
      TimeoutException('slow'),
      const HttpException('reset'),
    ]) {
      final resolver = LinkResolver(
        fetcher: ScriptedFetcher({}, error: problem),
      );
      expect(
        (await failureOf(resolver, 'https://fb.watch/abc/')).code,
        'network_transient',
      );
    }
  });

  test(
    'a resolved link is remembered, so lookup then download asks once',
    () async {
      final fetcher = ScriptedFetcher({
        'https://fb.watch/abc/': 'https://www.facebook.com/watch/?v=1',
      });
      final resolver = LinkResolver(fetcher: fetcher);
      await resolver.resolve('https://fb.watch/abc/');
      await resolver.resolve('https://fb.watch/abc/');
      expect(fetcher.requested, hasLength(1));
    },
  );
}
