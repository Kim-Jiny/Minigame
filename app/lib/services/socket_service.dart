import 'package:socket_io_client/socket_io_client.dart' as io;
import '../config/app_config.dart';
import 'remote_config_service.dart';
import '../utils/app_logger.dart';

class _QueuedEmit {
  final String event;
  final dynamic data;
  final bool requireLobbyJoined;

  const _QueuedEmit({
    required this.event,
    required this.data,
    required this.requireLobbyJoined,
  });
}

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  io.Socket? _socket;
  String? _currentServerUrl;
  int _connectionErrorCount = 0;
  bool _isLobbyJoined = false;

  // 소켓 연결 전에 등록된 리스너들을 버퍼링
  final Map<String, List<Function(dynamic)>> _pendingListeners = {};

  // 연결된 리스너들 저장 (재연결 시 사용)
  final Map<String, List<Function(dynamic)>> _activeListeners = {};

  final List<_QueuedEmit> _pendingEmits = [];

  bool get isConnected => _socket?.connected ?? false;
  bool get isLobbyJoined => _isLobbyJoined;
  bool get isReady => isConnected && _isLobbyJoined;
  io.Socket? get socket => _socket;

  void connect() {
    final serverUrl = AppConfig.serverUrl;
    AppLogger.debug('🔌 SocketService.connect() called, serverUrl=$serverUrl');

    // 이미 같은 URL로 연결되어 있고 실제로 연결된 상태면 스킵
    if (_socket != null && _currentServerUrl == serverUrl && (_socket!.connected)) {
      AppLogger.debug('🔌 Already connected to $serverUrl, skipping');
      return;
    }

    // 소켓은 있지만 연결이 끊어진 경우 재연결 시도
    if (_socket != null && _currentServerUrl == serverUrl && !(_socket!.connected)) {
      AppLogger.debug('🔌 Socket exists but disconnected, reconnecting...');
      _isLobbyJoined = false;
      _socket!.connect();
      return;
    }

    // URL이 변경되었으면 기존 연결 종료
    if (_socket != null && _currentServerUrl != serverUrl) {
      AppLogger.debug('🔄 Server URL changed, reconnecting...');
      _reconnectWithNewUrl(serverUrl);
      return;
    }

    _isLobbyJoined = false;
    _currentServerUrl = serverUrl;
    // HTTPS URL에 포트가 없으면 :443 명시 (socket_io_client 포트 파싱 버그 방지)
    var socketUrl = serverUrl;
    if (socketUrl.startsWith('https://') && !RegExp(r':\d+').hasMatch(socketUrl.replaceFirst('https://', ''))) {
      socketUrl = socketUrl.replaceFirst('https://', 'https://').replaceFirst(RegExp(r'/?$'), ':443');
    }

    _socket = io.io(
      socketUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .enableAutoConnect()
          .enableReconnection()
          .build(),
    );

    // 대기 중이던 리스너들 등록
    _registerPendingListeners();

    _registerConnectionHandlers(_socket!);
  }

  /// 연결 오류 발생 시 처리
  void _handleConnectionError() {
    _connectionErrorCount++;
    // 연결 오류가 발생하면 원격 설정 다시 확인 (점검 모드인지)
    if (_connectionErrorCount >= 2) {
      AppLogger.debug('🔄 Multiple connection errors, refreshing remote config...');
      RemoteConfigService().refresh();
      _connectionErrorCount = 0;
    }
  }

  void _registerPendingListeners() {
    if (_socket == null) return;

    for (final entry in _pendingListeners.entries) {
      final event = entry.key;
      final pendingCallbacks = entry.value;
      if (pendingCallbacks.isEmpty) continue;

      AppLogger.debug(
        '📡 Registering ${pendingCallbacks.length} pending listener(s) for: $event',
      );

      // pending 리스너들을 active로 이동
      _activeListeners[event] ??= [];
      for (final cb in pendingCallbacks) {
        if (!_activeListeners[event]!.contains(cb)) {
          _activeListeners[event]!.add(cb);
        }
      }

      _bindSocketEvent(event);
    }
    _pendingListeners.clear();
  }

  void disconnect() {
    _socket?.disconnect();
    _socket = null;
    _currentServerUrl = null;
    _isLobbyJoined = false;
    _pendingEmits.clear();
  }

  /// URL이 변경되었을 때 재연결
  void _reconnectWithNewUrl(String newUrl) {
    // 기존 소켓 연결 종료
    _socket?.disconnect();
    _socket = null;
    _isLobbyJoined = false;

    // 새 URL로 연결
    _currentServerUrl = newUrl;

    // HTTPS URL에 포트가 없으면 :443 명시 (socket_io_client 포트 파싱 버그 방지)
    var socketUrl = newUrl;
    if (socketUrl.startsWith('https://') && !RegExp(r':\d+').hasMatch(socketUrl.replaceFirst('https://', ''))) {
      socketUrl = socketUrl.replaceFirst(RegExp(r'/?$'), ':443');
    }

    _socket = io.io(
      socketUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .enableAutoConnect()
          .enableReconnection()
          .build(),
    );

    // 기존 리스너들 다시 등록
    _reregisterActiveListeners();

    _registerConnectionHandlers(_socket!);
  }

  void _registerConnectionHandlers(io.Socket socket) {
    socket.onConnect((_) {
      _isLobbyJoined = false;
      AppLogger.debug('🔌 Connected to server! isConnected=${socket.connected}');
      _dispatchEvent('connect', null);
    });

    socket.onDisconnect((reason) {
      _isLobbyJoined = false;
      AppLogger.debug('Disconnected from server');
      _dispatchEvent('disconnect', reason);
    });

    socket.onConnectError((error) {
      AppLogger.debug('🔌 Connection error: $error');
      _handleConnectionError();
      _dispatchEvent('connect_error', error);
    });

    socket.on('reconnect_attempt', (attempt) {
      AppLogger.debug('🔁 Reconnect attempt: $attempt');
      _dispatchEvent('reconnect_attempt', attempt);
    });

    socket.on('reconnect', (attempt) {
      AppLogger.debug('🔁 Reconnected after $attempt attempt(s)');
      _dispatchEvent('reconnect', attempt);
    });

    socket.on('reconnect_error', (error) {
      AppLogger.debug('🔁 Reconnect error: $error');
      _dispatchEvent('reconnect_error', error);
    });

    socket.on('reconnect_failed', (data) {
      AppLogger.debug('🔁 Reconnect failed');
      _dispatchEvent('reconnect_failed', data);
    });
  }

  /// 저장된 활성 리스너들 다시 등록
  void _reregisterActiveListeners() {
    if (_socket == null) return;

    for (final entry in _activeListeners.entries) {
      final event = entry.key;
      final callbacks = entry.value;
      if (callbacks.isEmpty) continue;

      _bindSocketEvent(event);
    }
  }

  /// 서버 URL 변경 감지하여 필요시 재연결
  void checkAndReconnect() {
    final newUrl = AppConfig.serverUrl;
    if (_currentServerUrl != null && _currentServerUrl != newUrl) {
      AppLogger.debug('🔄 Detected server URL change: $_currentServerUrl -> $newUrl');
      _reconnectWithNewUrl(newUrl);
    }
  }

  void emit(String event, dynamic data, {bool requireLobbyJoined = true}) {
    final shouldRequireLobbyJoined = requireLobbyJoined && event != 'join_lobby';

    if (_socket == null || !_socket!.connected || (shouldRequireLobbyJoined && !_isLobbyJoined)) {
      AppLogger.debug(
        '📤 Queueing emit: $event (connected=${_socket?.connected ?? false}, lobbyJoined=$_isLobbyJoined)',
      );
      _pendingEmits.add(
        _QueuedEmit(
          event: event,
          data: data,
          requireLobbyJoined: shouldRequireLobbyJoined,
        ),
      );
      if (_socket == null || !_socket!.connected) {
        connect();
      }
      return;
    }

    AppLogger.debug('📤 Emitting: $event');
    _socket?.emit(event, data);
  }

  void on(String event, Function(dynamic) callback) {
    AppLogger.debug('📡 Setting up listener for: $event');

    // 기존 리스너 목록에 추가 (여러 컴포넌트가 동시에 리스닝 가능)
    _activeListeners[event] ??= [];

    // 이미 같은 콜백이 있으면 중복 추가 방지
    if (!_activeListeners[event]!.contains(callback)) {
      _activeListeners[event]!.add(callback);
    }

    if (_socket != null) {
      _bindSocketEvent(event);
    } else {
      // 소켓이 없으면 버퍼링
      AppLogger.debug('📡 Buffering listener for: $event (socket not ready)');
      _pendingListeners[event] ??= [];
      if (!_pendingListeners[event]!.contains(callback)) {
        _pendingListeners[event]!.add(callback);
      }
    }
  }

  /// 특정 이벤트의 특정 콜백만 제거
  void offCallback(String event, Function(dynamic) callback) {
    _activeListeners[event]?.remove(callback);
    _pendingListeners[event]?.remove(callback);

    // 소켓 리스너 재등록 (남은 콜백들을 위해)
    if (_socket != null && (_activeListeners[event]?.isNotEmpty ?? false)) {
      _bindSocketEvent(event);
    } else if (_socket != null) {
      // 남은 콜백이 없으면 리스너 제거
      _socket!.off(event);
    }
  }

  /// 특정 이벤트의 모든 리스너 제거 (주의: 다른 컴포넌트의 리스너도 제거됨)
  void off(String event) {
    _socket?.off(event);
    _pendingListeners.remove(event);
    _activeListeners.remove(event);
  }

  void _bindSocketEvent(String event) {
    if (_socket == null) return;

    _socket!.off(event);
    _socket!.on(event, (data) {
      AppLogger.debug('📡 Received event: $event');
      _dispatchEvent(event, data);
    });
  }

  void _dispatchEvent(String event, dynamic data) {
    if (event == 'lobby_joined') {
      _isLobbyJoined = true;
      _flushPendingEmits();
    }

    final callbacks = List<Function(dynamic)>.from(_activeListeners[event] ?? []);
    for (final cb in callbacks) {
      try {
        cb(data);
      } catch (e) {
        AppLogger.debug('📡 Error in listener for $event: $e');
      }
    }
  }

  void _flushPendingEmits() {
    if (_socket == null || !_socket!.connected) return;
    if (_pendingEmits.isEmpty) return;

    final queuedEmits = List<_QueuedEmit>.from(_pendingEmits);
    _pendingEmits.clear();

    for (final pendingEmit in queuedEmits) {
      if (pendingEmit.requireLobbyJoined && !_isLobbyJoined) {
        _pendingEmits.add(pendingEmit);
        continue;
      }

      AppLogger.debug('📤 Flushing queued emit: ${pendingEmit.event}');
      _socket!.emit(pendingEmit.event, pendingEmit.data);
    }
  }
}
