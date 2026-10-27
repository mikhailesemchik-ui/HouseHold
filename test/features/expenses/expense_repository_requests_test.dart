import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/expenses/data/expense_repository.dart';
import 'package:household_os/features/expenses/data/financial_submit_outcome.dart';
import 'package:household_os/features/expenses/domain/financial_request.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A local HTTP server standing in for PostgREST, so the repository is checked
/// at the real network-request boundary rather than through a fake.
class _FakePostgrest {
  _FakePostgrest._(this._server);

  final HttpServer _server;
  final List<({String path, Map<String, dynamic> body})> requests = [];

  /// Scripted responses, consumed in order. `null` means success with an
  /// empty JSON result; a function takes control of the response.
  final List<Future<void> Function(HttpResponse)?> script = [];

  static Future<_FakePostgrest> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakePostgrest._(server);
    server.listen(fake._handle);
    return fake;
  }

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> _handle(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    requests.add((
      path: request.uri.path,
      body: raw.isEmpty ? {} : jsonDecode(raw) as Map<String, dynamic>,
    ));
    final step = script.isEmpty ? null : script.removeAt(0);
    if (step != null) {
      await step(request.response);
      return;
    }
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write('null');
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

Future<void> Function(HttpResponse) _json(
  int status,
  Map<String, dynamic> body,
) => (res) async {
  res
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  await res.close();
};

Future<void> _dropConnection(HttpResponse res) async {
  final socket = await res.detachSocket(writeHeaders: false);
  socket.destroy();
}

void main() {
  late _FakePostgrest server;
  late SupabaseClient client;
  late ExpenseRepository repo;

  setUp(() async {
    server = await _FakePostgrest.start();
    client = SupabaseClient(server.url, 'test-anon-key');
    repo = ExpenseRepository(client);
  });

  tearDown(() async {
    await client.dispose();
    await server.close();
  });

  Future<void> createExpense({String? requestId}) =>
      repo.createEqualSplitExpense(
        householdId: 'hh',
        title: 'Groceries',
        amountCents: 3000,
        currency: 'EUR',
        paidBy: 'u0',
        participantIds: const ['u0', 'u1'],
        requestId: requestId,
      );

  Future<void> createSettlement({String? requestId, int amount = 1250}) =>
      repo.createSettlement(
        householdId: 'hh',
        fromUserId: 'u0',
        toUserId: 'u1',
        amountCents: amount,
        currency: 'EUR',
        note: 'cash',
        requestId: requestId,
      );

  group('request maps sent to PostgREST', () {
    test(
      'the expense RPC carries p_request_id and every other parameter',
      () async {
        final id = generateRequestId();
        await createExpense(requestId: id);

        expect(server.requests, hasLength(1));
        expect(
          server.requests.single.path,
          '/rest/v1/rpc/create_equal_split_expense',
        );
        expect(server.requests.single.body, {
          'p_household_id': 'hh',
          'p_title': 'Groceries',
          'p_amount_cents': 3000,
          'p_currency': 'EUR',
          'p_paid_by': 'u0',
          'p_participant_ids': ['u0', 'u1'],
          'p_request_id': id,
        });
      },
    );

    test(
      'the settlement RPC carries p_request_id and every other parameter',
      () async {
        final id = generateRequestId();
        await createSettlement(requestId: id);

        expect(server.requests.single.path, '/rest/v1/rpc/create_settlement');
        expect(server.requests.single.body, {
          'p_household_id': 'hh',
          'p_from_user_id': 'u0',
          'p_to_user_id': 'u1',
          'p_amount_cents': 1250,
          'p_currency': 'EUR',
          'p_note': 'cash',
          'p_request_id': id,
        });
      },
    );

    test(
      'without a request id the key is omitted, as older clients send it',
      () async {
        await createExpense();
        await createSettlement();
        expect(server.requests.map((r) => r.body.containsKey('p_request_id')), [
          false,
          false,
        ]);
      },
    );

    test(
      'a retry sends the identical UUID and a new operation sends a new one',
      () async {
        final first = generateRequestId();
        await createSettlement(requestId: first);
        await createSettlement(requestId: first);
        final second = generateRequestId();
        await createSettlement(requestId: second, amount: 1250);

        final ids = server.requests.map((r) => r.body['p_request_id']).toList();
        expect(ids, [first, first, second]);
        expect(second, isNot(first));
      },
    );
  });

  group('failure classification against real client errors', () {
    Future<FinancialSubmitOutcome> outcomeOfNextCall() async {
      try {
        await createSettlement(requestId: generateRequestId());
      } catch (e) {
        return classifyFinancialSubmitError(e);
      }
      fail('the call was expected to fail');
    }

    test('a dropped connection is ambiguous', () async {
      server.script.add(_dropConnection);
      expect(await outcomeOfNextCall(), FinancialSubmitOutcome.ambiguous);
    });

    test(
      'a gateway error without a database error body is ambiguous',
      () async {
        server.script.add((res) async {
          res
            ..statusCode = 503
            ..write('Service Unavailable');
          await res.close();
        });
        expect(await outcomeOfNextCall(), FinancialSubmitOutcome.ambiguous);
      },
    );

    test('a database refusal is definite', () async {
      server.script.add(
        _json(400, {'code': 'HS007', 'message': 'not a party'}),
      );
      expect(await outcomeOfNextCall(), FinancialSubmitOutcome.rejected);
    });

    test('HF003 and HF002 are recognised', () async {
      server.script.add(_json(400, {'code': 'HF003', 'message': 'removed'}));
      expect(await outcomeOfNextCall(), FinancialSubmitOutcome.alreadyRemoved);
      server.script.add(_json(400, {'code': 'HF002', 'message': 'different'}));
      expect(await outcomeOfNextCall(), FinancialSubmitOutcome.keyReused);
    });

    test(
      'a connection error raised by the database itself stays ambiguous',
      () async {
        server.script.add(
          _json(503, {'code': '08006', 'message': 'connection failure'}),
        );
        expect(await outcomeOfNextCall(), FinancialSubmitOutcome.ambiguous);
      },
    );
  });
}
