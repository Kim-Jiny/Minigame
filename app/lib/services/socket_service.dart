import 'package:socket_io_client/socket_io_client.dart' as io;
import '../config/app_config.dart';

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  io.Socket? _socket;
  bool _isConnected = false;

  // 소켓 연결 전에 등록된 리스너들을 버퍼링
  final Map<String, List<Function(dynamic)>> _pendingListeners = {};

  bool get isConnected => _isConnected;
  io.Socket? get socket => _socket;

  void connect() {
    if (_socket != null) return;

    _socket = io.io(
      AppConfig.serverUrl,
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
  }

  void emit(String event, dynamic data) {
    _socket?.emit(event, data);
  }

  void on(String event, Function(dynamic) callback) {
    print('📡 Setting up listener for: $event');

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
  }
}
