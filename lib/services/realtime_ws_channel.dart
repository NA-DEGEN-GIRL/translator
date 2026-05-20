import 'package:web_socket_channel/web_socket_channel.dart';

import 'realtime_ws_channel_stub.dart'
    if (dart.library.io) 'realtime_ws_channel_io.dart'
    if (dart.library.js_interop) 'realtime_ws_channel_web.dart';

WebSocketChannel connectRealtimeWebSocket({
  required Uri uri,
  required String apiKey,
}) {
  return connectRealtimeWebSocketImpl(uri: uri, apiKey: apiKey);
}
