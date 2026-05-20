import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectRealtimeWebSocketImpl({
  required Uri uri,
  required String apiKey,
}) {
  return IOWebSocketChannel.connect(
    uri,
    headers: {'Authorization': 'Bearer $apiKey'},
    connectTimeout: const Duration(seconds: 10),
    pingInterval: const Duration(seconds: 20),
  );
}
