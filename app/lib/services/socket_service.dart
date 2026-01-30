import 'package:socket_io_client/socket_io_client.dart' as io;
import '../config/app_config.dart';

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  io.Socket? _socket;
  bool _isConnected = false;
  String? _currentServerUrl;

  // 소켓 연결 전에 등록된 리스너들을 버퍼링
  final Map<String, List<Function(dynamic)>> _pendingListeners = {};

  // 연결된 리스너들 저장 (재연결 시 사용)
  final Map<String, List<Function(dynamic)>> _activeListeners = {};

  bool get isConnected => _isConnected;
  io.Socket? get socket => _socket;

  void connect() {
    final serverUrl = AppConfig.serverUrl;

    // 이미 같은 URL로 연결되어 있으면 스킵
    if (_socket != null && _currentServerUrl == serverUrl) return;

    // URL이 변경되었으면 기존 연결 종료
    if (_socket != null && _currentServerUrl != serverUrl) {
      print('🔄 Server URL changed, reconnecting...');
      _reconnectWithNewUrl(serverUrl);
      return;
    }

    _currentServerUrl = serverUrl;
    _socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .enableAutoConnect()
          .enableReconnection()
          .build(),
    );

    // 대기 중이던 리스너들 등록
    _registerPendingListeners();

    _socket!.onConnect((_) {
      _isConnected = true;
      print('Connected to server');
    });

    _socket!.onDisconnect((_) {
      _isConnected = false;
      print('Disconnected from server');
    });

    _socket!.onConnectError((error) {
      print('Connection error: $error');
    });
  }

  void _registerPendingListeners() {
    if (_socket == null) return;

    for (final entry in _pendingListeners.entries) {
      final event = entry.key;
      for (final callback in entry.value) {
        print('📡 Registering pending listener for: $event');
        _socket!.on(event, (data) {
          print('📡 Received event: $event');
          callback(data);
        });
      }
    }
    _pendingListeners.clear();
  }

  void disconnect() {
    _socket?.disconnect();
    _socket = null;
    _isConnected = false;
    _currentServerUrl = null;
  }

  /// URL이 변경되었을 때 재연결
  void _reconnectWithNewUrl(String newUrl) {
    // 기존 소켓 연결 종료
    _socket?.disconnect();
    _socket = null;
    _isConnected = false;

    // 새 URL로 연결
    _currentServerUrl = newUrl;
    _socket = io.io(
      newUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .enableAutoConnect()
          .enableReconnection()
          .build(),
    );

    // 기존 리스너들 다시 등록
    _reregisterActiveListeners();

    _socket!.onConnect((_) {
      _isConnected = true;
      print('Connected to new server: $newUrl');
    });

    _socket!.onDisconnect((_) {
      _isConnected = false;
      print('Disconnected from server');
    });

    _socket!.onConnectError((error) {
      print('Connection error: $error');
    });
  }

  /// 저장된 활성 리스너들 다시 등록
  void _reregisterActiveListeners() {
    if (_socket == null) return;

    for (final entry in _activeListeners.entries) {
      final event = entry.key;
      for (final callback in entry.value) {
        _socket!.on(event, (data) {
          print('📡 Received event: $event');
          callback(data);
        });
      }
    }
  }

  /// 서버 URL 변경 감지하여 필요시 재연결
  void checkAndReconnect() {
    final newUrl = AppConfig.serverUrl;
    if (_currentServerUrl != null && _currentServerUrl != newUrl) {
      print('🔄 Detected server URL change: $_currentServerUrl -> $newUrl');
      _reconnectWithNewUrl(newUrl);
    }
  }

  void emit(String event, dynamic data) {
    _socket?.emit(event, data);
  }

  void on(String event, Function(dynamic) callback) {
    print('📡 Setting up listener for: $event');

    // 활성 리스너 목록에 저장 (재연결 시 사용)
    _activeListeners.putIfAbsent(event, () => []);
    _activeListeners[event]!.add(callback);

    if (_socket != null) {
      // 소켓이 있으면 바로 등록
      _socket!.on(event, (data) {
        print('📡 Received event: $event');
        callback(data);
      });
    } else {
      // 소켓이 없으면 버퍼링
      print('📡 Buffering listener for: $event (socket not ready)');
      _pendingListeners.putIfAbsent(event, () => []);
      _pendingListeners[event]!.add(callback);
    }
  }

  void off(String event) {
    _socket?.off(event);
    _pendingListeners.remove(event);
    _activeListeners.remove(event);
  }
}
