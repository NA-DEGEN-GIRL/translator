import 'package:web_socket_channel/html.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectOpenAIWebSocketImpl({
  required Uri uri,
  String? apiKey,
}) {
  if (apiKey == null || apiKey.isEmpty) {
    return HtmlWebSocketChannel.connect(uri);
  }
  return HtmlWebSocketChannel.connect(
    uri,
    protocols: ['openai-insecure-api-key.$apiKey'],
  );
}
