import 'package:web_socket_channel/html.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectRealtimeWebSocketImpl({
  required Uri uri,
  required String apiKey,
}) {
  return HtmlWebSocketChannel.connect(
    uri,
    protocols: ['realtime', 'openai-insecure-api-key.$apiKey'],
  );
}
