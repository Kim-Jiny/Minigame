import 'package:flutter/foundation.dart';
import '../../services/socket_listener_registry.dart';

class GameEventHelper {
  const GameEventHelper._();

  static void registerRematchHandlers({
    required SocketListenerRegistry registry,
    required void Function(bool waiting) onRematchWaiting,
    required void Function(bool wantsRematch) onOpponentRematchChanged,
  }) {
    registry.on('rematch_waiting', (data) {
      onRematchWaiting(data['waiting'] ?? false);
    });

    registry.on('rematch_requested', (_) {
      onOpponentRematchChanged(true);
    });

    registry.on('rematch_cancelled', (_) {
      onOpponentRematchChanged(false);
    });
  }

  static void registerInvalidRoomHandler({
    required SocketListenerRegistry registry,
    required VoidCallback onInvalidRoom,
  }) {
    registry.on('error', (data) {
      final message = data['message'] ?? '';
      if (_isInvalidRoomMessage(message.toString())) {
        onInvalidRoom();
      }
    });
  }

  static bool _isInvalidRoomMessage(String message) {
    return message.contains('Invalid room') ||
        message.contains('not in progress');
  }
}
