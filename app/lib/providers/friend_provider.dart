import 'package:flutter/foundation.dart';
import '../services/socket_service.dart';

class Friend {
  final int id;
  final String nickname;
  final String? email;
  final String? avatarUrl;
  final String? friendCode;
  final String? memo;
  final bool isOnline;

  Friend({
    required this.id,
    required this.nickname,
    this.email,
    this.avatarUrl,
    this.friendCode,
    this.memo,
    this.isOnline = false,
  });

  Friend copyWith({String? memo}) {
    return Friend(
      id: id,
      nickname: nickname,
      email: email,
      avatarUrl: avatarUrl,
      friendCode: friendCode,
      memo: memo ?? this.memo,
      isOnline: isOnline,
    );
  }

  factory Friend.fromJson(Map<String, dynamic> json) {
    return Friend(
      id: json['id'],
      nickname: json['nickname'],
      email: json['email'],
      avatarUrl: json['avatarUrl'],
      friendCode: json['friendCode'],
      memo: json['memo'],
      isOnline: json['isOnline'] ?? false,
    );
  }
}

class FriendRequest {
  final int id;
  final int fromUserId;
  final String fromNickname;
  final int toUserId;
  final String toNickname;
  final DateTime createdAt;

  FriendRequest({
    required this.id,
    required this.fromUserId,
    required this.fromNickname,
    required this.toUserId,
    required this.toNickname,
    required this.createdAt,
  });

  factory FriendRequest.fromJson(Map<String, dynamic> json) {
    return FriendRequest(
      id: json['id'],
      fromUserId: json['fromUserId'],
      fromNickname: json['fromNickname'],
      toUserId: json['toUserId'],
      toNickname: json['toNickname'],
      createdAt: DateTime.parse(json['createdAt']),
    );
  }
}

class Invitation {
  final int id;
  final int inviterId;
  final String inviterNickname;
  final int inviteeId;
  final String inviteeNickname;
  final String gameType;
  final bool isHardcore;
  final String status;
  final String? roomId;
  final DateTime createdAt;

  Invitation({
    required this.id,
    required this.inviterId,
    required this.inviterNickname,
    required this.inviteeId,
    required this.inviteeNickname,
    required this.gameType,
    required this.isHardcore,
    required this.status,
    this.roomId,
    required this.createdAt,
  });

  factory Invitation.fromJson(Map<String, dynamic> json) {
    return Invitation(
      id: json['id'],
      inviterId: json['inviterId'],
      inviterNickname: json['inviterNickname'],
      inviteeId: json['inviteeId'],
      inviteeNickname: json['inviteeNickname'],
      gameType: json['gameType'],
      isHardcore: json['isHardcore'] ?? false,
      status: json['status'],
      roomId: json['roomId'],
      createdAt: DateTime.parse(json['createdAt']),
    );
  }

  String get gameTypeName {
    final name = switch (gameType) {
      'tictactoe' => '틱택토',
      'infinite_tictactoe' => '무한 틱택토',
      _ => gameType,
    };
    return isHardcore ? '$name (하드코어)' : name;
  }
}

class FriendProvider extends ChangeNotifier {
  final SocketService _socketService = SocketService();

  String? _myFriendCode;
  List<Friend> _friends = [];
  List<FriendRequest> _receivedRequests = [];
  List<FriendRequest> _sentRequests = [];
  List<Invitation> _invitations = [];
  bool _isLoading = false;
  String? _error;
  String? _successMessage;
  bool _listenersInitialized = false;
  Map<int, int> _unreadCounts = {}; // friendId -> unread count

  // 초대 받았을 때 콜백
  Function(Invitation)? onInvitationReceived;
  // 게임 시작 콜백 (초대 수락 후) - gameState 포함
  Function(String gameType, String roomId, Map<String, dynamic>? gameState)? onGameStart;
  // 친구 요청 받았을 때 콜백
  Function(String fromNickname)? onFriendRequestReceived;

  String? get myFriendCode => _myFriendCode;
  List<Friend> get friends => _friends;
  List<FriendRequest> get receivedRequests => _receivedRequests;
  List<FriendRequest> get sentRequests => _sentRequests;
  List<Invitation> get invitations => _invitations;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get successMessage => _successMessage;
  Map<int, int> get unreadCounts => _unreadCounts;
  int get totalUnreadCount => _unreadCounts.values.fold(0, (sum, count) => sum + count);
  int get pendingRequestCount => _receivedRequests.length;

  void initialize() {
    debugPrint('🔧 FriendProvider.initialize() called, _listenersInitialized=$_listenersInitialized, isConnected=${_socketService.isConnected}');
    if (!_listenersInitialized) {
      _setupSocketListeners();
      _listenersInitialized = true;
    }
    // 이미 소켓이 연결되어 있으면 바로 데이터 가져오기
    if (_socketService.isConnected) {
      debugPrint('🔧 Socket connected, fetching initial data');
      _fetchInitialData();
    }
  }

  void _fetchInitialData() {
    getMyFriendCode();
    getFriends();
    getFriendRequests();
    getInvitations();
    getUnreadCounts();
  }

  void _setupSocketListeners() {
    // 로비 입장 후 데이터 가져오기
    _socketService.on('lobby_joined', (_) {
      _fetchInitialData();
    });

    // 친구 코드 응답
    _socketService.on('friend_code', (data) {
      _myFriendCode = data['code'];
      notifyListeners();
    });

    // 친구 요청 결과
    _socketService.on('friend_request_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        _successMessage = data['message'];
        _error = null;
        // 친구 요청 목록 새로고침
        getFriendRequests();
        // 바로 친구가 된 경우 친구 목록도 새로고침
        if (data['message']?.contains('친구가 되었습니다') == true) {
          getFriends();
        }
      } else {
        _error = data['message'];
        _successMessage = null;
      }
      notifyListeners();
    });

    // 친구 요청 받음 (실시간)
    _socketService.on('friend_request_received', (data) {
      final fromNickname = data['fromNickname'] as String;
      onFriendRequestReceived?.call(fromNickname);
      // 친구 요청 목록 새로고침
      getFriendRequests();
    });

    // 친구 요청 목록 응답
    _socketService.on('friend_requests_list', (data) {
      _receivedRequests = (data['received'] as List)
          .map((r) => FriendRequest.fromJson(r))
          .toList();
      _sentRequests = (data['sent'] as List)
          .map((r) => FriendRequest.fromJson(r))
          .toList();
      notifyListeners();
    });

    // 친구 요청 수락/거절/취소 결과
    _socketService.on('friend_request_action_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        _successMessage = data['message'];
        _error = null;
        // 친구 요청 목록 새로고침
        getFriendRequests();
        // 수락인 경우 친구 목록도 새로고침
        if (data['action'] == 'accept') {
          getFriends();
        }
      } else {
        _error = data['message'];
        _successMessage = null;
      }
      notifyListeners();
    });

    // 내가 보낸 친구 요청이 수락됨
    _socketService.on('friend_request_accepted', (data) {
      final newFriend = Friend(
        id: data['id'],
        nickname: data['nickname'],
        friendCode: data['friendCode'],
        isOnline: true,
      );
      if (!_friends.any((f) => f.id == newFriend.id)) {
        _friends.add(newFriend);
      }
      // 보낸 요청 목록에서 제거
      getFriendRequests();
      notifyListeners();
    });

    // 친구 목록 응답
    _socketService.on('friends_list', (data) {
      _friends = (data['friends'] as List)
          .map((f) => Friend.fromJson(f))
          .toList();
      _isLoading = false;
      notifyListeners();
    });

    // 친구 삭제 결과
    _socketService.on('remove_friend_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        _successMessage = data['message'];
        _error = null;
      } else {
        _error = data['message'];
        _successMessage = null;
      }
      notifyListeners();
    });

    // 친구 메모 수정 결과
    _socketService.on('update_friend_memo_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        final friendId = data['friendId'] as int;
        final memo = data['memo'] as String?;
        final index = _friends.indexWhere((f) => f.id == friendId);
        if (index != -1) {
          _friends[index] = _friends[index].copyWith(memo: memo);
        }
        _successMessage = data['message'];
        _error = null;
      } else {
        _error = data['message'];
        _successMessage = null;
      }
      notifyListeners();
    });

    // 초대 결과
    _socketService.on('invite_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        _successMessage = '초대를 보냈습니다.';
        _error = null;
      } else {
        _error = data['message'];
        _successMessage = null;
      }
      notifyListeners();
    });

    // 초대 목록 응답
    _socketService.on('invitations_list', (data) {
      _invitations = (data['invitations'] as List)
          .map((i) => Invitation.fromJson(i))
          .toList();
      notifyListeners();
    });

    // 실시간 초대 받음
    _socketService.on('game_invitation', (data) {
      final invitation = Invitation.fromJson(data['invitation']);
      _invitations.insert(0, invitation);
      notifyListeners();

      // 콜백 호출 (다이얼로그 표시용)
      onInvitationReceived?.call(invitation);
    });

    // 초대 수락 결과
    _socketService.on('accept_invitation_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        // 게임 시작 콜백 호출 (게임 상태 포함)
        final roomId = data['roomId'] as String?;
        final gameType = data['gameType'] as String?;
        final gameState = data['gameState'] as Map<String, dynamic>?;
        if (roomId != null && gameType != null) {
          onGameStart?.call(gameType, roomId, gameState);
        }
      } else {
        _error = data['message'];
      }
      notifyListeners();
    });

    // 초대 거절 결과
    _socketService.on('decline_invitation_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        _successMessage = '초대를 거절했습니다.';
      } else {
        _error = data['message'];
      }
      notifyListeners();
    });

    // 초대가 거절됨
    _socketService.on('invitation_declined', (data) {
      _error = '${data['declinedBy']}님이 초대를 거절했습니다.';
      notifyListeners();
    });

    // 초대가 수락됨 (초대자에게)
    _socketService.on('invitation_accepted', (data) {
      final roomId = data['roomId'] as String?;
      final gameType = data['gameType'] as String?;
      final gameState = data['gameState'] as Map<String, dynamic>?;
      if (roomId != null && gameType != null) {
        onGameStart?.call(gameType, roomId, gameState);
      }
    });

    // 안 읽은 메시지 수
    _socketService.on('unread_counts', (data) {
      debugPrint('📩 unread_counts received: $data');
      if (data['counts'] != null) {
        _unreadCounts = Map<int, int>.from(
          (data['counts'] as Map).map((k, v) => MapEntry(int.parse(k.toString()), v as int)),
        );
        debugPrint('📩 _unreadCounts updated: $_unreadCounts, total: $totalUnreadCount');
        notifyListeners();
      }
    });

    // 새 메시지 알림 (친구 탭 뱃지 업데이트용)
    _socketService.on('new_message', (data) {
      if (data['message'] != null) {
        final senderId = data['message']['senderId'] as int;
        _unreadCounts[senderId] = (_unreadCounts[senderId] ?? 0) + 1;
        notifyListeners();
      }
    });
  }

  void getMyFriendCode() {
    _socketService.emit('get_friend_code', {});
  }

  // 친구 요청 보내기 (친구 코드로)
  void sendFriendRequest(String code) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('send_friend_request', {'friendCode': code.toUpperCase()});
  }

  // 친구 요청 보내기 (유저 ID로)
  void sendFriendRequestByUserId(int friendUserId) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('send_friend_request_by_user_id', {'friendUserId': friendUserId});
  }

  // 친구 요청 목록 조회
  void getFriendRequests() {
    _socketService.emit('get_friend_requests', {});
  }

  // 친구 요청 수락
  void acceptFriendRequest(int requestId) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('accept_friend_request', {'requestId': requestId});
  }

  // 친구 요청 거절
  void declineFriendRequest(int requestId) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('decline_friend_request', {'requestId': requestId});
  }

  // 보낸 친구 요청 취소
  void cancelFriendRequest(int requestId) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('cancel_friend_request', {'requestId': requestId});
  }

  void getFriends() {
    _isLoading = true;
    notifyListeners();
    _socketService.emit('get_friends', {});
  }

  void removeFriend(int friendId) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('remove_friend', {'friendId': friendId});
    // 로컬에서도 즉시 제거
    _friends.removeWhere((f) => f.id == friendId);
    notifyListeners();
  }

  void updateFriendMemo(int friendId, String? memo) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('update_friend_memo', {
      'friendId': friendId,
      'memo': memo?.isEmpty == true ? null : memo,
    });
  }

  void inviteToGame(int friendId, String gameType, {bool isHardcore = false}) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('invite_to_game', {
      'friendId': friendId,
      'gameType': gameType,
      'isHardcore': isHardcore,
    });
  }

  void getInvitations() {
    _socketService.emit('get_invitations', {});
  }

  void acceptInvitation(int invitationId) {
    _isLoading = true;
    _error = null;
    notifyListeners();
    _socketService.emit('accept_invitation', {'invitationId': invitationId});
    // 로컬에서 제거
    _invitations.removeWhere((i) => i.id == invitationId);
    notifyListeners();
  }

  void declineInvitation(int invitationId) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('decline_invitation', {'invitationId': invitationId});
    // 로컬에서 제거
    _invitations.removeWhere((i) => i.id == invitationId);
    notifyListeners();
  }

  void clearMessages() {
    _error = null;
    _successMessage = null;
    notifyListeners();
  }

  void getUnreadCounts() {
    debugPrint('📤 Emitting get_unread_counts');
    _socketService.emit('get_unread_counts', {});
  }

  void markMessagesRead(int friendId) {
    _socketService.emit('mark_messages_read', {'friendId': friendId});
    _unreadCounts.remove(friendId);
    notifyListeners();
  }

  @override
  void dispose() {
    _socketService.off('lobby_joined');
    _socketService.off('friend_code');
    _socketService.off('friend_request_result');
    _socketService.off('friend_request_received');
    _socketService.off('friend_requests_list');
    _socketService.off('friend_request_action_result');
    _socketService.off('friend_request_accepted');
    _socketService.off('friends_list');
    _socketService.off('remove_friend_result');
    _socketService.off('update_friend_memo_result');
    _socketService.off('invite_result');
    _socketService.off('invitations_list');
    _socketService.off('game_invitation');
    _socketService.off('accept_invitation_result');
    _socketService.off('decline_invitation_result');
    _socketService.off('invitation_declined');
    _socketService.off('invitation_accepted');
    _socketService.off('unread_counts');
    _socketService.off('new_message');
    super.dispose();
  }
}
