import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/ranked_provider.dart';
import '../../services/socket_service.dart';

class GameSessionHelper {
  const GameSessionHelper._();

  static void returnToLobby({
    required BuildContext context,
    required bool mounted,
    required bool hasScheduledPop,
    required VoidCallback markScheduledPop,
    required String message,
    String title = '게임 종료',
    VoidCallback? beforeNavigate,
  }) {
    if (!mounted || hasScheduledPop) {
      return;
    }

    markScheduledPop();
    beforeNavigate?.call();

    ScaffoldMessenger.of(context).clearSnackBars();
    try {
      context.read<GameProvider>().setLobbyNotice(
        title: title,
        message: message,
        tone: LobbyNoticeTone.warning,
      );
    } catch (_) {}
    try {
      context.read<GameProvider>().reset();
    } catch (_) {}

    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  static void handleInvalidRoom({
    required BuildContext context,
    required bool mounted,
    required bool hasScheduledPop,
    required VoidCallback markScheduledPop,
    VoidCallback? beforeNavigate,
  }) {
    returnToLobby(
      context: context,
      mounted: mounted,
      hasScheduledPop: hasScheduledPop,
      markScheduledPop: markScheduledPop,
      title: '연결 종료',
      message: '연결이 끊어져 게임이 종료되었습니다.',
      beforeNavigate: beforeNavigate,
    );
  }

  static void handleReconnectTimeout({
    required BuildContext context,
    required bool mounted,
    required bool hasScheduledPop,
    required VoidCallback markScheduledPop,
    VoidCallback? beforeNavigate,
    String message = '20초 안에 연결을 복구하지 못해 패배 처리되었습니다.',
  }) {
    returnToLobby(
      context: context,
      mounted: mounted,
      hasScheduledPop: hasScheduledPop,
      markScheduledPop: markScheduledPop,
      title: '재연결 실패',
      message: message,
      beforeNavigate: beforeNavigate,
    );
  }

  static void leaveGame({
    required BuildContext context,
    required SocketService socketService,
    required String? roomId,
    required bool isRanked,
    required VoidCallback resetState,
  }) {
    final resolvedRoomId = resolveRoomId(
      context: context,
      roomId: roomId,
      isRanked: isRanked,
    );

    if (resolvedRoomId != null) {
      socketService.emit('leave_room', {'roomId': resolvedRoomId});
    }

    try {
      context.read<GameProvider>().reset();
    } catch (_) {}

    resetState();
  }

  static String? resolveRoomId({
    required BuildContext context,
    required String? roomId,
    required bool isRanked,
  }) {
    if (roomId != null || !isRanked) {
      return roomId;
    }

    try {
      return context.read<RankedProvider>().roomId;
    } catch (_) {
      return null;
    }
  }
}
