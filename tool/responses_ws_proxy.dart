import 'dart:async';
import 'dart:io';

import 'package:web_socket_channel/io.dart';

Future<void> main(List<String> args) async {
  final options = _ProxyOptions.parse(args);
  final envFile = _readEnvFiles(options.envFiles);
  final apiKey =
      Platform.environment['OPENAI_API_KEY'] ?? envFile['OPENAI_API_KEY'] ?? '';
  if (apiKey.isEmpty) {
    stderr.writeln(
      'OPENAI_API_KEY is required in the environment, .env.flutter, or .env.',
    );
    exitCode = 64;
    return;
  }

  final token =
      options.token ??
      Platform.environment['PINGPONG_WS_PROXY_TOKEN'] ??
      envFile['PINGPONG_WS_PROXY_TOKEN'] ??
      '';
  final upstreamUri = Uri.parse(
    Platform.environment['OPENAI_RESPONSES_WS_URL'] ??
        envFile['OPENAI_RESPONSES_WS_URL'] ??
        'wss://api.openai.com/v1/responses',
  );
  final server = await HttpServer.bind(options.host, options.port);
  stdout.writeln(
    'responses ws proxy listening on ws://${options.host}:${options.port}/v1/responses',
  );

  await for (final request in server) {
    unawaited(
      _handleRequest(
        request,
        apiKey: apiKey,
        token: token,
        upstreamUri: upstreamUri,
      ),
    );
  }
}

Future<void> _handleRequest(
  HttpRequest request, {
  required String apiKey,
  required String token,
  required Uri upstreamUri,
}) async {
  if (request.uri.path == '/healthz') {
    _writeText(request, HttpStatus.ok, 'ok');
    return;
  }
  if (request.uri.path != '/v1/responses') {
    _writeText(request, HttpStatus.notFound, 'not found');
    return;
  }
  if (token.isNotEmpty && request.uri.queryParameters['token'] != token) {
    _writeText(request, HttpStatus.unauthorized, 'unauthorized');
    return;
  }
  if (!WebSocketTransformer.isUpgradeRequest(request)) {
    _writeText(request, HttpStatus.upgradeRequired, 'websocket required');
    return;
  }

  WebSocket? client;
  IOWebSocketChannel? upstream;
  try {
    client = await WebSocketTransformer.upgrade(request);
    upstream = IOWebSocketChannel.connect(
      upstreamUri,
      headers: {'Authorization': 'Bearer $apiKey'},
      connectTimeout: const Duration(seconds: 10),
      pingInterval: const Duration(seconds: 20),
    );
    await upstream.ready.timeout(const Duration(seconds: 10));
  } catch (error) {
    stderr.writeln('proxy connect failed: $error');
    await _closeClient(client, WebSocketStatus.internalServerError, 'upstream');
    return;
  }

  final done = Completer<void>();
  late final StreamSubscription clientSub;
  late final StreamSubscription upstreamSub;

  void closeBoth(int code, String reason) {
    if (!done.isCompleted) done.complete();
    unawaited(_closeClient(client, code, reason));
    unawaited(upstream?.sink.close(code, reason));
  }

  clientSub = client.listen(
    upstream.sink.add,
    onError: (_) => closeBoth(WebSocketStatus.protocolError, 'client error'),
    onDone: () => closeBoth(WebSocketStatus.normalClosure, 'client closed'),
    cancelOnError: true,
  );
  upstreamSub = upstream.stream.listen(
    client.add,
    onError: (_) => closeBoth(WebSocketStatus.protocolError, 'upstream error'),
    onDone: () => closeBoth(WebSocketStatus.normalClosure, 'upstream closed'),
    cancelOnError: true,
  );

  await done.future;
  try {
    await Future.wait([clientSub.cancel(), upstreamSub.cancel()]);
  } catch (_) {
    // Cleanup should not keep the process from accepting new connections.
  }
}

void _writeText(HttpRequest request, int status, String text) {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.text
    ..write(text);
  unawaited(request.response.close());
}

Future<void> _closeClient(WebSocket? client, int code, String reason) async {
  if (client == null) return;
  try {
    await client.close(code, reason);
  } catch (_) {
    // The socket may already be closed by the peer.
  }
}

Map<String, String> _readEnvFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return {};
  final values = <String, String>{};
  for (final rawLine in file.readAsLinesSync()) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final index = line.indexOf('=');
    if (index <= 0) continue;
    final key = line.substring(0, index).trim();
    var value = line.substring(index + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    values[key] = value;
  }
  return values;
}

Map<String, String> _readEnvFiles(List<String> paths) {
  final values = <String, String>{};
  for (final path in paths) {
    values.addAll(_readEnvFile(path));
  }
  return values;
}

class _ProxyOptions {
  final String host;
  final int port;
  final List<String> envFiles;
  final String? token;

  const _ProxyOptions({
    required this.host,
    required this.port,
    required this.envFiles,
    required this.token,
  });

  factory _ProxyOptions.parse(List<String> args) {
    String host = '0.0.0.0';
    var port = 8787;
    var envFiles = <String>['.env', '.env.flutter'];
    String? token;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      String? nextValue() => i + 1 < args.length ? args[++i] : null;
      switch (arg) {
        case '--host':
          host = nextValue() ?? host;
        case '--port':
          port = int.tryParse(nextValue() ?? '') ?? port;
        case '--env-file':
          final value = nextValue();
          if (value != null) envFiles = [value];
        case '--token':
          token = nextValue();
        case '--help':
        case '-h':
          stdout.writeln('''
Usage: dart run tool/responses_ws_proxy.dart [options]

Options:
  --host <host>       Bind host. Default: 0.0.0.0
  --port <port>       Bind port. Default: 8787
  --env-file <path>   Env file to read. Default: .env then .env.flutter
  --token <token>     Optional query token. Client URL: ws://host:8787/v1/responses?token=...

Environment:
  OPENAI_API_KEY              Required unless present in .env.flutter or .env.
  PINGPONG_WS_PROXY_TOKEN     Optional query token.
  OPENAI_RESPONSES_WS_URL     Optional upstream override.
''');
          exit(0);
      }
    }

    return _ProxyOptions(
      host: host,
      port: port,
      envFiles: envFiles,
      token: token,
    );
  }
}
