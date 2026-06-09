import 'package:socket_io_client/socket_io_client.dart' as io;
import '../config/app_config.dart';
import 'remote_config_service.dart';
import '../utils/app_logger.dart';

/// ready(=서버 인증 완료) 이전에 emit 된 이벤트를 보관했다가 ready 시점에 flush.
class _QueuedEmit {
  final String event;
  final dynamic data;
  const _QueuedEmit(this.event, this.data);
}

/// Socket.IO 연결을 감싸는 싱글톤.
///
/// - 인증은 핸드셰이크(`auth`)로 처리한다. 토큰/닉네임 등을 [setAuth] 로 넘기면
///   연결/재연결 시 서버 connection 시점에 전달되고, 서버는 인증이 끝나면
///   `lobby_joined`(성공) 또는 `auth_error`(실패) 를 보낸다.
/// - `lobby_joined` 를 받은 시점부터 [isReady] 가 true 가 되며, 그 전에 호출된
///   [emit] 은 큐에 쌓였다가 ready 가 되면 한 번에 전송된다.
class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  /// 항상 소켓에 바인딩해 두는 시스템 이벤트. 사용자 리스너 등록 여부와 무관하게
  /// ready 상태를 추적하려면 dispatch 경로를 거쳐야 한다.
  static const Set<String> _systemEvents = {
    'connect',
    'disconnect',
    'connect_error',
    'error',
    'reconnect',
    'reconnect_attempt',
    'reconnect_error',
    'reconnect_failed',
    'lobby_joined',
    'auth_error',
  };

  io.Socket? _socket;
  String? _currentUrl;
  Map<String, dynamic> _auth = const {};
  bool _isReady = false;
  int _connectionErrorCount = 0;

  /// event → 콜백 목록. 소켓이 재생성돼도(URL 변경) 이 맵을 기준으로 재바인딩한다.
  final Map<String, List<Function(dynamic)>> _listeners = {};

  /// ready 이전에 쌓인 emit. `lobby_joined` 수신 시 flush.
  final List<_QueuedEmit> _pendingEmits = [];

  bool get isConnected => _socket?.connected ?? false;
  bool get isReady => _isReady;
  io.Socket? get socket => _socket;

  /// 핸드셰이크 인증 정보 설정. 이미 다른 auth 로 연결돼 있으면 새 auth 로 재연결한다.
  void setAuth(Map<String, dynamic> auth) {
    _auth = Map<String, dynamic>.from(auth);
    final socket = _socket;
    if (socket != null) {
      socket.auth = _auth;
      _isReady = false;
      socket
        ..disconnect()
        ..connect();
    }
  }

  void connect() {
    final url = AppConfig.serverUrl;

    // 같은 URL 의 소켓이 이미 있으면 재사용. 끊겨 있으면 재연결만.
    if (_socket != null && _currentUrl == url) {
      if (!_socket!.connected) {
        _isReady = false;
        _socket!.connect();
      }
      return;
    }

    AppLogger.debug('🔌 SocketService.connect() → $url');
    _teardownSocket();
    _currentUrl = url;

    _socket = io.io(
      _normalizeUrl(url),
      io.OptionBuilder()
          .setTransports(['websocket'])
          .enableReconnection()
          .setAuth(_auth)
          .build(),
    );

    // 시스템 이벤트 + 등록돼 있던 사용자 리스너를 모두 바인딩.
    for (final event in {..._systemEvents, ..._listeners.keys}) {
      _bindEvent(event);
    }
    _socket!.connect();
  }

  /// 서버 URL 변경 감지 후 필요 시 재연결. (connect 가 URL 변경을 직접 처리한다.)
  void checkAndReconnect() => connect();

  void disconnect() {
    _teardownSocket();
    _currentUrl = null;
    _pendingEmits.clear();
  }

  void _teardownSocket() {
    final socket = _socket;
    _socket = null;
    _isReady = false;
    // dispose() 가 disconnect + 모든 리스너 제거를 함께 처리한다.
    socket?.dispose();
  }

  void emit(String event, [dynamic data]) {
    if (_socket != null && _isReady) {
      AppLogger.debug('📤 emit: $event');
      _socket!.emit(event, data);
      return;
    }

    AppLogger.debug('📤 queue emit: $event (ready=$_isReady)');
    _pendingEmits.add(_QueuedEmit(event, data));
    // 소켓이 없거나 끊겨 있으면 연결을 보장한다.
    connect();
  }

  void on(String event, Function(dynamic) callback) {
    final callbacks = _listeners[event] ??= [];
    if (callbacks.contains(callback)) return;
    callbacks.add(callback);

    // 첫 콜백이면 dispatcher 를 바인딩 (시스템 이벤트는 이미 바인딩돼 있음).
    if (_socket != null && callbacks.length == 1) {
      _bindEvent(event);
    }
  }

  /// 특정 이벤트의 특정 콜백만 제거.
  void offCallback(String event, Function(dynamic) callback) {
    final callbacks = _listeners[event];
    if (callbacks == null) return;
    callbacks.remove(callback);
    if (callbacks.isEmpty && !_systemEvents.contains(event)) {
      _listeners.remove(event);
      _socket?.off(event);
    }
  }

  /// 특정 이벤트의 모든 리스너 제거. (시스템 이벤트는 dispatcher 를 유지한다.)
  void off(String event) {
    _listeners.remove(event);
    if (!_systemEvents.contains(event)) {
      _socket?.off(event);
    }
  }

  void _bindEvent(String event) {
    final socket = _socket;
    if (socket == null) return;
    socket.off(event);
    socket.on(event, (data) => _dispatch(event, data));
  }

  void _dispatch(String event, dynamic data) {
    switch (event) {
      case 'lobby_joined':
        _isReady = true;
        _connectionErrorCount = 0;
        _flushPendingEmits();
        break;
      case 'disconnect':
      case 'auth_error':
        _isReady = false;
        break;
      case 'connect_error':
      case 'reconnect_error':
        _isReady = false;
        _handleConnectionError();
        break;
    }

    final callbacks = _listeners[event];
    if (callbacks == null || callbacks.isEmpty) return;
    for (final cb in List<Function(dynamic)>.from(callbacks)) {
      try {
        cb(data);
      } catch (e) {
        AppLogger.debug('📡 listener error for $event: $e');
      }
    }
  }

  void _flushPendingEmits() {
    if (_socket == null || !_isReady || _pendingEmits.isEmpty) return;
    final queued = List<_QueuedEmit>.from(_pendingEmits);
    _pendingEmits.clear();
    for (final e in queued) {
      AppLogger.debug('📤 flush queued emit: ${e.event}');
      _socket!.emit(e.event, e.data);
    }
  }

  /// 연결 오류가 반복되면 원격 설정을 갱신해 점검 모드인지 확인한다.
  void _handleConnectionError() {
    _connectionErrorCount++;
    if (_connectionErrorCount >= 2) {
      AppLogger.debug('🔄 Multiple connection errors, refreshing remote config...');
      RemoteConfigService().refresh();
      _connectionErrorCount = 0;
    }
  }

  /// HTTPS URL 에 포트가 없으면 `:443` 을 명시한다.
  /// (socket_io_client 의 포트 파싱 버그 회피)
  String _normalizeUrl(String url) {
    if (url.startsWith('https://') &&
        !RegExp(r':\d+').hasMatch(url.replaceFirst('https://', ''))) {
      return url.replaceFirst(RegExp(r'/?$'), ':443');
    }
    return url;
  }
}
