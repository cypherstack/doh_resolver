import 'dart:async';
import 'dart:convert';
import 'package:doh_resolver/doh_resolver.dart';
import 'package:test/test.dart';

import 'support/fake_transport.dart';

Map<String, Object?> reply({List<Map<String, Object?>>? answers}) => {
      'Status': 0,
      'AD': true,
      'CD': false,
      'TC': false,
      'Question': [
        {'name': 'alice.example.', 'type': 16}
      ],
      'Answer': answers ??
          [rr('alice.example.', 16, 'oa1:xmr recipient_address=valid;')],
    };
Map<String, Object?> rr(String name, int type, String data) => {
      'name': name,
      'type': type,
      'TTL': 60,
      'data': data,
    };
final resolver = Uri.parse('https://dns.example/resolve');
DohResolverJsonResponse decode(Object? json) =>
    DohResolverJsonResponse.fromJson(json, resolver: resolver);

void main() {
  test('only terminal-owner TXT answers are accepted; response retained', () {
    final response = decode(reply(answers: [
      rr('alice.example.', 5, 'pay.example.'),
      rr('pay.example.', 16, 'one'),
      rr('pay.example.', 16, 'two'),
      rr('evil.example.', 16, 'evil')
    ]));
    final result = response.authenticatedTxt('Alice.Example.',
        txtFormat: DohResolverTxtFormat.raw);
    expect(result.records.map((r) => r.text), ['one', 'two']);
    expect(result.canonicalName, 'pay.example');
    expect(result.aliases, hasLength(1));
    expect(result.response, same(response));
    expect(result.records.first.ttl, 60);
    expect(result, isA<DohResolverTxtResult>());
  });
  for (final field in ['AD', 'CD', 'TC']) {
    test('missing or unacceptable $field never authenticates', () {
      for (final body in [
        reply()..remove(field),
        reply()..[field] = field != 'AD'
      ]) {
        expect(
            () => decode(body).authenticatedTxt('alice.example',
                txtFormat: DohResolverTxtFormat.raw),
            throwsA(isA<DohResolverAuthenticationUnavailableException>()));
      }
    });
  }
  test('DNS error preserves status without inferring bogus or unsigned', () {
    expect(
        () => decode(reply()..['Status'] = 2).authenticatedTxt('alice.example',
            txtFormat: DohResolverTxtFormat.raw),
        throwsA(isA<DohResolverQueryFailedException>()
            .having((e) => e.rcode, 'rcode', 2)));
  });
  test('ttl is the minimum over the CNAME chain and null for NODATA', () {
    DohResolverTxtResult txt(List<Map<String, Object?>> answers) =>
        decode(reply(answers: answers)).authenticatedTxt('alice.example',
            txtFormat: DohResolverTxtFormat.raw);
    expect(
        txt([
          rr('alice.example', 5, 'pay.example')..['TTL'] = 30,
          rr('pay.example', 5, 'txt.example')..['TTL'] = 300,
          rr('txt.example', 16, 'one')..['TTL'] = 90,
          rr('txt.example', 16, 'two')..['TTL'] = 45,
        ]).ttl,
        30);
    expect(txt([rr('alice.example', 16, 'x')..['TTL'] = 7]).ttl, 7);
    expect(txt([rr('alice.example', 5, 'pay.example')]).ttl, isNull);
    expect(txt([]).ttl, isNull);
  });
  test('a result can be built directly, e.g. for fakes', () {
    final bytes = utf8.encode('oa1:xmr recipient_address=valid;');
    final records = [
      DohResolverTxtRecord(name: 'a.example', ttl: 9, bytes: bytes)
    ];
    final result = DohResolverTxtResult(
        question: 'a.example',
        canonicalName: 'a.example',
        resolver: resolver,
        records: records);
    expect(result.records.single.text, 'oa1:xmr recipient_address=valid;');
    expect(result.aliases, isEmpty);
    expect(result.response, isNull);
    expect(result.ttl, 9);
    expect(() => result.records.add(records.single), throwsUnsupportedError);
    expect(() => DohResolverTxtRecord(name: 'a.example', ttl: 1, bytes: [256]),
        throwsArgumentError);
  });
  test('Status must be an in-range RCODE', () {
    for (final status in [-1, 0x10000, 1.0, '0', null]) {
      expect(() => decode(reply()..['Status'] = status),
          throwsA(isA<DohResolverMalformedResponseException>()),
          reason: '$status');
    }
    expect(decode(reply()..['Status'] = 0xffff).status, 0xffff);
  });
  test('maxAnswers bounds the question and answer lists alike', () {
    final question = {'name': 'alice.example.', 'type': 16};
    final answer = rr('alice.example.', 16, 'x');
    for (final (field, item) in [('Question', question), ('Answer', answer)]) {
      final body = reply()..[field] = List.filled(3, item);
      expect(
          () => DohResolverJsonResponse.fromJson(body,
              resolver: resolver, maxAnswers: 2),
          throwsA(isA<DohResolverResponseTooLargeException>()),
          reason: field);
      expect(
          DohResolverJsonResponse.fromJson(body,
              resolver: resolver, maxAnswers: 3),
          isA<DohResolverJsonResponse>(),
          reason: field);
    }
    expect(
        () => DohResolverJsonResponse.fromJson(reply(),
            resolver: resolver, maxAnswers: -1),
        throwsArgumentError);
  });
  test('the sealed resolver root catches its named leaves', () {
    expect(const DohResolverAliasLoopException('loop'),
        isA<DohResolverException>());
    expect(
        const DohResolverLookupTimeoutException('late',
            timeout: Duration(seconds: 12)),
        isA<DohResolverException>());
    expect(const DohResolverQueryFailedException('x', rcode: 3).rcode, 3);
    expect(const DohResolverQueryFailedException('failed', rcode: 3).toString(),
        'DohResolverQueryFailedException(rcode: 3): failed');
  });
  for (final questions in [
    <Object>[],
    [
      {'name': 'other.example', 'type': 16}
    ],
    [
      {'name': 'alice.example', 'type': 1}
    ],
    [
      {'name': 'alice.example', 'type': 16},
      {'name': 'alice.example', 'type': 16}
    ]
  ]) {
    test('rejects mismatched questions $questions', () {
      expect(
          () => decode(reply()..['Question'] = questions).authenticatedTxt(
              'alice.example',
              txtFormat: DohResolverTxtFormat.raw),
          throwsA(isA<DohResolverQuestionMismatchException>()));
    });
  }
  test('no answers is distinct from DNS failure', () {
    expect(
        decode(reply()..remove('Answer'))
            .authenticatedTxt('alice.example',
                txtFormat: DohResolverTxtFormat.raw)
            .records,
        isEmpty);
  });
  test('rejects loops, ambiguous owners and excessive chains', () {
    expect(
        () => decode(reply(answers: [rr('alice.example', 5, 'alice.example')]))
            .authenticatedTxt('alice.example',
                txtFormat: DohResolverTxtFormat.raw),
        throwsA(isA<DohResolverAliasLoopException>()));
    for (final records in [
      [rr('alice.example', 5, 'pay.example'), rr('alice.example', 16, 'txt')],
      [
        rr('alice.example', 5, 'pay.example'),
        rr('alice.example', 5, 'pay.example')
      ]
    ]) {
      expect(
          () => decode(reply(answers: records)).authenticatedTxt(
              'alice.example',
              txtFormat: DohResolverTxtFormat.raw),
          throwsA(isA<DohResolverAliasAmbiguousException>()));
    }
    final chain = [
      rr('alice.example', 5, 'hop0.example'),
      for (var i = 0; i < 7; i++) rr('hop$i.example', 5, 'hop${i + 1}.example'),
      rr('hop7.example', 16, 'txt')
    ];
    expect(
        () => decode(reply(answers: chain)).authenticatedTxt('alice.example',
            txtFormat: DohResolverTxtFormat.raw),
        throwsA(isA<DohResolverAliasTooLongException>()));
  });
  test('rejects invalid TTLs, names, record data, types and response shape',
      () {
    for (final body in [
      null,
      <Object>[],
      reply()..['Answer'] = 'bad',
      reply()..['AD'] = 'true',
      reply(answers: [rr('alice.example', 16, 'x')..['TTL'] = -1]),
      reply(answers: [rr('alice.example', 16, 'x')..['TTL'] = 0x100000000]),
      reply(answers: [rr('alice.example', 16, 'x')..['data'] = 7]),
      reply(answers: [rr('alice.example', 16, 'x')..['type'] = '16']),
      reply(answers: [rr('alice.example', 16, 'x')..['type'] = 0x10000]),
      reply()
        ..['Question'] = [
          {'name': 'alice.example', 'type': -1}
        ],
      reply(answers: [rr('K.example', 16, 'x')])
    ]) {
      expect(() => decode(body), throwsA(isA<DohResolverException>()));
    }
    expect(
        () => decode(reply(
            answers: List.generate(65, (_) => rr('alice.example', 16, 'x')))),
        throwsA(isA<DohResolverResponseTooLargeException>()));
  });
  test('TXT chunks and decimal UTF-8 octets are decoded without loss', () {
    expect(
        utf8.decode(decodeDohResolverTxtBytes(
            r'"oa1:xmr recipient_" "address=valid;"',
            DohResolverTxtFormat.quoted)),
        'oa1:xmr recipient_address=valid;');
    expect(
        utf8.decode(decodeDohResolverTxtBytes(
            r'"\195\169\032\""', DohResolverTxtFormat.quoted)),
        'é "');
    expect(
        utf8.decode(decodeDohResolverTxtBytes(
            '"emoji 😀"', DohResolverTxtFormat.quoted)),
        'emoji 😀');
    expect(decodeDohResolverTxtBytes(r'"\255"', DohResolverTxtFormat.quoted),
        [255]);
    expect(
        utf8.decode(
            decodeDohResolverTxtBytes('"\\😀"', DohResolverTxtFormat.quoted)),
        '😀');
    expect(() => DohResolverTxtRecord(name: 'x', ttl: 1, bytes: [255]).text,
        throwsA(isA<DohResolverMalformedResponseException>()));
  });
  test('TTLs with the high bit set are treated as zero', () {
    for (final (raw, ttl) in [(0x7fffffff, 0x7fffffff), (0x80000000, 0)]) {
      final result = decode(reply(answers: [
        rr('alice.example', 5, 'pay.example')..['TTL'] = raw,
        rr('pay.example', 16, 'x')..['TTL'] = raw,
      ])).authenticatedTxt('alice.example',
          txtFormat: DohResolverTxtFormat.raw);
      expect(result.records.single.ttl, ttl);
      expect(result.aliases.single.ttl, ttl);
    }
  });
  test('raw TXT is taken verbatim and quoted TXT must be quoted', () {
    for (final value in ['"hello"', r'\065 x', '"unmatched']) {
      expect(
          utf8.decode(
              decodeDohResolverTxtBytes(value, DohResolverTxtFormat.raw)),
          value);
    }
    expect(
        () =>
            decodeDohResolverTxtBytes('lone \ud800', DohResolverTxtFormat.raw),
        throwsA(isA<DohResolverMalformedResponseException>()));
    expect(
        decodeDohResolverTxtBytes('""', DohResolverTxtFormat.quoted), isEmpty);
    expect(decodeDohResolverTxtBytes(' "" "" ', DohResolverTxtFormat.quoted),
        isEmpty);
    for (final value in ['hello', 'a "b"', '', '   ']) {
      expect(
          () => decodeDohResolverTxtBytes(value, DohResolverTxtFormat.quoted),
          throwsA(isA<DohResolverMalformedResponseException>()));
    }
  });
  test('known resolvers get their TXT format and media type; others choose',
      () {
    DohResolver resolverFor(String url) => DohResolver(
        transport: FakeDohResolverTransport(), endpoint: Uri.parse(url));
    final google = DohResolver(transport: FakeDohResolverTransport());
    expect(google.txtFormat, DohResolverTxtFormat.raw);
    expect(google.mediaType, 'application/json');
    for (final host in ['dns.google', '8.8.8.8']) {
      expect(resolverFor('https://$host/resolve').txtFormat,
          DohResolverTxtFormat.raw);
      expect(
          resolverFor('https://$host/resolve').mediaType, 'application/json');
    }
    for (final host in [
      'cloudflare-dns.com',
      'security.cloudflare-dns.com',
      'one.one.one.one',
      '1.1.1.1'
    ]) {
      final resolver = resolverFor('https://$host/dns-query');
      expect(resolver.txtFormat, DohResolverTxtFormat.quoted);
      expect(resolver.mediaType, 'application/dns-json');
    }
    final unknown = Uri.parse('https://resolver.example/resolve');
    expect(() => resolverFor('$unknown'), throwsArgumentError);
    for (final (format, type) in [
      (DohResolverTxtFormat.raw, null),
      (null, 'application/dns-json'),
    ]) {
      expect(
          () => DohResolver(
              transport: FakeDohResolverTransport(),
              endpoint: unknown,
              txtFormat: format,
              mediaType: type),
          throwsArgumentError);
    }
    final custom = DohResolver(
        transport: FakeDohResolverTransport(),
        endpoint: Uri.parse('https://dns.google/resolve'),
        txtFormat: DohResolverTxtFormat.quoted,
        mediaType: 'application/dns-json');
    expect(custom.txtFormat, DohResolverTxtFormat.quoted);
    expect(custom.mediaType, 'application/dns-json');
  });
  test('mediaType must be a bare type/subtype', () {
    for (final type in ['', 'application/json; charset=utf-8', 'a /b']) {
      expect(
          () => DohResolver(
              transport: FakeDohResolverTransport(),
              endpoint: Uri.parse('https://resolver.example/resolve'),
              txtFormat: DohResolverTxtFormat.raw,
              mediaType: type),
          throwsA(
              isA<ArgumentError>().having((e) => e.name, 'name', 'mediaType')));
    }
  });
  test('the transport receives the media type', () {
    final transport = FakeDohResolverTransport();
    DohResolver(transport: transport).startTxtLookup('alice.example');
    DohResolver(
            transport: transport,
            endpoint: Uri.parse('https://cloudflare-dns.com/dns-query'))
        .startTxtLookup('alice.example');
    DohResolver(
            transport: transport,
            endpoint: Uri.parse('https://resolver.example/resolve'),
            txtFormat: DohResolverTxtFormat.raw,
            mediaType: 'application/x-custom')
        .startTxtLookup('alice.example');
    expect(transport.mediaTypes,
        ['application/json', 'application/dns-json', 'application/x-custom']);
  });
  for (final (endpoint, data, text) in [
    ('https://dns.google/resolve', '"hello"', '"hello"'),
    ('https://cloudflare-dns.com/dns-query', r'"hel" "lo\033"', 'hello!'),
  ]) {
    test('$endpoint TXT $data decodes to $text', () async {
      final transport = FakeDohResolverTransport();
      final result =
          DohResolver(transport: transport, endpoint: Uri.parse(endpoint))
              .lookupTxt('alice.example');
      transport.respond(DohResolverResponse(utf8.encode(
          jsonEncode(reply(answers: [rr('alice.example', 16, data)])))));
      expect((await result).records.single.text, text);
    });
  }
  test('malformed and overlong TXT cannot turn into recipient data', () {
    for (final s in [
      '"unterminated',
      '"one" junk',
      r'"\999"',
      r'"\12"',
      r'"\1"',
      r'"\1x2"',
      '"trailing\\',
      'lone \ud800',
      '"lone \udc00"',
      '"\\\ud800"',
      '"\ud800 x"',
    ]) {
      expect(() => decodeDohResolverTxtBytes(s, DohResolverTxtFormat.quoted),
          throwsA(isA<DohResolverMalformedResponseException>()));
    }
    expect(
        () =>
            decodeDohResolverTxtBytes('a' * 8193, DohResolverTxtFormat.quoted),
        throwsA(isA<DohResolverResponseTooLargeException>()));
  });
  test('requests privacy flags and propagates the authenticated result',
      () async {
    final transport = FakeDohResolverTransport();
    final resolver = DohResolver(transport: transport);
    final query = resolver.startTxtLookup('alice.example');
    expect(transport.uri!.queryParameters, {
      'name': 'alice.example.',
      'type': 'TXT',
      'do': 'true',
      'cd': 'false',
      'edns_client_subnet': '0.0.0.0/0',
      'random_padding': matches(r'^X+$'),
    });
    expect(transport.uri.toString().length % 128, 0);
    transport.respond(DohResolverResponse(utf8.encode(jsonEncode(reply()))));
    expect((await query.result).records.single.text,
        'oa1:xmr recipient_address=valid;');
    query.cancel();
    expect(transport.cancelled, isFalse,
        reason: 'a completed transport operation is never cancelled');
  });
  test('preserves repeated endpoint parameters; resolver keys override', () {
    final transport = FakeDohResolverTransport();
    DohResolver(
            txtFormat: DohResolverTxtFormat.raw,
            mediaType: 'application/dns-json',
            transport: transport,
            endpoint: Uri.parse('https://dns.example/resolve'
                '?tag=first&tag=second&name=evil&type=A&type=AAAA'))
        .startTxtLookup('alice.example');
    final sent = transport.uri!.queryParametersAll;
    expect(sent['tag'], ['first', 'second']);
    expect(sent['name'], ['alice.example.']);
    expect(sent['type'], ['TXT']);
    expect(transport.uri.toString().length % 128, 0);
  });
  test('padding hides name length and keeps endpoint parameters', () {
    final lengths = <int>{};
    for (final name in ['a.example', 'abcd.example']) {
      final transport = FakeDohResolverTransport();
      DohResolver(
              txtFormat: DohResolverTxtFormat.raw,
              mediaType: 'application/dns-json',
              transport: transport,
              endpoint: Uri.parse('https://dns.example/resolve?ct=x'))
          .startTxtLookup(name);
      expect(transport.uri!.queryParameters['ct'], 'x');
      expect(transport.uri!.queryParameters['name'], '$name.');
      lengths.add(transport.uri.toString().length);
    }
    expect(lengths, {128});
  });
  test('an invalid name fails the result without reaching the transport',
      () async {
    final fake = FakeDohResolverTransport();
    final operation = DohResolver(transport: fake).startTxtLookup('a..example');
    await expectLater(
        operation.result, throwsA(isA<DohResolverInvalidNameException>()));
    operation.cancel();
    expect(fake.uri, isNull);
  });
  test('dropped synchronous and asynchronous failures stay handled', () async {
    final errors = <Object>[];
    await runZonedGuarded(() async {
      DohResolver(transport: FakeDohResolverTransport())
          .startTxtLookup('a..example');
      final fake = FakeDohResolverTransport();
      DohResolver(transport: fake).startTxtLookup('a.example');
      fake.fail(StateError('down'));
      await Future<void>.delayed(Duration.zero);
    }, (error, _) => errors.add(error));

    expect(errors, isEmpty);
  });
  test('endpoints with undecodable parameters or ports are rejected up front',
      () {
    for (final endpoint in [
      'https://resolver.example/resolve?x=%FF',
      'https://resolver.example/resolve?%C3=1',
      'https://resolver.example:0/resolve',
      'https://resolver.example:70000/resolve',
      'https://resolver.example:99999999999999999999/resolve',
    ]) {
      expect(
          () => DohResolver(
              txtFormat: DohResolverTxtFormat.raw,
              mediaType: 'application/dns-json',
              transport: FakeDohResolverTransport(),
              endpoint: Uri.parse(endpoint)),
          throwsArgumentError);
    }
  });
  test('a transport that throws on start fails the result', () async {
    for (final (thrown, expected) in [
      (
        const DohResolverCancelledException('closed',
            reason: DohResolverCancellationReason.transportClosed),
        isA<DohResolverCancelledException>().having((error) => error.reason,
            'reason', DohResolverCancellationReason.transportClosed)
      ),
      (
        StateError('broken'),
        isA<DohResolverTransportException>()
            .having((error) => error.cause, 'cause', isA<StateError>())
            .having(
                (error) => error.causeStackTrace, 'causeStackTrace', isNotNull)
      ),
    ]) {
      final fake = FakeDohResolverTransport()..throwOnStart = thrown;
      await expectLater(DohResolver(transport: fake).lookupTxt('a.example'),
          throwsA(expected));
    }
  });
  test('resolver exceptions from the port pass through unchanged; others wrap',
      () async {
    const passed = <DohResolverException>[
      DohResolverHttpStatusException('opaque', statusCode: 502),
      DohResolverTransportTimeoutException('opaque',
          timeout: Duration(seconds: 9)),
      DohResolverCancelledException('opaque',
          reason: DohResolverCancellationReason.transportClosed),
      DohResolverResponseTooLargeException('opaque',
          kind: DohResolverLimitKind.responseBytes, maximum: 2048),
      DohResolverMalformedResponseException('opaque'),
      DohResolverQuestionMismatchException('opaque'),
      DohResolverTransportException('opaque'),
    ];
    for (final error in passed) {
      final fake = FakeDohResolverTransport([error]);
      await expectLater(DohResolver(transport: fake).lookupTxt('a.example'),
          throwsA(same(error)),
          reason: '$error');
    }
    final cause = StateError('socket failure');
    final fake = FakeDohResolverTransport([cause]);
    await expectLater(
        DohResolver(transport: fake).lookupTxt('a.example'),
        throwsA(isA<DohResolverTransportException>()
            .having((error) => error.cause, 'cause', same(cause))
            .having((error) => error.causeStackTrace, 'causeStackTrace',
                isNotNull)));
  });
  test('scripted responses answer consecutive lookups in order', () async {
    final fake = FakeDohResolverTransport([
      DohResolverResponse(utf8.encode(jsonEncode(reply()))),
      const DohResolverHttpStatusException('unavailable', statusCode: 503),
    ]);
    final resolver = DohResolver(transport: fake);
    expect((await resolver.lookupTxt('alice.example')).records, hasLength(1));
    await expectLater(resolver.lookupTxt('alice.example'),
        throwsA(isA<DohResolverHttpStatusException>()));
    expect(fake.requests, hasLength(2));
  });
  test('a throwing transport cancel cannot escape the deadline', () async {
    final transport = FakeDohResolverTransport()..throwOnCancel = true;
    final query = DohResolver(
            transport: transport, timeout: const Duration(milliseconds: 20))
        .startTxtLookup('alice.example');
    await expectLater(
        query.result, throwsA(isA<DohResolverLookupTimeoutException>()));
    query.cancel();
  });
  for (final cancel in [true, false]) {
    test(
        '${cancel ? 'cancellation' : 'deadline'} aborts the underlying operation',
        () async {
      final transport = FakeDohResolverTransport();
      final resolver = DohResolver(
          transport: transport, timeout: const Duration(milliseconds: 30));
      final query = resolver.startTxtLookup('alice.example');
      final failed = expectLater(
          query.result,
          throwsA(cancel
              ? isA<DohResolverCancelledException>()
              : isA<DohResolverLookupTimeoutException>()));
      if (cancel) query.cancel();
      await failed;
      expect(transport.cancelled, isTrue);
      transport.respond(DohResolverResponse(utf8.encode(jsonEncode(reply()))));
      await Future<void>.delayed(Duration.zero);
    });
  }
  test('HTTP cache age reduces TTLs and never drives them negative', () async {
    for (final (age, ttl) in [(0, 60), (25, 35), (60, 0), (250, 0)]) {
      final transport = FakeDohResolverTransport();
      final result =
          DohResolver(transport: transport).lookupTxt('alice.example');
      transport.respond(DohResolverResponse(
          utf8.encode(jsonEncode(reply(answers: [
            rr('alice.example', 5, 'pay.example'),
            rr('pay.example', 16, 'x'),
          ]))),
          age: Duration(seconds: age)));
      final txt = await result;
      expect(txt.records.single.ttl, ttl);
      expect(txt.aliases.single.ttl, ttl);
      expect(txt.response!.age, Duration(seconds: age));
    }
    expect(() => DohResolverResponse([], age: const Duration(seconds: -1)),
        throwsArgumentError);
  });
  test('unexpected parsing errors complete with an exception', () async {
    final transport = FakeDohResolverTransport();
    final result = DohResolver(transport: transport).lookupTxt('alice.example');
    transport.respond(_ThrowingResponse());
    await expectLater(result.timeout(const Duration(seconds: 1)),
        throwsA(isA<DohResolverMalformedResponseException>()));
  });
  test('rejects JSON and injected response limit violations', () async {
    for (final response in [
      DohResolverResponse(utf8.encode('bad json')),
      DohResolverResponse(List.filled(65537, 0))
    ]) {
      final transport = FakeDohResolverTransport();
      final result =
          DohResolver(transport: transport).lookupTxt('alice.example');
      transport.respond(response);
      await expectLater(result, throwsA(isA<DohResolverException>()));
      expect(transport.cancelled, isFalse);
    }
    final failing = FakeDohResolverTransport();
    final failed = DohResolver(transport: failing).lookupTxt('alice.example');
    failing.fail(StateError('down'));
    await expectLater(failed, throwsA(isA<DohResolverTransportException>()));
    expect(failing.cancelled, isFalse);
  });
}

class _ThrowingResponse implements DohResolverResponse {
  @override
  Duration get age => Duration.zero;
  @override
  List<int> get body => throw StateError('broken body');
}
