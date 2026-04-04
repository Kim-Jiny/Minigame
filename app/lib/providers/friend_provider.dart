import 'package:flutter/foundation.dart';
import 'mixins/provider_feedback.dart';
import '../services/socket_service.dart';
import '../services/socket_listener_registry.dart';
import '../models/shop_item.dart';
import '../utils/game_catalog.dart';

class Friend {
  final int id;
  final String nickname;
  final String? email;
  final String? avatarUrl;
  final String? friendCode;
  final String? memo;
  final bool isOnline;
  final UserProfileSettings? profileSettings;

  Friend({
    required this.id,
    required this.nickname,
    this.email,
    this.avatarUrl,
    this.friendCode,
    this.memo,
    this.isOnline = false,
    this.profileSettings,
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
      profileSettings: profileSettings,
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
      profileSettings: json['profileSettings'] != null
          ? UserProfileSettings.fromJson(json['profileSettings'])
          : null,
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
    final name = GameCatalog.nameFor(gameType);
    return isHardcore ? '$name (하드코어)' : name;
  }
}

class FriendProvider extends ChangeNotifier with ProviderFeedback {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(_socketService);

  String? _myFriendCode;
  List<Friend> _friends = [];
  List<FriendRequest> _receivedRequests = [];
  List<FriendRequest> _sentRequests = [];
  List<Invitation> _invitations = [];
  bool _listenersInitialized = false;
  bool _hasFetchedInitialData = false;
  Map<int, int> _unreadCounts = {}; // friendId -> unread count
  final Set<int> _pendingRemovals = {};
  int? _activeChatFriendId;

  // 초대 받았을 때 콜백
  Function(Invitation)? onInvitationReceived;
  // 게임 시작 콜백 (초대 수락 후) - gameState 포함, shouldNavigate: 화면 전환 필요 여부
  Function(String gameType, String roomId, Map<String, dynamic>? gameState, bool shouldNavigate)? onGameStart;
  // 친구 요청 받았을 때 콜백
  Function(String fromNickname)? onFriendRequestReceived;
  // 초대 만료 콜백
  Function(String message)? onInvitationExpired;
  // 초대 전송 실패 콜백 (busy 등)
  Function(String message, String? reason)? onInviteFailed;

  String? get myFriendCode => _myFriendCode;
  List<Friend> get friends => _friends;
  List<FriendRequest> get receivedRequests => _receivedRequests;
  List<FriendRequest> get sentRequests => _sentRequests;
  List<Invitation> get invitations => _invitations;
  Map<int, int> get unreadCounts => _unreadCounts;
  bool isRemoving(int friendId) => _pendingRemovals.contains(friendId);
  int get totalUnreadCount => _unreadCounts.values.fold(0, (sum, count) => sum + count);
  int get pendingRequestCount => _receivedRequests.length;
  int? get activeChatFriendId => _activeChatFriendId;
  bool get hasFetchedInitialData => _hasFetchedInitialData;

  // 특정 userId가 이미 친구인지 확인
  bool isFriend(int userId) {
    return _friends.any((f) => f.id == userId);
  }

  void initialize() {
    debugPrint('🔧 FriendProvider.initialize() called, _listenersInitialized=$_listenersInitialized, isConnected=${_socketService.isConnected}');
    if (!_listenersInitialized) {
      _setupSocketListeners();
      _listenersInitialized = true;
    }
    // 로비 입장이 끝난 뒤에만 즉시 조회한다.
    if (_socketService.isReady) {
      debugPrint('🔧 Socket ready, fetching initial data');
      refreshAll();
    }
  }

  void refreshAll() {
    _hasFetchedInitialData = true;
    getMyFriendCode();
    getFriends();
    getFriendRequests();
    getInvitations();
    getUnreadCounts();
  }

  void _setupSocketListeners() {
    // 로비 입장 후 데이터 가져오기
    _socketListeners.on('lobby_joined', (_) {
      refreshAll();
    });

    // 친구 코드 응답
    _socketListeners.on('friend_code', (data) {
      debugPrint('📥 Received friend_code: ${data['code']}');
      _myFriendCode = data['code'];
      notifyListeners();
    });

    _socketListeners.on('friend_code_error', (data) {
      _myFriendCode = null;
      final message = data['message'] as String? ?? '친구 코드를 불러오지 못했습니다.';
      setError(message);
      notifyListeners();
    });

    // 친구 요청 결과
    _socketListeners.on('friend_request_result', (data) {
      setLoading(false);
      if (data['success'] == true) {
        setSuccess(data['message']);
        // 친구 요청 목록 새로고침
        getFriendRequests();
        // 바로 친구가 된 경우 친구 목록도 새로고침
        if (data['message']?.contains('친구가 되었습니다') == true) {
          getFriends();
        }
      } else {
        setError(data['message']);
      }
      notifyListeners();
    });

    // 친구 요청 받음 (실시간)
    _socketListeners.on('friend_request_received', (data) {
      final fromNickname = data['fromNickname'] as String;
      onFriendRequestReceived?.call(fromNickname);
      // 친구 요청 목록 새로고침
      getFriendRequests();
    });

    // 친구 요청 목록 응답
    _socketListeners.on('friend_requests_list', (data) {
      _receivedRequests = (data['received'] as List)
          .map((r) => FriendRequest.fromJson(r))
          .toList();
      _sentRequests = (data['sent'] as List)
          .map((r) => FriendRequest.fromJson(r))
          .toList();
      notifyListeners();
    });

    // 친구 요청 수락/거절/취소 결과
    _socketListeners.on('friend_request_action_result', (data) {
      setLoading(false);
      if (data['success'] == true) {
        setSuccess(data['message']);
        // 친구 요청 목록 새로고침
        getFriendRequests();
        // 수락인 경우 친구 목록도 새로고침
        if (data['action'] == 'accept') {
          getFriends();
        }
      } else {
        setError(data['message']);
      }
      notifyListeners();
    });

    // 내가 보낸 친구 요청이 수락됨
    _socketListeners.on('friend_request_accepted', (data) {
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
    _socketListeners.on('friends_list', (data) {
      _friends = (data['friends'] as List)
          .map((f) => Friend.fromJson(f))
          .toList();
      setLoading(false);
      notifyListeners();
    });

    // 친구 삭제 결과
    _socketListeners.on('remove_friend_result', (data) {
      final friendId = data['friendId'] as int?;
      if (friendId != null) {
        _pendingRemovals.remove(friendId);
      } else {
        _pendingRemovals.clear();
      }
      setLoading(false);
      if (data['success'] == true) {
        setSuccess(data['message']);
        // 성공 시 서버 상태로 동기화
        getFriends();
      } else {
        setError(data['message']);
        // 실패 시 서버 상태로 동기화
        getFriends();
      }
      notifyListeners();
    });

    // 친구 메모 수정 결과
    _socketListeners.on('update_friend_memo_result', (data) {
      setLoading(false);
      if (data['success'] == true) {
        final friendId = data['friendId'] as int;
        final memo = data['memo'] as String?;
        final index = _friends.indexWhere((f) => f.id == friendId);
        if (index != -1) {
          _friends[index] = _friends[index].copyWith(memo: memo);
        }
        setSuccess(data['message']);
      } else {
        setError(data['message']);
      }
      notifyListeners();
    });

    // 초대 결과 (게임 화면에서 자체 SnackBar를 표시하므로 successMessage는 설정하지 않음)
    _socketListeners.on('invite_result', (data) {
      setLoading(false);
      if (data['success'] != true) {
        setError(data['message']);
        final reason = data['reason'] as String?;
        onInviteFailed?.call(data['message'] ?? '초대 실패', reason);
      }
      notifyListeners();
    });

    // 초대 만료
    _socketListeners.on('invitation_expired', (data) {
      final invitationId = data['invitationId'] as int?;
      final message = data['message'] as String? ?? '초대가 만료되었습니다.';

      // 초대 목록에서 제거
      if (invitationId != null) {
        _invitations.removeWhere((i) => i.id == invitationId);
      }

      // 콜백 호출
      onInvitationExpired?.call(message);
      notifyListeners();
    });

    // 초대 목록 응답
    _socketListeners.on('invitations_list', (data) {
      _invitations = (data['invitations'] as List)
          .map((i) => Invitation.fromJson(i))
          .toList();
      notifyListeners();
    });

    // 실시간 초대 받음
    _socketListeners.on('game_invitation', (data) {
      final invitation = Invitation.fromJson(data['invitation']);
      if (_invitations.any((existing) => existing.id == invitation.id)) {
        return;
      }
      _invitations.insert(0, invitation);
      notifyListeners();

      // 콜백 호출 (다이얼로그 표시용)
      onInvitationReceived?.call(invitation);
    });

    // 초대 수락 결과
    _socketListeners.on('accept_invitation_result', (data) {
      setLoading(false);
      if (data['success'] == true) {
        final acceptedInvitationId = data['invitationId'] as int?;
        if (acceptedInvitationId != null) {
          _invitations.removeWhere((i) => i.id == acceptedInvitationId);
        }
        // 게임 시작 콜백 호출 (게임 상태 포함)
        // 수락자는 게임 화면으로 이동 필요
        final roomId = data['roomId'] as String?;
        final gameType = data['gameType'] as String?;
        final gameState = data['gameState'] as Map<String, dynamic>?;
        if (roomId != null && gameType != null) {
          onGameStart?.call(gameType, roomId, gameState, true);
        }
      } else {
        setError(data['message']);
      }
      notifyListeners();
    });

    // 초대 거절 결과
    _socketListeners.on('decline_invitation_result', (data) {
      setLoading(false);
      if (data['success'] == true) {
        final declinedInvitationId = data['invitationId'] as int?;
        if (declinedInvitationId != null) {
          _invitations.removeWhere((i) => i.id == declinedInvitationId);
        }
        setSuccess('초대를 거절했습니다.');
      } else {
        setError(data['message']);
      }
      notifyListeners();
    });

    // 초대가 거절됨
    _socketListeners.on('invitation_declined', (data) {
      setError('${data['declinedBy']}님이 초대를 거절했습니다.');
      notifyListeners();
    });

    // 초대가 수락됨 (초대자에게)
    _socketListeners.on('invitation_accepted', (data) {
      final roomId = data['roomId'] as String?;
      final gameType = data['gameType'] as String?;
      final gameState = data['gameState'] as Map<String, dynamic>?;
      if (roomId != null && gameType != null) {
        // 초대자도 게임 화면으로 이동 (로비에서 초대한 경우)
        onGameStart?.call(gameType, roomId, gameState, true);
      }
    });

    // 안 읽은 메시지 수
    _socketListeners.on('unread_counts', (data) {
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
    _socketListeners.on('new_message', (data) {
      if (data['message'] != null) {
        final senderId = data['message']['senderId'] as int?;
        if (senderId == null) return;
        if (_activeChatFriendId == senderId) return;
        _unreadCounts[senderId] = (_unreadCounts[senderId] ?? 0) + 1;
        notifyListeners();
      }
    });
  }

  void setActiveChatFriend(int? friendId) {
    _activeChatFriendId = friendId;
    if (friendId != null) {
      _unreadCounts.remove(friendId);
      notifyListeners();
    }
  }

  void getMyFriendCode() {
    debugPrint('📤 Emitting get_friend_code');
    _socketService.emit('get_friend_code', {});
  }

  // 친구 요청 보내기 (친구 코드로)
  void sendFriendRequest(String code) {
    startLoading();
    notifyListeners();
    _socketService.emit('send_friend_request', {'friendCode': code.toUpperCase()});
  }

  // 친구 요청 보내기 (유저 ID로)
  void sendFriendRequestByUserId(int friendUserId) {
    startLoading();
    notifyListeners();
    _socketService.emit('send_friend_request_by_user_id', {'friendUserId': friendUserId});
  }

  // 친구 요청 목록 조회
  void getFriendRequests() {
    _socketService.emit('get_friend_requests', {});
  }

  // 친구 요청 수락
  void acceptFriendRequest(int requestId) {
    startLoading();
    notifyListeners();
    _socketService.emit('accept_friend_request', {'requestId': requestId});
  }

  // 친구 요청 거절
  void declineFriendRequest(int requestId) {
    startLoading();
    notifyListeners();
    _socketService.emit('decline_friend_request', {'requestId': requestId});
  }

  // 보낸 친구 요청 취소
  void cancelFriendRequest(int requestId) {
    startLoading();
    notifyListeners();
    _socketService.emit('cancel_friend_request', {'requestId': requestId});
  }

  void getFriends() {
    setLoading(true);
    notifyListeners();
    _socketService.emit('get_friends', {});
  }

  void removeFriend(int friendId) {
    startLoading();
    _pendingRemovals.add(friendId);
    notifyListeners();
    _socketService.emit('remove_friend', {'friendId': friendId});
  }

  void updateFriendMemo(int friendId, String? memo) {
    startLoading();
    notifyListeners();
    _socketService.emit('update_friend_memo', {
      'friendId': friendId,
      'memo': memo?.isEmpty == true ? null : memo,
    });
  }

  void inviteToGame(int friendId, String gameType, {bool isHardcore = false}) {
    // 중복 초대 방지
    if (isLoading) {
      // 이미 로딩 중이면 새 요청을 무시
      debugPrint('🚫 inviteToGame: 이미 초대 진행 중');
      return;
    }
    startLoading();
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
    startLoading(clearSuccess: false);
    notifyListeners();
    _socketService.emit('accept_invitation', {'invitationId': invitationId});
  }

  void declineInvitation(int invitationId) {
    startLoading();
    notifyListeners();
    _socketService.emit('decline_invitation', {'invitationId': invitationId});
  }

  void clearMessages() {
    clearFeedback();
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

  void resetState() {
    _myFriendCode = null;
    _friends = [];
    _receivedRequests = [];
    _sentRequests = [];
    _invitations = [];
    _hasFetchedInitialData = false;
    _unreadCounts = {};
    _pendingRemovals.clear();
    _activeChatFriendId = null;
    clearFeedback();
    notifyListeners();
  }

  @override
  void dispose() {
    _socketListeners.offAll();
    super.dispose();
  }
}
