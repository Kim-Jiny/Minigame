import 'socket_service.dart';

class SocketListenerRegistry {
  final SocketService _socketService;
  final Map<String, Function(dynamic)> _handlers = {};

  SocketListenerRegistry(this._socketService);

  void on(String event, Function(dynamic) handler) {
    if (_handlers.containsKey(event)) return;
    _handlers[event] = handler;
    _socketService.on(event, handler);
  }

  void offAll() {
    for (final entry in _handlers.entries) {
      _socketService.offCallback(entry.key, entry.value);
    }
    _handlers.clear();
  }
}
