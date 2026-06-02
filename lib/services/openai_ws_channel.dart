import 'package:web_socket_channel/web_socket_channel.dart';

import 'openai_ws_channel_stub.dart'
    if (dart.library.io) 'openai_ws_channel_io.dart'
    if (dart.library.js_interop) 'openai_ws_channel_web.dart';

WebSocketChannel connectOpenAIWebSocket({required Uri uri, String? apiKey}) {
  return connectOpenAIWebSocketImpl(uri: uri, apiKey: apiKey);
}
