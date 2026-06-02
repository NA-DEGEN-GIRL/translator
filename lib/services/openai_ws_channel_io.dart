import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectOpenAIWebSocketImpl({
  required Uri uri,
  String? apiKey,
}) {
  return IOWebSocketChannel.connect(
    uri,
    headers: apiKey == null || apiKey.isEmpty
        ? null
        : {'Authorization': 'Bearer $apiKey'},
    connectTimeout: const Duration(seconds: 10),
    pingInterval: const Duration(seconds: 20),
  );
}
